#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/vps-devops/scripts/conference-tool-borg-env
# shellcheck source=/dev/null
source /opt/vps-devops/scripts/conference-tool-backup-env

TOTAL_STEPS=8
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
  [[ "$(docker inspect -f '{{.State.Running}}' "$CT_CONTAINER" 2>/dev/null || true)" == "true" ]]
}

reset_staging_dir() {
  mkdir -p "$CT_STAGING_DIR"
  find "$CT_STAGING_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

require_env BORG_REPO
require_env BORG_PASSPHRASE
require_env BORG_RSH
require_env CT_CONTAINER
require_env CT_DB_VOLUME
require_env CT_STAGING_DIR
require_env CT_ARCHIVE_PREFIX

require_command borg
require_command docker
require_command flock
require_command jq

LOCK_FILE="${CT_STAGING_DIR}.lock"
GLOBAL_LOCK_FILE="/opt/vps-devops/backups/.backup-job.lock"
log_step "Acquiring backup lock at ${LOCK_FILE}"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another conference-tool backup or restore appears to be running." >&2
  exit 1
fi

log_info "Waiting for shared backup lock at ${GLOBAL_LOCK_FILE}"
mkdir -p "$(dirname "$GLOBAL_LOCK_FILE")"
exec 8>"$GLOBAL_LOCK_FILE"
flock 8

restart_container=0

cleanup() {
  local rc=$?

  if [[ $restart_container -eq 1 ]]; then
    log_info "Starting ${CT_CONTAINER} again after interrupted backup..."
    docker start "$CT_CONTAINER" >/dev/null || true
  fi

  log_info "Cleaning staging directory ${CT_STAGING_DIR}"
  reset_staging_dir || true
  exit "$rc"
}

trap cleanup EXIT

log_step "Checking whether data exists in volume ${CT_DB_VOLUME}"
if ! docker run --rm -v "${CT_DB_VOLUME}:/data:ro" alpine:3.22 sh -c 'test -f /data/conference.db' >/dev/null 2>&1; then
  log_info "No database found in volume ${CT_DB_VOLUME}, skipping backup."
  exit 0
fi

log_step "Preparing staging directory ${CT_STAGING_DIR}"
reset_staging_dir
mkdir -p "${CT_STAGING_DIR}/data"

log_step "Checking whether ${CT_CONTAINER} is currently running"
if container_is_running; then
  log_step "Stopping ${CT_CONTAINER} for a consistent backup"
  docker stop "$CT_CONTAINER" >/dev/null
  restart_container=1
else
  log_info "${CT_CONTAINER} is not running; continuing without stopping it first."
fi

log_step "Copying volume data into staging"
docker run --rm \
  -v "${CT_DB_VOLUME}:/data:ro" \
  -v "${CT_STAGING_DIR}/data:/staging" \
  alpine:3.22 sh -c 'cp -a /data/. /staging/'

backup_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hostname_value="$(hostname -f 2>/dev/null || hostname)"
deployed_digest="unknown"
if [[ -f /opt/vps-devops/conference-tool/.last-deployed-digest ]]; then
  deployed_digest="$(tr -d '\n' < /opt/vps-devops/conference-tool/.last-deployed-digest)"
fi

log_step "Writing backup manifest"
jq -n \
  --arg backup_timestamp "$backup_timestamp" \
  --arg hostname "$hostname_value" \
  --arg archive_prefix "$CT_ARCHIVE_PREFIX" \
  --arg db_volume "$CT_DB_VOLUME" \
  --arg container "$CT_CONTAINER" \
  --arg deployed_digest "$deployed_digest" \
  '{
    backup_timestamp: $backup_timestamp,
    hostname: $hostname,
    archive_prefix: $archive_prefix,
    backup_mode: "volume-copy-with-container-stopped",
    db_volume: $db_volume,
    container: $container,
    deployed_digest: $deployed_digest
  }' > "${CT_STAGING_DIR}/manifest.json"

if [[ $restart_container -eq 1 ]]; then
  log_step "Starting ${CT_CONTAINER} again before Borg archival"
  docker start "$CT_CONTAINER" >/dev/null
  restart_container=0
fi

archive_name="${CT_ARCHIVE_PREFIX}-${backup_timestamp}"
archive_name="${archive_name//:/-}"

log_step "Creating Borg archive ${archive_name}"
(
  cd "$CT_STAGING_DIR"
  borg create --compression lz4 --noxattrs "${BORG_REPO}::${archive_name}" .
)

log_step "Pruning conference-tool Borg archives"
borg prune \
  --glob-archives "${CT_ARCHIVE_PREFIX}-*" \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  "$BORG_REPO"

log_info "Conference-tool backup completed successfully."
