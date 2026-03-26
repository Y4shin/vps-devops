#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/vps-devops/scripts/authentik-borg-env
# shellcheck source=/dev/null
source /opt/vps-devops/scripts/authentik-backup-env

TOTAL_STEPS=9
CURRENT_STEP=0

log_info() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  log_info "Step ${CURRENT_STEP}/${TOTAL_STEPS}: $*"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Required environment variable '$name' is not set." >&2
    exit 1
  fi
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Required command '$name' is not installed." >&2
    exit 1
  fi
}

container_is_running() {
  local name="$1"
  [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" == "true" ]]
}

reset_backup_tmp_dir() {
  mkdir -p "$AUTHENTIK_BACKUP_TMP_DIR"
  find "$AUTHENTIK_BACKUP_TMP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

require_env BORG_REPO
require_env BORG_PASSPHRASE
require_env BORG_RSH
require_env AUTHENTIK_ROOT
require_env AUTHENTIK_DATA_ROOT
require_env AUTHENTIK_MEDIA_DIR
require_env AUTHENTIK_CERTS_DIR
require_env AUTHENTIK_TEMPLATES_DIR
require_env AUTHENTIK_BACKUP_TMP_DIR
require_env AUTHENTIK_POSTGRES_CONTAINER
require_env AUTHENTIK_SERVER_CONTAINER
require_env AUTHENTIK_WORKER_CONTAINER
require_env AUTHENTIK_ARCHIVE_PREFIX

require_command borg
require_command docker
require_command flock
require_command jq

LOCK_FILE="${AUTHENTIK_DATA_ROOT}.lock"
log_step "Acquiring backup lock at ${LOCK_FILE}"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another Authentik backup or restore appears to be running." >&2
  exit 1
fi

restart_server=0
restart_worker=0

cleanup() {
  local rc=$?

  if [[ $restart_server -eq 1 ]]; then
    log_info "Starting ${AUTHENTIK_SERVER_CONTAINER} again after backup..."
    docker start "$AUTHENTIK_SERVER_CONTAINER" >/dev/null || true
  fi

  if [[ $restart_worker -eq 1 ]]; then
    log_info "Starting ${AUTHENTIK_WORKER_CONTAINER} again after backup..."
    docker start "$AUTHENTIK_WORKER_CONTAINER" >/dev/null || true
  fi

  log_info "Cleaning backup temp directory ${AUTHENTIK_BACKUP_TMP_DIR}"
  reset_backup_tmp_dir || true
  exit "$rc"
}

trap cleanup EXIT

log_step "Preparing Authentik backup temp directory"
reset_backup_tmp_dir

log_step "Stopping Authentik server and worker for a consistent filesystem snapshot"
if container_is_running "$AUTHENTIK_SERVER_CONTAINER"; then
  docker stop "$AUTHENTIK_SERVER_CONTAINER" >/dev/null
  restart_server=1
fi
if container_is_running "$AUTHENTIK_WORKER_CONTAINER"; then
  docker stop "$AUTHENTIK_WORKER_CONTAINER" >/dev/null
  restart_worker=1
fi

log_step "Dumping PostgreSQL database from ${AUTHENTIK_POSTGRES_CONTAINER}"
docker exec "$AUTHENTIK_POSTGRES_CONTAINER" sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > "${AUTHENTIK_BACKUP_TMP_DIR}/postgresql.dump"
chmod 600 "${AUTHENTIK_BACKUP_TMP_DIR}/postgresql.dump"

backup_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hostname_value="$(hostname -f 2>/dev/null || hostname)"

log_step "Writing backup manifest"
jq -n \
  --arg backup_timestamp "$backup_timestamp" \
  --arg hostname "$hostname_value" \
  --arg archive_prefix "$AUTHENTIK_ARCHIVE_PREFIX" \
  --arg media_dir "$AUTHENTIK_MEDIA_DIR" \
  --arg certs_dir "$AUTHENTIK_CERTS_DIR" \
  --arg templates_dir "$AUTHENTIK_TEMPLATES_DIR" \
  '{
    backup_timestamp: $backup_timestamp,
    hostname: $hostname,
    archive_prefix: $archive_prefix,
    backup_mode: "postgres-dump-plus-bind-mounts",
    media_dir: $media_dir,
    certs_dir: $certs_dir,
    templates_dir: $templates_dir
  }' > "${AUTHENTIK_BACKUP_TMP_DIR}/manifest.json"

archive_name="${AUTHENTIK_ARCHIVE_PREFIX}-${backup_timestamp}"
archive_name="${archive_name//:/-}"

log_step "Creating Borg archive ${archive_name}"
(
  cd "$AUTHENTIK_ROOT"
  borg create --compression lz4 "${BORG_REPO}::${archive_name}" \
    data/media \
    data/certs \
    data/custom-templates \
    data/.backup-tmp
)

log_step "Pruning Authentik Borg archives"
borg prune \
  --glob-archives "${AUTHENTIK_ARCHIVE_PREFIX}-*" \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  "$BORG_REPO"

log_step "Cleaning temporary backup files"
reset_backup_tmp_dir

log_info "Authentik backup completed successfully."
