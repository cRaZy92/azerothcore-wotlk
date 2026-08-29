#!/usr/bin/env bash
#
# Nightly redeploy trigger for the friends server.
#
# GitHub cannot reach the home Dokploy (the inbound tunnel is geoblocked), so
# deploys are pull-based: this script runs on the Dokploy CT and asks Dokploy
# to redeploy the compose service. Because every AC service carries
# `pull_policy: always`, that fetches the newest `latest` images and recreates
# only the containers whose image actually changed — the database stays up.
#
# Two modes, picked automatically:
#
#   API   (preferred) when DOKPLOY_API_KEY and DOKPLOY_COMPOSE_ID are set.
#   LOCAL (fallback)  when they are not, but AC_COMPOSE_FILE points at the
#                     compose file Dokploy checked out. Runs a plain
#                     `docker compose pull && docker compose up -d`.
#
# Cron (root on the Dokploy CT), 05:00 Europe/Bratislava:
#   0 5 * * * TZ=Europe/Bratislava /path/to/deploy/redeploy.sh >> /var/log/ac-redeploy.log 2>&1
#
# Dokploy >= 0.22 also has a Schedules tab that can run this on the same cron
# without touching the host crontab; see RUNBOOK.md.

set -euo pipefail

# Optional ops-only env file (kept out of Dokploy's Environment tab, which
# would leak these into the containers).
OPS_ENV_FILE="${OPS_ENV_FILE:-/etc/azerothcore/ops.env}"
if [[ -f "$OPS_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$OPS_ENV_FILE"; set +a
fi

DOKPLOY_URL="${DOKPLOY_URL:-http://localhost:3000}"
DOKPLOY_API_KEY="${DOKPLOY_API_KEY:-}"
DOKPLOY_COMPOSE_ID="${DOKPLOY_COMPOSE_ID:-}"
AC_COMPOSE_FILE="${AC_COMPOSE_FILE:-}"

log() { printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }

dokploy_call() {
  # $1 = endpoint (e.g. compose.redeploy). Echoes the response body, returns
  # the curl exit status; the HTTP status is appended as the last line.
  local endpoint="$1"
  curl --silent --show-error --fail-with-body \
       --max-time 120 \
       --request POST "${DOKPLOY_URL%/}/api/${endpoint}" \
       --header 'Content-Type: application/json' \
       --header "x-api-key: ${DOKPLOY_API_KEY}" \
       --data "{\"composeId\":\"${DOKPLOY_COMPOSE_ID}\"}"
}

redeploy_via_api() {
  local endpoint response
  # compose.redeploy is the documented "pull and recreate" call. Older builds
  # only expose compose.deploy, so fall back to it.
  for endpoint in compose.redeploy compose.deploy; do
    log "POST ${DOKPLOY_URL%/}/api/${endpoint} (composeId=${DOKPLOY_COMPOSE_ID})"
    if response="$(dokploy_call "$endpoint")"; then
      log "ok: ${response:-<empty body>}"
      return 0
    fi
    log "failed on ${endpoint}: ${response:-<no body>}"
  done
  return 1
}

redeploy_via_compose() {
  log "docker compose pull && up -d against ${AC_COMPOSE_FILE}"
  docker compose --file "$AC_COMPOSE_FILE" pull
  docker compose --file "$AC_COMPOSE_FILE" up --detach --remove-orphans
  log "ok"
}

if [[ -n "$DOKPLOY_API_KEY" && -n "$DOKPLOY_COMPOSE_ID" ]]; then
  if redeploy_via_api; then
    exit 0
  fi
  log "Dokploy API failed"
  if [[ -z "$AC_COMPOSE_FILE" ]]; then
    exit 1
  fi
  log "falling back to local compose"
fi

if [[ -z "$AC_COMPOSE_FILE" ]]; then
  log "nothing to do: set DOKPLOY_API_KEY + DOKPLOY_COMPOSE_ID, or AC_COMPOSE_FILE"
  exit 1
fi

redeploy_via_compose
