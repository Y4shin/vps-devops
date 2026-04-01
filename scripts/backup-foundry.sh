#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/vps-devops/scripts/foundry-borg-env
# shellcheck source=/dev/null
source /opt/vps-devops/scripts/foundry-backup-env

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
  [[ "$(docker inspect -f '{{.State.Running}}' "$FOUNDRY_CONTAINER" 2>/dev/null || true)" == "true" ]]
}

reset_staging_dir() {
  mkdir -p "$FOUNDRY_BACKUP_STAGING_DIR"
  find "$FOUNDRY_BACKUP_STAGING_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

require_env BORG_REPO
require_env BORG_PASSPHRASE
require_env BORG_RSH
require_env FOUNDRY_ROOT
require_env FOUNDRY_DATA_DIR
require_env FOUNDRY_BACKUP_STAGING_DIR
require_env FOUNDRY_CONTAINER
require_env FOUNDRY_PUBLIC_HOSTNAME
require_env FOUNDRY_ARCHIVE_PREFIX

require_command borg
require_command docker
require_command flock
require_command jq
require_command rsync

LOCK_FILE="${FOUNDRY_DATA_DIR}.lock"
GLOBAL_LOCK_FILE="/opt/vps-devops/backups/.backup-job.lock"
log_step "Acquiring backup lock at ${LOCK_FILE}"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another Foundry backup or restore appears to be running." >&2
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
    log_info "Starting ${FOUNDRY_CONTAINER} again after backup..."
    docker start "$FOUNDRY_CONTAINER" >/dev/null || true
  fi

  log_info "Cleaning staging directory ${FOUNDRY_BACKUP_STAGING_DIR}"
  reset_staging_dir || true
  exit "$rc"
}

trap cleanup EXIT

log_step "Checking whether Foundry data exists in ${FOUNDRY_DATA_DIR}"
if [[ ! -d "${FOUNDRY_DATA_DIR}/Config" && ! -d "${FOUNDRY_DATA_DIR}/Data" ]]; then
  log_info "No Foundry data found yet, skipping backup."
  exit 0
fi

log_step "Preparing staging directory ${FOUNDRY_BACKUP_STAGING_DIR}"
reset_staging_dir
mkdir -p "${FOUNDRY_BACKUP_STAGING_DIR}/data"

log_step "Checking whether ${FOUNDRY_CONTAINER} is currently running"
if container_is_running; then
  log_step "Stopping ${FOUNDRY_CONTAINER} for a consistent backup"
  docker stop "$FOUNDRY_CONTAINER" >/dev/null
  restart_container=1
else
  log_info "${FOUNDRY_CONTAINER} is not running; continuing without stopping it first."
fi

log_step "Staging Foundry data directory"
rsync -a --delete "${FOUNDRY_DATA_DIR}/" "${FOUNDRY_BACKUP_STAGING_DIR}/data/"

backup_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hostname_value="$(hostname -f 2>/dev/null || hostname)"
image_value="$(docker inspect -f '{{.Config.Image}}' "$FOUNDRY_CONTAINER" 2>/dev/null || printf 'unknown')"

log_step "Writing backup manifest"
jq -n \
  --arg backup_timestamp "$backup_timestamp" \
  --arg hostname "$hostname_value" \
  --arg archive_prefix "$FOUNDRY_ARCHIVE_PREFIX" \
  --arg public_hostname "$FOUNDRY_PUBLIC_HOSTNAME" \
  --arg data_dir "$FOUNDRY_DATA_DIR" \
  --arg container "$FOUNDRY_CONTAINER" \
  --arg image "$image_value" \
  '{
    backup_timestamp: $backup_timestamp,
    hostname: $hostname,
    archive_prefix: $archive_prefix,
    backup_mode: "bind-mount-copy-with-container-stopped",
    public_hostname: $public_hostname,
    data_dir: $data_dir,
    container: $container,
    image: $image
  }' > "${FOUNDRY_BACKUP_STAGING_DIR}/manifest.json"

if [[ $restart_container -eq 1 ]]; then
  log_step "Starting ${FOUNDRY_CONTAINER} again before Borg archival"
  docker start "$FOUNDRY_CONTAINER" >/dev/null
  restart_container=0
fi

archive_name="${FOUNDRY_ARCHIVE_PREFIX}-${backup_timestamp}"
archive_name="${archive_name//:/-}"

log_step "Creating Borg archive ${archive_name}"
(
  cd "$FOUNDRY_BACKUP_STAGING_DIR"
  borg create --compression lz4 "${BORG_REPO}::${archive_name}" .
)

log_step "Pruning Foundry Borg archives"
borg prune \
  --glob-archives "${FOUNDRY_ARCHIVE_PREFIX}-*" \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  "$BORG_REPO"

log_info "Foundry backup completed successfully."
