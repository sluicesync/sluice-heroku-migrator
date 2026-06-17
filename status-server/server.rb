#!/usr/bin/env ruby
# frozen_string_literal: true

# Lightweight HTTP status server for monitoring a sluice-driven Heroku Postgres
# -> PlanetScale Postgres migration. This is the sluice analog of the upstream
# Bucardo migrator's status server: same dashboard, same phase model, same
# endpoints -- but the replication engine underneath is sluice's
# postgres-trigger CDC engine instead of Bucardo.
#
# Endpoints:
#   GET  /                - HTML dashboard UI
#   GET  /status          - current migration status as JSON
#   GET  /health          - basic health check (no auth)
#   GET  /preflight-checks- automated pre-migration validation
#   GET  /logs            - recent sluice sync + setup logs
#   POST /start-migration - install the trigger engine on the source
#   POST /start-copy      - launch `sluice sync start` (schema + copy + CDC)
#   POST /pause-sync      - drain + stop the sync process (triggers stay)
#   POST /resume-sync     - relaunch the sync (warm resume from position)
#   POST /switch-traffic  - REVOKE writes on Heroku, prime sequences
#   POST /revert-switch   - restore write access on Heroku
#   POST /cleanup         - teardown trigger engine (Complete Migration)
#   POST /abort           - emergency teardown from any active phase
#   POST /retry           - reset error -> waiting

require "webrick"
require "webrick/httpauth"
require "json"
require "tmpdir"
require "fileutils"
require "net/http"
require "uri"
require "time"

# sluice's CLI output (help text, logs) contains UTF-8 (em-dashes etc.). If the
# container locale is US-ASCII, backtick/File reads tag those bytes as ASCII and
# any later String#scan / JSON.generate raises "invalid byte sequence in
# US-ASCII". Force UTF-8 defaults; log reads are additionally scrubbed below.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
STATE_DIR = "/opt/sluice/state"
STATUS_FILE = File.join(STATE_DIR, "status.json")
COPY_PROGRESS_FILE = File.join(STATE_DIR, "copy_progress.json")
SETUP_LOG_FILE = File.join(STATE_DIR, "setup.log")
SYNC_LOG_FILE = "/var/log/sluice/sync.log"
SYNC_PID_FILE = File.join(STATE_DIR, "sync.pid")
SCRIPTS_DIR = "/opt/sluice/scripts"

SLUICE_BIN = ENV["SLUICE_BIN"] || "sluice"
STREAM_ID = ENV["SLUICE_STREAM_ID"] || "ps_import"

HEROKU_URL = ENV["HEROKU_URL"]
PLANETSCALE_URL = ENV["PLANETSCALE_URL"]

PORT = (ENV["PORT"] || 8080).to_i

# ---------------------------------------------------------------------------
# Slack notifications (opt-in). Unlike the upstream tool, this fork ships NO
# hardcoded webhook -- set SLACK_WEBHOOK_URL to enable, DISABLE_NOTIFICATIONS to
# force off.
# ---------------------------------------------------------------------------
SLACK_WEBHOOK_URL = ENV["SLACK_WEBHOOK_URL"]
NOTIFICATIONS_ENABLED = !SLACK_WEBHOOK_URL.to_s.strip.empty? &&
                        ENV["DISABLE_NOTIFICATIONS"]&.downcase != "true"

# Parse the PlanetScale branch id from the connection string username when
# present (format: pscale_xxx.BRANCH_ID). Best-effort, decorative only.
PS_BRANCH_ID = begin
  user = PLANETSCALE_URL&.split("/")&.dig(2)&.split(":")&.first
  user&.split(".")&.last
rescue StandardError
  nil
end

# ---------------------------------------------------------------------------
# HTTP basic auth
# ---------------------------------------------------------------------------
PASSWORD = ENV.fetch("PASSWORD")
AUTH_DISABLED = ENV["DISABLE_AUTH"]&.downcase == "true"
realm = "sluice Migration"
htpasswd = WEBrick::HTTPAuth::Htpasswd.new("/tmp/.htpasswd")
htpasswd.set_passwd(realm, "admin", PASSWORD)
AUTHENTICATOR = WEBrick::HTTPAuth::BasicAuth.new(Realm: realm, UserDB: htpasswd)

def require_auth(req, res)
  return if AUTH_DISABLED
  AUTHENTICATOR.authenticate(req, res)
end

# ---------------------------------------------------------------------------
# Slack helpers
# ---------------------------------------------------------------------------
def notify_slack(message)
  return unless NOTIFICATIONS_ENABLED
  Thread.new do
    begin
      uri = URI.parse(SLACK_WEBHOOK_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 5
      http.read_timeout = 5
      req = Net::HTTP::Post.new(uri.request_uri, { "Content-Type" => "application/json" })
      req.body = JSON.generate({ text: message })
      http.request(req)
    rescue => e
      $stderr.puts "Slack notification failed: #{e.message}"
    end
  end
end

def branch_tag
  PS_BRANCH_ID ? " (branch: #{PS_BRANCH_ID})" : ""
end

def filter_harmless_pg_warnings(output)
  output.lines.reject { |line|
    line =~ /\AWARNING:\s+no privileges (?:could be revoked|were granted) for/
  }.join
end

# Phase transition tracking for milestone notifications
$last_notified_phase = nil
$last_notified_copy_phase = nil

def check_milestone_notifications(status_data)
  return unless NOTIFICATIONS_ENABLED
  phase = status_data["phase"]
  copy_phase = status_data.dig("sluice", "initial_copy_phase")
  return if phase == $last_notified_phase && copy_phase == $last_notified_copy_phase

  case phase
  when "starting"
    notify_slack(":rocket: Migration started#{branch_tag}") if $last_notified_phase.nil?
  when "configuring"
    notify_slack(":gear: Installing trigger engine on the source#{branch_tag}") if $last_notified_phase != "configuring"
  when "ready_to_copy"
    notify_slack(":white_check_mark: Triggers installed, ready to start data copy#{branch_tag}") if $last_notified_phase != "ready_to_copy"
  when "copying"
    notify_slack(":arrows_counterclockwise: Data copy started#{branch_tag}") if $last_notified_phase != "copying"
  when "replicating"
    notify_slack(":white_check_mark: Databases in sync#{branch_tag}") if $last_notified_phase != "replicating"
  when "switched"
    notify_slack(":warning: Traffic switched -- Heroku writes revoked#{branch_tag}") if $last_notified_phase != "switched"
  when "cleaning_up"
    notify_slack(":broom: Cleaning up replication#{branch_tag}") if $last_notified_phase != "cleaning_up"
  when "completed"
    notify_slack(":tada: Migration complete!#{branch_tag}") if $last_notified_phase != "completed"
  when "error"
    if $last_notified_phase != "error"
      error_msg = status_data["error"]&.to_s&.slice(0, 200)
      notify_slack(":x: Migration error#{branch_tag}: #{error_msg || 'Unknown error'}")
    end
  end

  $last_notified_phase = phase
  $last_notified_copy_phase = copy_phase
end

# ---------------------------------------------------------------------------
# Persistent migration state (survives Heroku dyno restarts). Stored on the
# PlanetScale target so it outlives the ephemeral dyno filesystem.
# ---------------------------------------------------------------------------
def ps_migrate_query(sql)
  `psql "#{PLANETSCALE_URL}" -A -t -c "#{sql}" 2>/dev/null`.strip
end

def ensure_migration_state_table
  ps_migrate_query("CREATE TABLE IF NOT EXISTS _ps_migration_state (id integer PRIMARY KEY DEFAULT 1, phase text NOT NULL, started_at text, switched_at text, completed_at text, error text, updated_at text)")
end

def read_persistent_state
  return nil unless PLANETSCALE_URL
  row = ps_migrate_query("SELECT phase, started_at, switched_at, completed_at, error FROM _ps_migration_state WHERE id = 1")
  return nil if row.empty?
  parts = row.split("|", -1)
  return nil if parts.length < 5
  { "phase" => parts[0], "started_at" => parts[1], "switched_at" => parts[2], "completed_at" => parts[3], "error" => parts[4] }
rescue StandardError
  nil
end

def write_persistent_state(phase, extras = {})
  return unless PLANETSCALE_URL
  ensure_migration_state_table
  now = Time.now.utc.iso8601
  switched = extras[:switched_at] || "NULL"
  completed = extras[:completed_at] || "NULL"
  error_val = extras[:error]&.gsub("'", "''") || ""
  started = extras[:started_at] || now

  ps_migrate_query("INSERT INTO _ps_migration_state (id, phase, started_at, switched_at, completed_at, error, updated_at) VALUES (1, '#{phase}', '#{started}', #{switched == 'NULL' ? 'NULL' : "'#{switched}'"}, #{completed == 'NULL' ? 'NULL' : "'#{completed}'"}, '#{error_val}', '#{now}') ON CONFLICT (id) DO UPDATE SET phase = '#{phase}', switched_at = #{switched == 'NULL' ? 'NULL' : "'#{switched}'"}, completed_at = #{completed == 'NULL' ? 'NULL' : "'#{completed}'"}, error = '#{error_val}', updated_at = '#{now}'")
rescue => e
  $stderr.puts "Failed to write persistent state: #{e.message}"
end

def read_status_file
  if File.exist?(STATUS_FILE)
    JSON.parse(File.read(STATUS_FILE))
  else
    { "phase" => "unknown", "state" => "unknown", "message" => "Status file not found" }
  end
rescue JSON::ParserError
  { "phase" => "unknown", "state" => "unknown", "message" => "Status file corrupted" }
end

# ---------------------------------------------------------------------------
# sluice replication status.
#
# Source of truth is `sluice sync status --format=json`, which reads the
# target's sluice_cdc_state control table -- so it is accurate even between
# sync-process restarts. A stream row appears only AFTER the snapshot completes
# and CDC starts, so its presence is our clean "initial copy finished" signal.
# Shape (cmd/sluice/status_render.go):
#   {"streams":[{"stream_id":...,"position":{"engine":...,"token":...},
#                "updated_at":...,"age_seconds":N}]}
# ---------------------------------------------------------------------------
def get_sluice_status
  out = `#{SLUICE_BIN} sync status --target-driver=postgres --target="#{PLANETSCALE_URL}" --stream-id="#{STREAM_ID}" --format=json 2>/dev/null`
  return nil if out.strip.empty?

  doc = JSON.parse(out)
  return nil unless doc.is_a?(Hash)

  streams = doc["streams"].is_a?(Array) ? doc["streams"] : []
  stream = streams.find { |s| s["stream_id"] == STREAM_ID } || streams.first
  result = { "raw" => out }

  if stream.nil?
    # No CDC position yet: either the snapshot is still running or it hasn't
    # started. Treat as initial copy in progress; byte-weighted progress (below)
    # estimates how far the copy has gotten from target relation sizes.
    result["active"] = sync_process_running? ? "Copying" : "Inactive"
    result["current_state"] = "not-yet-started"
    result["initial_copy_phase"] = "in-progress"
    return result
  end

  age = stream["age_seconds"]
  age = age.is_a?(Numeric) ? age.to_i : nil
  result["active"] = "Active"
  result["initial_copy_phase"] = "finished" # a position row exists only post-snapshot
  result["last_good_sync"] = stream["updated_at"]
  result["seconds_since_last_good"] = age
  result["position_token"] = stream.dig("position", "token").to_s
  result["position_engine"] = stream.dig("position", "engine").to_s
  # A maintained position row means CDC is live. Lag/idle is surfaced separately
  # through seconds_since_last_good; we do not flap current_state on quiet
  # periods (no writes looks the same as a short stall -- the dashboard's stall
  # detector distinguishes them over time).
  result["current_state"] = "good"
  result
rescue StandardError => e
  { "error" => e.message }
end

def read_copy_progress_file
  return nil unless File.exist?(COPY_PROGRESS_FILE)
  JSON.parse(File.read(COPY_PROGRESS_FILE))
rescue JSON::ParserError
  nil
end

def write_copy_progress_file(data)
  File.write(COPY_PROGRESS_FILE, JSON.generate(data))
rescue StandardError => e
  $stderr.puts "Failed to write copy progress file: #{e.message}"
end

def parse_time_safe(value)
  return nil if value.nil? || value.to_s.strip.empty?
  Time.parse(value.to_s)
rescue StandardError
  nil
end

def normalize_table_name(value)
  return nil if value.nil?
  table = value.to_s.strip
  table = table.gsub(/\A"+|"+\z/, "")
  table = table.gsub(/\Apublic\./i, "")
  table.empty? ? nil : table
end

def list_public_tables
  return [] unless HEROKU_URL
  output = `psql "#{HEROKU_URL}" -A -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename NOT LIKE 'sluice\\_%' ORDER BY tablename;" 2>/dev/null`.strip
  return [] if output.empty?
  output.split("\n").map { |t| normalize_table_name(t) }.compact.uniq
rescue StandardError
  []
end

# Public tables with no primary key and no unique index. sluice's
# postgres-trigger engine tracks rows by primary key, so each replicated table
# needs one -- the same hard requirement Bucardo has.
def check_tables_without_pk_or_unique
  return [] unless HEROKU_URL
  query = "SELECT c.relname FROM pg_class c " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace " \
          "WHERE n.nspname = 'public' AND c.relkind = 'r' " \
          "AND c.relname NOT LIKE 'sluice\\_%' " \
          "AND NOT EXISTS (" \
          "  SELECT 1 FROM pg_index i " \
          "  WHERE i.indrelid = c.oid " \
          "  AND (i.indisprimary OR i.indisunique)" \
          ") ORDER BY c.relname;"
  output = `psql "#{HEROKU_URL}" -A -t -c "#{query}" 2>/dev/null`.strip
  return [] if output.empty?
  output.split("\n").map { |t| normalize_table_name(t) }.compact.uniq
rescue StandardError
  []
end

# Public tables with at least one generated column. sluice translates and
# recreates GENERATED ALWAYS ... STORED columns on the target and omits them
# from the bulk copy automatically (the target recomputes them), so this is
# informational only and does NOT block start.
def check_tables_with_generated_columns
  return [] unless HEROKU_URL
  query = "SELECT c.relname, a.attname " \
          "FROM pg_attribute a " \
          "JOIN pg_class c ON c.oid = a.attrelid " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace " \
          "WHERE n.nspname = 'public' AND c.relkind = 'r' " \
          "  AND c.relname NOT LIKE 'sluice\\_%' " \
          "  AND a.attnum > 0 AND NOT a.attisdropped " \
          "  AND a.attgenerated <> '' " \
          "ORDER BY c.relname, a.attnum;"
  output = `psql "#{HEROKU_URL}" -A -t -F"|" -c "#{query}" 2>/dev/null`.strip
  return [] if output.empty?

  by_table = {}
  output.split("\n").each do |line|
    parts = line.strip.split("|")
    next unless parts.length == 2
    table = normalize_table_name(parts[0])
    column = parts[1].to_s.strip
    next if table.nil? || column.empty?
    (by_table[table] ||= []) << column
  end
  by_table.map { |table, columns| { "table" => table, "columns" => columns.uniq } }
rescue StandardError
  []
end

def capture_table_size_estimates
  return nil unless HEROKU_URL
  sizes = get_table_size_estimates(HEROKU_URL)
  return nil if sizes.empty?
  {
    "captured_at" => Time.now.utc.iso8601,
    "table_sizes" => sizes,
    "total_tables" => sizes.length,
    "total_bytes" => sizes.values.reduce(0, :+),
    "completed_tables" => [],
    "history" => [],
    "last_progress_at" => Time.now.utc.iso8601,
  }
rescue StandardError
  nil
end

def get_table_size_estimates(db_url)
  return {} unless db_url
  query = "SELECT c.relname, pg_total_relation_size(c.oid)::bigint FROM pg_class c " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace " \
          "WHERE n.nspname = 'public' AND c.relkind = 'r' " \
          "AND c.relname NOT LIKE 'sluice\\_%' ORDER BY c.relname;"
  output = `psql "#{db_url}" -A -t -c "#{query}" 2>/dev/null`.strip
  return {} if output.empty?

  sizes = {}
  output.split("\n").each do |line|
    parts = line.strip.split("|")
    next unless parts.length == 2
    table = normalize_table_name(parts[0])
    next unless table
    sizes[table] = parts[1].to_i
  end
  sizes
rescue StandardError
  {}
end

def tail_sync_log(lines = 300)
  return "" unless File.exist?(SYNC_LOG_FILE)
  `tail -#{lines} "#{SYNC_LOG_FILE}" 2>/dev/null`.scrub
rescue StandardError
  ""
end

def extract_tables_from_text(text, patterns, known_tables)
  return [] unless text && !text.empty?
  found = []
  patterns.each do |pattern|
    text.scan(pattern) do |match|
      table_raw = match.is_a?(Array) ? match[0] : match
      table = normalize_table_name(table_raw)
      next unless table
      next if known_tables.any? && !known_tables.include?(table)
      found << table
    end
  end
  found.uniq
end

# sluice logs bulk-copy progress per table; pull the most recently mentioned
# table as the "current" one during the copy phase.
def extract_current_table(log_text, known_tables)
  return nil if log_text.nil? || log_text.empty?
  patterns = [
    /copying\s+table\s+("?[\w.]+")/i,
    /bulk[- ]?copy.*\btable[=:]?\s*("?[\w.]+")/i,
    /table[=:]\s*("?[\w.]+")/i,
  ]
  extract_tables_from_text(log_text, patterns, known_tables).last
end

def extract_completed_tables(log_text, known_tables)
  patterns = [
    /(?:finished|completed|copied)\s+table\s+("?[\w.]+")/i,
    /table\s+("?[\w.]+")\s+(?:done|finished|complete|copied)/i,
  ]
  extract_tables_from_text(log_text, patterns, known_tables)
end

def compute_backlog_trend(history)
  points = Array(history).last(6).map { |h| h["seconds_since_last_good"] }.select { |v| v.is_a?(Numeric) }
  return "unknown" if points.length < 3
  deltas = points.each_cons(2).map { |a, b| b - a }
  return "growing" if deltas.all? { |d| d >= 0 } && deltas.any? { |d| d > 0 }
  return "shrinking" if deltas.all? { |d| d <= 0 } && deltas.any? { |d| d < 0 }
  "stable"
end

def compute_throughput_and_eta(history, total_bytes, copied_bytes)
  return nil unless total_bytes.to_i > 0 && copied_bytes.to_i >= 0
  points = Array(history).last(20).select { |h| h["copied_bytes"].is_a?(Numeric) && parse_time_safe(h["ts"]) }
  return nil if points.length < 2

  first = points.first
  last = points.last
  bytes_delta = last["copied_bytes"].to_i - first["copied_bytes"].to_i
  seconds_delta = parse_time_safe(last["ts"]).to_i - parse_time_safe(first["ts"]).to_i
  return nil if bytes_delta <= 0 || seconds_delta <= 0

  bytes_per_min = (bytes_delta.to_f / seconds_delta) * 60.0
  return nil if bytes_per_min <= 0

  remaining = [total_bytes.to_i - copied_bytes.to_i, 0].max
  eta_minutes = remaining / bytes_per_min
  {
    "bytes_per_min" => bytes_per_min.round,
    "mb_per_min" => (bytes_per_min / 1024.0 / 1024.0).round(2),
    "eta_min_minutes" => (eta_minutes * 0.7).round,
    "eta_max_minutes" => (eta_minutes * 1.3).round,
  }
end

def build_event_checklist(phase:, copy_phase:, lag_health:)
  replication_healthy = lag_health["health_state"] == "healthy"
  steps = [
    { "id" => "triggers_installed", "label" => "Triggers installed", "status" => ["ready_to_copy", "copying", "replicating", "switched", "cleaning_up", "completed"].include?(phase) ? "complete" : "pending" },
    { "id" => "sync_launched", "label" => "Sync launched", "status" => ["copying", "replicating", "switched", "cleaning_up", "completed"].include?(phase) ? "complete" : "pending" },
    { "id" => "initial_copy_running", "label" => "Initial copy running", "status" => copy_phase == "in-progress" ? "current" : (["replicating", "switched", "cleaning_up", "completed"].include?(phase) ? "complete" : "pending") },
    { "id" => "initial_copy_complete", "label" => "Initial copy complete", "status" => (copy_phase == "finished" || ["replicating", "switched", "cleaning_up", "completed"].include?(phase)) ? "complete" : "pending" },
    { "id" => "replication_healthy", "label" => "Replication healthy", "status" => replication_healthy ? "complete" : (["replicating", "switched", "cleaning_up", "completed"].include?(phase) ? "current" : "pending") },
  ]
  {
    "steps" => steps,
    "completed" => steps.count { |s| s["status"] == "complete" },
    "total" => steps.length,
  }
end

def build_progress_signals(phase:, sluice_status:, readiness:)
  state = read_copy_progress_file || {}
  if state["table_sizes"].nil? || state["table_sizes"].empty?
    captured = capture_table_size_estimates
    state = captured if captured
  end

  table_sizes = state["table_sizes"].is_a?(Hash) ? state["table_sizes"] : {}
  known_tables = table_sizes.keys
  if known_tables.empty?
    known_tables = list_public_tables
    state["table_sizes"] ||= {}
    known_tables.each { |t| state["table_sizes"][t] ||= 0 }
  end

  total_tables = state["total_tables"].to_i
  total_tables = known_tables.length if total_tables <= 0

  log_tail = tail_sync_log(500)
  detected_completed = extract_completed_tables(log_tail, known_tables)
  persisted_completed = Array(state["completed_tables"]).map { |t| normalize_table_name(t) }.compact
  completed_tables = (persisted_completed + detected_completed).uniq
  current_table = extract_current_table(log_tail, known_tables)
  copy_phase = sluice_status.is_a?(Hash) ? sluice_status["initial_copy_phase"] : "unknown"
  tables_completed = completed_tables.length
  tables_completed = total_tables if copy_phase == "finished" && total_tables > 0
  tables_completed = [tables_completed, total_tables].min if total_tables > 0

  total_bytes = state["total_bytes"].to_i
  total_bytes = state["table_sizes"].values.reduce(0, :+) if total_bytes <= 0 && state["table_sizes"].is_a?(Hash)
  copied_bytes = completed_tables.reduce(0) { |sum, t| sum + state["table_sizes"].fetch(t, 0).to_i }
  byte_estimate_mode = "completed_tables"
  if copy_phase == "in-progress" && total_bytes > 0
    # Estimate partial progress from live target relation sizes, clamped at each
    # table's source size. Gives non-zero movement before a table is marked done.
    target_sizes = get_table_size_estimates(PLANETSCALE_URL)
    if target_sizes.any?
      estimated_copied = 0
      state["table_sizes"].each do |table, source_size|
        src = source_size.to_i
        dst = target_sizes[table].to_i
        next if src <= 0
        estimated_copied += [dst, src].min
      end
      if estimated_copied > copied_bytes
        copied_bytes = estimated_copied
        byte_estimate_mode = "target_size_estimate"
      end
    end
  end
  if copied_bytes <= 0 && total_bytes > 0 && total_tables > 0 && tables_completed > 0
    copied_bytes = ((tables_completed.to_f / total_tables) * total_bytes).round
    byte_estimate_mode = "table_ratio_estimate"
  end
  # Keep progress monotonic so operators never see the bar regress.
  previous_max_copied = state["max_copied_bytes_seen"].to_i
  if copy_phase == "in-progress" && copied_bytes < previous_max_copied
    copied_bytes = previous_max_copied
    byte_estimate_mode = "target_size_estimate_monotonic" if byte_estimate_mode == "target_size_estimate"
  end
  state["max_copied_bytes_seen"] = [previous_max_copied, copied_bytes].max
  byte_percent = total_bytes > 0 ? ((copied_bytes.to_f / total_bytes) * 100.0).round(1) : 0.0

  now = Time.now.utc
  last_good = sluice_status.is_a?(Hash) ? parse_time_safe(sluice_status["last_good_sync"]) : nil
  last_good_age = if sluice_status.is_a?(Hash) && sluice_status["seconds_since_last_good"].is_a?(Numeric)
    sluice_status["seconds_since_last_good"].to_i
  elsif last_good
    (now - last_good).to_i
  end

  state["history"] ||= []
  history = state["history"]
  history << {
    "ts" => now.iso8601,
    "tables_completed" => tables_completed,
    "copied_bytes" => copied_bytes,
    "seconds_since_last_good" => last_good_age,
    "last_good_sync" => sluice_status.is_a?(Hash) ? sluice_status["last_good_sync"] : nil,
  }
  state["history"] = history.last(240)

  previous = state["history"][-2]
  progress_advanced = false
  if previous
    progress_advanced ||= tables_completed > previous["tables_completed"].to_i
    progress_advanced ||= copied_bytes > previous["copied_bytes"].to_i
    prev_good = previous["last_good_sync"]
    progress_advanced ||= prev_good != (sluice_status.is_a?(Hash) ? sluice_status["last_good_sync"] : nil)
  end
  state["last_progress_at"] = now.iso8601 if progress_advanced || state["last_progress_at"].nil?

  backlog_trend = compute_backlog_trend(state["history"])
  health_state = if sluice_status.nil?
    "blocked"
  elsif sluice_healthy_for_replication?(sluice_status) && last_good_age && last_good_age <= 120
    "healthy"
  elsif sluice_healthy_for_replication?(sluice_status)
    "degraded"
  else
    "blocked"
  end

  blocker_reason = nil
  if readiness.is_a?(Hash) && readiness["hard_blockers"].is_a?(Array) && !readiness["hard_blockers"].empty?
    blocker_reason = readiness["hard_blockers"].first
  elsif health_state == "blocked"
    blocker_reason = "replication_not_healthy"
  end

  throughput = compute_throughput_and_eta(state["history"], total_bytes, copied_bytes)
  last_progress_at = parse_time_safe(state["last_progress_at"])
  no_progress_minutes = last_progress_at ? ((now - last_progress_at) / 60.0).round(1) : 0
  stall_warning = {
    "stalled" => ["copying", "replicating"].include?(phase) && no_progress_minutes >= 10,
    "no_progress_minutes" => no_progress_minutes,
    "message" => "No measurable progress for #{no_progress_minutes} minute(s). Check the sync log, sluice sync status, and source DB load.",
    "next_steps" => [
      "Open Live Logs and inspect recent sluice output",
      "Confirm `sluice sync status` shows a maintained position",
      "Check Heroku Postgres load and lock contention",
    ],
  }

  checklist = build_event_checklist(
    phase: phase,
    copy_phase: copy_phase,
    lag_health: { "health_state" => health_state },
  )

  state["completed_tables"] = completed_tables
  state["total_tables"] = total_tables
  state["total_bytes"] = total_bytes
  write_copy_progress_file(state)

  {
    "table_phase" => {
      "phase" => copy_phase,
      "current_table" => current_table,
      "tables_completed" => tables_completed,
      "total_tables" => total_tables,
    },
    "byte_weighted" => {
      "copied_bytes" => copied_bytes,
      "total_bytes" => total_bytes,
      "percent" => byte_percent,
      "estimate_mode" => byte_estimate_mode,
    },
    "replication_delay" => {
      "last_good_sync" => sluice_status.is_a?(Hash) ? sluice_status["last_good_sync"] : nil,
      "seconds_since_last_good" => last_good_age,
      "backlog_trend" => backlog_trend,
      "health_state" => health_state,
      "blocker_reason" => blocker_reason,
    },
    "throughput_eta" => throughput,
    "event_checklist" => checklist,
    "stall_detection" => stall_warning,
  }
end

def recent_good_sync?(sluice_status, max_age_seconds = 120)
  age = sluice_status["seconds_since_last_good"]
  return age <= max_age_seconds if age.is_a?(Numeric)
  last_good = parse_time_safe(sluice_status["last_good_sync"])
  last_good && (Time.now.utc - last_good).to_i <= max_age_seconds
end

def sluice_healthy_for_replication?(sluice_status)
  return false unless sluice_status.is_a?(Hash)
  return false if sluice_status["error"]

  # A maintained CDC position row is the core health signal. The snapshot has
  # finished (initial_copy_phase finished) and sluice recorded a position.
  return false unless sluice_status["initial_copy_phase"] == "finished"
  return false unless sluice_status["current_state"] == "good"
  true
end

def build_cutover_readiness(phase:, sluice_status:)
  unless ["copying", "replicating", "switched"].include?(phase)
    return {
      "level" => "not_ready",
      "can_force" => false,
      "message" => "Cutover is only available once replication is running.",
      "hard_blockers" => [],
      "soft_blockers" => [],
    }
  end

  hard_blockers = []
  soft_blockers = []

  if phase == "replicating" || phase == "copying"
    if sluice_status.nil?
      hard_blockers << "sluice_status_unavailable"
    else
      hard_blockers << "initial_copy_not_finished" if sluice_status["initial_copy_phase"] != "finished"
      soft_blockers << "replication_not_healthy" unless sluice_healthy_for_replication?(sluice_status)
      # A large freshness gap during replicating is a soft blocker: it may just
      # be a quiet source, but warn the operator to confirm before cutover.
      age = sluice_status["seconds_since_last_good"]
      soft_blockers << "replication_lag_high" if age.is_a?(Numeric) && age > 300
    end
  end

  if hard_blockers.any?
    { "level" => "blocked", "can_force" => false, "message" => "Cutover is blocked until safety checks pass.", "hard_blockers" => hard_blockers, "soft_blockers" => soft_blockers }
  elsif soft_blockers.any?
    { "level" => "warning", "can_force" => true, "message" => "Cutover has warnings. You can override if replication appears healthy.", "hard_blockers" => hard_blockers, "soft_blockers" => soft_blockers }
  else
    { "level" => "ready", "can_force" => true, "message" => "Cutover readiness checks passed.", "hard_blockers" => hard_blockers, "soft_blockers" => soft_blockers }
  end
end

# ---------------------------------------------------------------------------
# HTML dashboard
# ---------------------------------------------------------------------------
DASHBOARD_PATH = File.join(__dir__, "dashboard.html")
# Read at boot as a fallback, but re-read per request (below) so a `docker cp`
# of an updated dashboard.html is picked up WITHOUT restarting the server --
# which matters because the status server is this container's PID-1 keep-alive
# (entrypoint.sh `wait`s on it), so restarting it restarts the whole container.
DASHBOARD_HTML = File.read(DASHBOARD_PATH)

def render_dashboard
  # Per-request read so dashboard edits go live on the next page load; fall back
  # to the boot-time copy if the file is transiently unreadable mid-`docker cp`.
  File.read(DASHBOARD_PATH)
rescue StandardError
  DASHBOARD_HTML
end

def sync_process_running?
  return false unless File.exist?(SYNC_PID_FILE)
  pid = File.read(SYNC_PID_FILE).strip.to_i
  return false if pid <= 0
  Process.kill(0, pid)
  true
rescue Errno::ESRCH, Errno::EPERM
  false
rescue StandardError
  false
end

def cdc_position_exists?
  return false unless PLANETSCALE_URL
  row = ps_migrate_query("SELECT 1 FROM sluice_cdc_state WHERE stream_id = '#{STREAM_ID}' LIMIT 1")
  !row.empty?
rescue StandardError
  false
end

def run_script(args)
  output = `sh #{SCRIPTS_DIR}/#{args} 2>&1`
  [output, $?.success?]
end

# ---------------------------------------------------------------------------
# Server setup
# ---------------------------------------------------------------------------
server = WEBrick::HTTPServer.new(Port: PORT, Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO))

# GET /health (no auth)
server.mount_proc "/health" do |req, res|
  res.content_type = "application/json"
  res.body = JSON.generate({ ok: true, timestamp: Time.now.utc.iso8601 })
end

# GET /preflight-checks
server.mount_proc "/preflight-checks" do |req, res|
  require_auth(req, res)
  res.content_type = "application/json"
  tables = check_tables_without_pk_or_unique
  generated = check_tables_with_generated_columns
  res.body = JSON.generate({
    tables_without_pk_or_unique: tables,
    all_tables_valid: tables.empty?,
    tables_with_generated_columns: generated,
  })
end

# GET / (dashboard)
server.mount_proc "/" do |req, res|
  if req.path == "/"
    require_auth(req, res)
    res.content_type = "text/html; charset=utf-8"
    res.body = render_dashboard
  end
end

# GET /status
server.mount_proc "/status" do |req, res|
  require_auth(req, res)
  res.content_type = "application/json"

  base_status = read_status_file
  sluice_status = get_sluice_status
  persisted = read_persistent_state
  persisted_phase = persisted.is_a?(Hash) ? persisted["phase"] : nil

  combined = base_status.merge("sluice" => sluice_status, "timestamp" => Time.now.utc.iso8601)

  # Auto-transition copying -> replicating once a CDC position exists and the
  # stream is healthy. (sluice records a position only after the snapshot
  # completes and the snapshot->CDC handoff succeeds.)
  if sluice_status
    started_at = combined["started_at"]
    if combined["phase"] == "copying"
      if sluice_status["initial_copy_phase"] == "finished" && sluice_healthy_for_replication?(sluice_status)
        File.write(STATUS_FILE, JSON.generate({
          phase: "replicating", state: "running",
          message: "Initial copy complete. Real-time replication is active.",
          error: nil, started_at: started_at,
        }))
        write_persistent_state("replicating", started_at: started_at)
        combined["phase"] = "replicating"
        combined["state"] = "running"
        combined["message"] = "Initial copy complete. Real-time replication is active."
      elsif sluice_status["initial_copy_phase"] == "finished"
        combined["state"] = "copy_health_check_failed"
        combined["message"] = "Initial copy appears complete, but replication health checks are not passing yet."
      end
    end
  end

  combined["cutover_readiness"] = build_cutover_readiness(phase: combined["phase"], sluice_status: sluice_status)
  combined["progress_signals"] = build_progress_signals(phase: combined["phase"], sluice_status: sluice_status, readiness: combined["cutover_readiness"])

  check_milestone_notifications(combined)
  res.body = JSON.generate(combined)
end

# POST /start-migration - install the trigger engine on the source
server.mount_proc "/start-migration" do |req, res|
  require_auth(req, res)
  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end
  res.content_type = "application/json"

  current = read_status_file
  unless current["phase"] == "waiting" || current["phase"] == "unknown"
    res.body = JSON.generate({ success: false, message: "Migration already in progress or completed (phase: #{current["phase"]})" })
    next
  end

  bad_tables = check_tables_without_pk_or_unique
  unless bad_tables.empty?
    res.body = JSON.generate({
      success: false,
      message: "Cannot start migration: #{bad_tables.length} table(s) have no primary key or unique index. " \
               "sluice's trigger engine tracks rows by primary key. Add a primary key or unique index to: #{bad_tables.join(', ')}",
      tables_without_pk_or_unique: bad_tables,
    })
    next
  end

  started_at = Time.now.utc.iso8601
  FileUtils.rm_f(COPY_PROGRESS_FILE)
  File.write(STATUS_FILE, JSON.generate({ phase: "starting", state: "initializing", message: "Starting migration...", error: nil, started_at: started_at }))
  write_persistent_state("starting", started_at: started_at)

  Thread.new do
    begin
      File.write(STATUS_FILE, JSON.generate({
        phase: "configuring", state: "installing_triggers",
        message: "Installing sluice's trigger engine on the Heroku source (change capture begins now)...",
        error: nil, started_at: started_at,
      }))
      write_persistent_state("configuring", started_at: started_at)

      output, success = run_script("mk-sluice-repl.sh --primary \"#{HEROKU_URL}\" --replica \"#{PLANETSCALE_URL}\" --phase configure")
      File.write(SETUP_LOG_FILE, output)

      if success
        File.write(STATUS_FILE, JSON.generate({
          phase: "ready_to_copy", state: "schema_copied",
          message: "Triggers installed and capturing changes. Ready to start data copy.",
          error: nil, started_at: started_at,
        }))
        write_persistent_state("ready_to_copy", started_at: started_at)
      else
        error_msg = output.split("\n").last(5).join(" ").slice(0, 500)
        File.write(STATUS_FILE, JSON.generate({ phase: "error", state: "setup_failed", message: "Trigger-engine setup failed.", error: error_msg, started_at: started_at }))
        write_persistent_state("error", started_at: started_at, error: error_msg)
      end
    rescue => e
      File.write(STATUS_FILE, JSON.generate({ phase: "error", state: "setup_failed", message: "Trigger-engine setup failed with exception.", error: e.message, started_at: started_at }))
      write_persistent_state("error", started_at: started_at, error: e.message)
    end
  end

  res.body = JSON.generate({ success: true, message: "Migration started." })
end

# POST /start-copy - launch `sluice sync start`
server.mount_proc "/start-copy" do |req, res|
  require_auth(req, res)
  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end
  res.content_type = "application/json"

  current = read_status_file
  unless current["phase"] == "ready_to_copy"
    res.body = JSON.generate({ success: false, message: "Not in ready_to_copy phase (current: #{current["phase"]})" })
    next
  end

  started_at = current["started_at"]
  copy_state = capture_table_size_estimates
  write_copy_progress_file(copy_state) if copy_state

  File.write(STATUS_FILE, JSON.generate({ phase: "copying", state: "initial_copy", message: "Copying all rows from Heroku to PlanetScale...", error: nil, started_at: started_at }))
  write_persistent_state("copying", started_at: started_at)

  Thread.new do
    output, success = run_script("mk-sluice-repl.sh --primary \"#{HEROKU_URL}\" --replica \"#{PLANETSCALE_URL}\" --phase copy")
    File.write(SETUP_LOG_FILE, output)
    unless success
      error_msg = output.split("\n").last(8).join(" ").slice(0, 500)
      File.write(STATUS_FILE, JSON.generate({ phase: "error", state: "copy_start_failed", message: "Failed to start initial data copy.", error: error_msg, started_at: started_at }))
      write_persistent_state("error", started_at: started_at, error: error_msg)
    end
  end

  res.body = JSON.generate({ success: true, message: "Data copy request accepted." })
end

# POST /pause-sync - drain + stop the sync process. Triggers stay installed, so
# changes keep queuing in sluice_change_log on the source.
server.mount_proc "/pause-sync" do |req, res|
  require_auth(req, res)
  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end
  res.content_type = "application/json"

  output = `#{SLUICE_BIN} sync stop --target-driver=postgres --target="#{PLANETSCALE_URL}" --stream-id="#{STREAM_ID}" --wait 2>&1`
  success = $?.success?
  FileUtils.rm_f(SYNC_PID_FILE) if success

  if success
    started_at = read_status_file["started_at"]
    File.write(STATUS_FILE, JSON.generate({
      phase: "replicating", state: "paused",
      message: "Sync stopped. Triggers are still active on Heroku -- every write still has trigger overhead and queues in sluice_change_log. Resume drains the queue; to fully remove triggers, use Abort Migration.",
      error: nil, started_at: started_at,
    }))
  end

  res.body = JSON.generate({ success: success, output: output.strip })
end

# POST /resume-sync - relaunch the sync (warm resume from the persisted position)
server.mount_proc "/resume-sync" do |req, res|
  require_auth(req, res)
  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end
  res.content_type = "application/json"

  started_at = read_status_file["started_at"]
  # If a CDC position already exists, the snapshot finished -- warm-resume CDC
  # only. Otherwise the snapshot was interrupted and must restart (same caveat
  # as Bucardo's non-resumable onetimecopy).
  resume_flag = cdc_position_exists? ? "--no-initial-copy" : ""
  output, success = run_script("mk-sluice-repl.sh --primary \"#{HEROKU_URL}\" --replica \"#{PLANETSCALE_URL}\" --phase copy #{resume_flag}")
  File.write(SETUP_LOG_FILE, output)

  if success
    phase = resume_flag.empty? ? "copying" : "replicating"
    state = resume_flag.empty? ? "initial_copy" : "running"
    message = resume_flag.empty? ? "Resuming -- snapshot was interrupted, restarting the initial copy." : "sluice replication is active."
    File.write(STATUS_FILE, JSON.generate({ phase: phase, state: state, message: message, error: nil, started_at: started_at }))
    write_persistent_state(phase, started_at: started_at)
  end

  res.body = JSON.generate({ success: success, output: output.strip })
end

# /count-rows intentionally disabled (expensive on large DBs).
server.mount_proc "/count-rows" do |req, res|
  require_auth(req, res)
  res.status = 410
  res.content_type = "application/json"
  res.body = JSON.generate({ success: false, error: "Row count checks are disabled for safety on large databases. Use `sluice verify --depth=count` out-of-band.", code: "row_counts_disabled" })
end

# GET /logs
server.mount_proc "/logs" do |req, res|
  require_auth(req, res)
  res.content_type = "application/json"
  lines = (req.query["lines"] || "100").to_i
  lines = [lines, 1000].min

  logs = {}
  logs["sync"] = tail_sync_log(lines) if File.exist?(SYNC_LOG_FILE)
  logs["setup"] = (File.read(SETUP_LOG_FILE).scrub rescue "Unable to read setup log") if File.exist?(SETUP_LOG_FILE)
  res.body = JSON.generate(logs)
end

# POST /switch-traffic - REVOKE writes on Heroku, then prime target sequences.
server.mount_proc "/switch-traffic" do |req, res|
  require_auth(req, res)
  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end
  res.content_type = "application/json"

  current = read_status_file
  unless current["phase"] == "replicating"
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Switch traffic is only allowed during replicating phase.", phase: current["phase"] })
    next
  end

  readiness = build_cutover_readiness(phase: current["phase"], sluice_status: get_sluice_status)
  query_params = WEBrick::HTTPUtils.parse_query(req.query_string || "")
  force_override = %w[1 true yes].include?(query_params["force"]&.to_s&.downcase)

  if readiness["level"] == "blocked"
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Cutover is blocked by replication health checks.", code: "cutover_blocked", readiness: readiness })
    next
  end
  if readiness["level"] == "warning" && !force_override
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Cutover requires explicit override due to incomplete verification warnings.", code: "cutover_override_required", readiness: readiness })
    next
  end

  if HEROKU_URL.nil? || HEROKU_URL.empty?
    res.status = 500
    res.body = JSON.generate({ error: "HEROKU_URL not configured" })
    next
  end

  username = HEROKU_URL.split("/")[2]&.split(":")&.first
  if username.nil?
    res.status = 500
    res.body = JSON.generate({ error: "Could not parse username from HEROKU_URL" })
    next
  end

  cmd = "psql \"#{HEROKU_URL}\" -c \"REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM #{username};\""
  output = `#{cmd} 2>&1`
  success = $?.success?

  cutover_output = ""
  if success
    # Writes are now blocked on the source -- the right moment to prime target
    # sequences/identity past the source's max so post-cutover INSERTs on
    # PlanetScale don't collide. Best-effort: a hiccup here doesn't fail the
    # switch (the operator can re-run `sluice cutover` manually).
    cutover_output = `#{SLUICE_BIN} cutover --source-driver=postgres --source="#{HEROKU_URL}" --target-driver=postgres --target="#{PLANETSCALE_URL}" 2>&1`

    switched_at = Time.now.utc.iso8601
    started_at = read_status_file["started_at"]
    File.write(STATUS_FILE, JSON.generate({
      phase: "switched", state: "writes_revoked",
      message: "Write access revoked on Heroku and target sequences primed. Update your app to use PlanetScale.",
      error: nil, started_at: started_at, switched_at: switched_at,
    }))
    write_persistent_state("switched", started_at: started_at, switched_at: switched_at)
  end

  res.body = JSON.generate({ success: success, output: filter_harmless_pg_warnings(output).strip, cutover: cutover_output.strip })
end

# POST /revert-switch
server.mount_proc "/revert-switch" do |req, res|
  require_auth(req, res)
  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end
  res.content_type = "application/json"

  username = HEROKU_URL&.split("/")&.dig(2)&.split(":")&.first
  if username.nil?
    res.status = 500
    res.body = JSON.generate({ error: "Could not parse username from HEROKU_URL" })
    next
  end

  cmd = "psql \"#{HEROKU_URL}\" -c \"GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{username};\""
  output = `#{cmd} 2>&1`
  success = $?.success?

  if success
    started_at = read_status_file["started_at"]
    File.write(STATUS_FILE, JSON.generate({ phase: "replicating", state: "running", message: "Write access restored on Heroku. Replication continues.", error: nil, started_at: started_at }))
    write_persistent_state("replicating", started_at: started_at)
  end

  res.body = JSON.generate({ success: success, output: filter_harmless_pg_warnings(output).strip })
end

# POST /cleanup - Complete Migration: teardown the trigger engine on the source.
server.mount_proc "/cleanup" do |req, res|
  require_auth(req, res)
  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end
  res.content_type = "application/json"

  started_at = read_status_file["started_at"]
  File.write(STATUS_FILE, JSON.generate({ phase: "cleaning_up", state: "removing_replication", message: "Removing sluice replication...", error: nil, started_at: started_at }))
  write_persistent_state("cleaning_up", started_at: started_at)

  Thread.new do
    output, success = run_script("rm-sluice-repl.sh --primary \"#{HEROKU_URL}\" --replica \"#{PLANETSCALE_URL}\"")
    completed_at = Time.now.utc.iso8601
    File.write(STATUS_FILE, JSON.generate({
      phase: success ? "completed" : "error",
      state: success ? "cleanup_complete" : "cleanup_failed",
      message: success ? "Migration complete. sluice replication removed." : "Cleanup failed.",
      error: success ? nil : output,
      started_at: started_at, completed_at: completed_at,
    }))
    write_persistent_state(success ? "completed" : "error", started_at: started_at, completed_at: completed_at, error: success ? nil : output&.slice(0, 500))
  end

  res.body = JSON.generate({ success: true, message: "Cleanup started. Check /status for progress." })
end

# POST /retry - reset to waiting after an error
server.mount_proc "/retry" do |req, res|
  require_auth(req, res)
  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end
  res.content_type = "application/json"

  current = read_status_file
  unless current["phase"] == "error"
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Retry is only available when the migration is in an error state (current phase: #{current["phase"]})." })
    next
  end

  File.write(STATUS_FILE, JSON.generate({ phase: "waiting", state: "ready", message: "Ready to start migration.", error: nil }))
  write_persistent_state("waiting")
  res.body = JSON.generate({ success: true, message: "Migration reset. You can start again when ready." })
end

# POST /abort - emergency teardown from any active phase
server.mount_proc "/abort" do |req, res|
  require_auth(req, res)
  unless req.request_method == "POST"
    res.status = 405
    res.content_type = "application/json"
    res.body = JSON.generate({ error: "Method not allowed" })
    next
  end
  res.content_type = "application/json"

  current = read_status_file
  allowed_phases = %w[configuring ready_to_copy copying replicating error]
  unless allowed_phases.include?(current["phase"])
    res.status = 409
    res.body = JSON.generate({ success: false, error: "Abort is not available in the current phase (#{current["phase"]})." })
    next
  end

  started_at = current["started_at"]
  File.write(STATUS_FILE, JSON.generate({ phase: "cleaning_up", state: "aborting", message: "Aborting migration and removing sluice triggers...", error: nil, started_at: started_at }))
  write_persistent_state("cleaning_up", started_at: started_at)
  notify_slack(":stop_sign: Migration aborted#{branch_tag}")

  Thread.new do
    output, success = run_script("rm-sluice-repl.sh --primary \"#{HEROKU_URL}\" --replica \"#{PLANETSCALE_URL}\"")
    completed_at = Time.now.utc.iso8601
    File.write(STATUS_FILE, JSON.generate({
      phase: success ? "aborted" : "error",
      state: success ? "aborted" : "abort_failed",
      message: success ? "Migration aborted. All sluice triggers have been removed from your Heroku database. We recommend running ANALYZE on your Heroku database to refresh query plan statistics." : "Abort cleanup failed.",
      error: success ? nil : output,
      started_at: started_at, completed_at: completed_at,
    }))
    write_persistent_state(success ? "aborted" : "error", started_at: started_at, completed_at: completed_at, error: success ? nil : output&.slice(0, 500))
  end

  res.body = JSON.generate({ success: true, message: "Abort started. Removing triggers and replication. Check /status for progress." })
end

# ---------------------------------------------------------------------------
# Signal handlers and start
# ---------------------------------------------------------------------------
trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

puts "Status server listening on port #{PORT}..."
server.start
