#!/usr/bin/env ruby
# frozen_string_literal: true

# Thin wrapper that patches hardcoded constants in server.rb so the status
# server can run locally against a temp directory and a fake `sluice` binary.
#
# Usage:
#   TEST_STATE_DIR=/tmp/test_state \
#   PASSWORD=test \
#   DISABLE_AUTH=true \
#   DISABLE_NOTIFICATIONS=true \
#     ruby test/test_server_wrapper.rb

require "fileutils"

state_dir = ENV.fetch("TEST_STATE_DIR")
FileUtils.mkdir_p(state_dir)

scripts_dir = File.join(state_dir, "scripts")
FileUtils.mkdir_p(scripts_dir)

# Write no-op shell scripts so abort/setup/copy don't fail.
%w[mk-sluice-repl.sh rm-sluice-repl.sh stat-sluice-repl.sh].each do |name|
  File.write(File.join(scripts_dir, name), "#!/bin/sh\necho 'fake #{name}'\n")
end

# Write default status file if missing.
unless File.exist?(File.join(state_dir, "status.json"))
  require "json"
  File.write(File.join(state_dir, "status.json"),
    JSON.generate({ phase: "waiting", state: "ready", message: "Ready", error: nil }))
end

# Read server.rb source and patch hardcoded paths.
server_path = File.expand_path("../status-server/server.rb", __dir__)
source = File.read(server_path)

replacements = {
  'STATE_DIR = "/opt/sluice/state"' => "STATE_DIR = #{state_dir.inspect}",
  'SYNC_LOG_FILE = "/var/log/sluice/sync.log"' => "SYNC_LOG_FILE = #{File.join(state_dir, 'sync.log').inspect}",
  'SCRIPTS_DIR = "/opt/sluice/scripts"' => "SCRIPTS_DIR = #{scripts_dir.inspect}",
}

replacements.each do |old, new_val|
  $stderr.puts "WARNING: Could not find '#{old}' in server.rb" unless source.include?(old)
  source = source.sub(old, new_val)
end

# Stub out persistent-state queries (no real PlanetScale DB in unit tests).
source = source.sub(/^def ps_migrate_query\(sql\).*?^end/m, "def ps_migrate_query(sql)\n  \"\"\nend")

eval(source, binding, server_path, 1)
