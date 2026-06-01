# syntax=docker/dockerfile:1.7
#
# sluice Heroku -> PlanetScale migrator.
#
# Two stages. The builder compiles the sluice binary from source; the runtime is
# a slim Debian image with just `psql` (for the cutover REVOKE/GRANT + size
# queries) and Ruby (for the dashboard). There is no local PostgreSQL and no
# replication daemon to install -- sluice is a single static Go binary, which is
# the whole reason this image is a fraction of the Bucardo migrator's size.
#
# sluice currently lives in a PRIVATE module (github.com/orware/sluice), so the
# builder needs read access. Provide it as a BuildKit secret at build time:
#
#   DOCKER_BUILDKIT=1 docker build \
#     --secret id=gh_token,env=GH_TOKEN \
#     --build-arg SLUICE_VERSION=v0.97.2 \
#     -t sluice-heroku-migrator .
#
# Offline / vendored alternative: drop a prebuilt linux/amd64 binary at
# ./bin/sluice and build with `--build-arg SLUICE_SOURCE=vendored`.

# ---------------------------------------------------------------------------
# Stage 1: build (or vendor) the sluice binary
# ---------------------------------------------------------------------------
FROM golang:1.25-bookworm AS builder

ARG SLUICE_VERSION=latest
ARG SLUICE_MODULE=github.com/orware/sluice
ARG SLUICE_SOURCE=git
ENV GOPRIVATE=github.com/orware GOFLAGS=-trimpath CGO_ENABLED=0

WORKDIR /build
COPY bin/ /build/bin/

# Build from the private module using a short-lived token secret, OR use a
# vendored binary copied in above. The secret is never written to a layer.
RUN --mount=type=secret,id=gh_token,required=false <<'EOF'
set -e
if [ "$SLUICE_SOURCE" = "vendored" ]; then
  if [ ! -x /build/bin/sluice ]; then
    echo "SLUICE_SOURCE=vendored but ./bin/sluice is missing or not executable" >&2
    exit 1
  fi
  cp /build/bin/sluice /build/sluice
  echo "Using vendored sluice binary."
else
  if [ -f /run/secrets/gh_token ]; then
    git config --global url."https://x-access-token:$(cat /run/secrets/gh_token)@github.com/".insteadOf "https://github.com/"
  fi
  go install "${SLUICE_MODULE}/cmd/sluice@${SLUICE_VERSION}"
  cp "$(go env GOPATH)/bin/sluice" /build/sluice
fi
/build/sluice --version || true
EOF

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
# Ruby tags backtick/File output with the locale encoding; sluice emits UTF-8
# (em-dashes in help/logs). C.UTF-8 is built into glibc (no locale-gen needed)
# and keeps the dashboard from 500-ing on "invalid byte sequence in US-ASCII".
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      postgresql-client \
      ruby \
      ruby-webrick \
      ruby-json \
      procps \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/sluice /usr/local/bin/sluice

# Writable runtime dirs. Heroku runs containers as a random non-root UID, so
# everything the runner touches must be world-writable. (Unlike the Bucardo
# image, we don't need an /etc/passwd entry -- nothing here requires a resolvable
# user; the sluice binary and psql are happy with a bare UID.)
RUN mkdir -p /opt/sluice/state /var/log/sluice && \
    chmod -R 777 /opt/sluice /var/log/sluice

COPY scripts/        /opt/sluice/scripts/
COPY status-server/  /opt/sluice/status-server/
COPY entrypoint.sh   /opt/sluice/entrypoint.sh

RUN chmod +x /opt/sluice/entrypoint.sh /opt/sluice/scripts/*.sh

ENV SLUICE_BIN=sluice \
    SLUICE_STREAM_ID=ps_import \
    SLUICE_STATE_DIR=/opt/sluice/state \
    SLUICE_LOG_DIR=/var/log/sluice

EXPOSE ${PORT:-8080}

ENTRYPOINT ["/opt/sluice/entrypoint.sh"]
