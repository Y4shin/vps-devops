#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/vps-devops/scripts/headscale-borg-env
# shellcheck source=/dev/null
source /opt/vps-devops/scripts/headscale-backup-env

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
  [[ "$(docker inspect -f '{{.State.Running}}' "$HS_CONTAINER" 2>/dev/null || true)" == "true" ]]
}

reset_staging_dir() {
  mkdir -p "$HS_STAGING_DIR"
  # Run as root inside a container so files owned by any container UID can be removed
  docker run --rm \
    -v "${HS_STAGING_DIR}:/staging" \
    alpine:3.22 sh -c 'find /staging -mindepth 1 -maxdepth 1 -exec rm -rf {} +'
}

require_env BORG_REPO
require_env BORG_PASSPHRASE
require_env BORG_RSH
require_env HS_CONTAINER
require_env HS_DATA_VOLUME
require_env HS_STAGING_DIR
require_env HS_ARCHIVE_PREFIX

require_command borg
require_command docker
require_command flock
require_command jq

LOCK_FILE="${HS_STAGING_DIR}.lock"
GLOBAL_LOCK_FILE="/opt/vps-devops/backups/.backup-job.lock"
log_step "Acquiring backup lock at ${LOCK_FILE}"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another headscale backup or restore appears to be running." >&2
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
    log_info "Starting ${HS_CONTAINER} again after interrupted backup..."
    docker start "$HS_CONTAINER" >/dev/null || true
  fi

  log_info "Cleaning staging directory ${HS_STAGING_DIR}"
  reset_staging_dir || true
  exit "$rc"
}

trap cleanup EXIT

log_step "Checking whether data exists in volume ${HS_DATA_VOLUME}"
if ! docker run --rm -v "${HS_DATA_VOLUME}:/data:ro" alpine:3.22 sh -c 'test -f /data/db.sqlite' >/dev/null 2>&1; then
  log_info "No db.sqlite found in volume ${HS_DATA_VOLUME}, skipping backup."
  exit 0
fi

log_step "Preparing staging directory ${HS_STAGING_DIR}"
reset_staging_dir
mkdir -p "${HS_STAGING_DIR}/data"

log_step "Checking whether ${HS_CONTAINER} is currently running"
if container_is_running; then
  log_step "Stopping ${HS_CONTAINER} for a consistent backup"
  docker stop "$HS_CONTAINER" >/dev/null
  restart_container=1
else
  log_info "${HS_CONTAINER} is not running; continuing without stopping it first."
fi

log_step "Copying volume data into staging"
DEPLOY_UID="$(id -u)"
DEPLOY_GID="$(id -g)"
docker run --rm \
  -v "${HS_DATA_VOLUME}:/data:ro" \
  -v "${HS_STAGING_DIR}/data:/staging" \
  alpine:3.22 sh -c "cp -a /data/. /staging/ && chown -R ${DEPLOY_UID}:${DEPLOY_GID} /staging/"

backup_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hostname_value="$(hostname -f 2>/dev/null || hostname)"

log_step "Writing backup manifest"
jq -n \
  --arg backup_timestamp "$backup_timestamp" \
  --arg hostname "$hostname_value" \
  --arg archive_prefix "$HS_ARCHIVE_PREFIX" \
  --arg db_volume "$HS_DATA_VOLUME" \
  --arg container "$HS_CONTAINER" \
  '{
    backup_timestamp: $backup_timestamp,
    hostname: $hostname,
    archive_prefix: $archive_prefix,
    backup_mode: "volume-copy-with-container-stopped",
    db_volume: $db_volume,
    container: $container
  }' > "${HS_STAGING_DIR}/manifest.json"

if [[ $restart_container -eq 1 ]]; then
  log_step "Starting ${HS_CONTAINER} again before Borg archival"
  docker start "$HS_CONTAINER" >/dev/null
  restart_container=0
fi

archive_name="${HS_ARCHIVE_PREFIX}-${backup_timestamp}"
archive_name="${archive_name//:/-}"

log_step "Creating Borg archive ${archive_name}"
(
  cd "$HS_STAGING_DIR"
  borg create --compression lz4 --noxattrs "${BORG_REPO}::${archive_name}" .
)

log_step "Pruning headscale Borg archives"
borg prune \
  --glob-archives "${HS_ARCHIVE_PREFIX}-*" \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  "$BORG_REPO"

log_info "Headscale backup completed successfully."
