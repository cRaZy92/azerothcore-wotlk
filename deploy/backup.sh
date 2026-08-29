#!/usr/bin/env bash
#
# mysqldump of the databases that hold state we cannot rebuild:
# acore_characters (everything players did), acore_auth (accounts, realm) and
# acore_playerbots (selfbot links, custom bot strategies — small, and annoying
# to lose). acore_world is deliberately skipped — ac-db-import recreates it
# from the repo on every deploy.
#
# This sits on top of the Proxmox Backup Server snapshots of the whole CT; it
# exists so a single bad SQL update or a botched deploy can be undone without
# rolling back the entire container.
#
# Cron (root on the Dokploy CT), 04:30 Europe/Bratislava — half an hour before
# the nightly redeploy, so the newest dump predates any breakage a new image
# might introduce:
#   30 4 * * * TZ=Europe/Bratislava /path/to/deploy/backup.sh >> /var/log/ac-backup.log 2>&1

set -euo pipefail

OPS_ENV_FILE="${OPS_ENV_FILE:-/etc/azerothcore/ops.env}"
if [[ -f "$OPS_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$OPS_ENV_FILE"; set +a
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/azerothcore}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
AC_DB_CONTAINER="${AC_DB_CONTAINER:-ac-database}"
AC_COMPOSE_FILE="${AC_COMPOSE_FILE:-}"
DATABASES=(acore_characters acore_auth acore_playerbots)

if [[ -z "${DOCKER_DB_ROOT_PASSWORD:-}" ]]; then
  echo "DOCKER_DB_ROOT_PASSWORD is not set (put it in ${OPS_ENV_FILE})" >&2
  exit 1
fi

log() { printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"; }

# Prefer the fixed container name: it is stable no matter what project name
# Dokploy gives the stack. `docker compose exec` is used instead when
# AC_COMPOSE_FILE is set, e.g. on a host where the stack runs outside Dokploy.
db_exec() {
  if [[ -n "$AC_COMPOSE_FILE" ]]; then
    docker compose --file "$AC_COMPOSE_FILE" exec -T \
      --env "MYSQL_PWD=${DOCKER_DB_ROOT_PASSWORD}" ac-database "$@"
  else
    docker exec --interactive \
      --env "MYSQL_PWD=${DOCKER_DB_ROOT_PASSWORD}" "$AC_DB_CONTAINER" "$@"
  fi
}

mkdir -p "$BACKUP_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"

for db in "${DATABASES[@]}"; do
  target="${BACKUP_DIR}/${db}-${stamp}.sql.gz"
  tmp="${target}.partial"
  log "dumping ${db} -> ${target}"
  # --single-transaction keeps the dump consistent without locking the live
  # server; the tables are InnoDB.
  db_exec mysqldump \
      --user=root \
      --single-transaction \
      --quick \
      --routines \
      --triggers \
      --events \
      --hex-blob \
      --default-character-set=utf8mb4 \
      "$db" \
    | gzip --best > "$tmp"
  mv "$tmp" "$target"
  log "wrote $(du -h "$target" | cut -f1) ${target}"
done

log "pruning dumps older than ${BACKUP_KEEP_DAYS} days"
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'acore_*.sql.gz' \
  -mtime "+${BACKUP_KEEP_DAYS}" -print -delete
# Leftovers from an interrupted run.
find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.sql.gz.partial' -mtime +1 -print -delete

log "done"
