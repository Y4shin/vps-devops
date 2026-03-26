#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/vps-devops/scripts/reporting-tool-borg-env
# shellcheck source=/dev/null
source /opt/vps-devops/scripts/reporting-tool-backup-env

TOTAL_STEPS=10
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

reset_staging_dir() {
  mkdir -p "$REPORTING_TOOL_STAGING_DIR"
  find "$REPORTING_TOOL_STAGING_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

reporting_tool_is_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$REPORTING_TOOL_CONTAINER" 2>/dev/null || true)" == "true" ]]
}

require_env BORG_REPO
require_env BORG_PASSPHRASE
require_env BORG_RSH
require_env REPORTING_TOOL_COMPOSE_DIR
require_env REPORTING_TOOL_CONTAINER
require_env REPORTING_TOOL_DB_VOLUME
require_env REPORTING_TOOL_STAGING_DIR
require_env S3_ENDPOINT
require_env S3_BUCKET
require_env S3_REGION
require_env S3_ACCESS_KEY_ID
require_env S3_SECRET_ACCESS_KEY

require_command aws
require_command borg
require_command docker
require_command flock
require_command jq

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"

LOCK_FILE="${REPORTING_TOOL_STAGING_DIR}.lock"
log_step "Acquiring backup lock at ${LOCK_FILE}"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another reporting-tool backup or restore appears to be running." >&2
  exit 1
fi

app_restart_required=0

cleanup() {
  local rc=$?

  if [[ $app_restart_required -eq 1 ]]; then
    log_info "Starting ${REPORTING_TOOL_CONTAINER} again after interrupted backup..."
    docker start "$REPORTING_TOOL_CONTAINER" >/dev/null || true
  fi

  log_info "Cleaning staging directory ${REPORTING_TOOL_STAGING_DIR}"
  reset_staging_dir || true
  exit "$rc"
}

trap cleanup EXIT

log_step "Checking whether SQLite database exists in volume ${REPORTING_TOOL_DB_VOLUME}"
if ! docker run --rm -v "${REPORTING_TOOL_DB_VOLUME}:/data:ro" alpine:3.22 sh -c 'test -f /data/app.db' >/dev/null 2>&1; then
  log_info "No database found in volume ${REPORTING_TOOL_DB_VOLUME}, skipping backup."
  exit 0
fi

log_step "Preparing staging directory ${REPORTING_TOOL_STAGING_DIR}"
reset_staging_dir
mkdir -p "$REPORTING_TOOL_STAGING_DIR/db" "$REPORTING_TOOL_STAGING_DIR/bucket"

log_step "Checking whether ${REPORTING_TOOL_CONTAINER} is currently running"
if reporting_tool_is_running; then
  log_step "Stopping ${REPORTING_TOOL_CONTAINER} for snapshot staging"
  docker stop "$REPORTING_TOOL_CONTAINER" >/dev/null
  app_restart_required=1
else
  log_info "${REPORTING_TOOL_CONTAINER} is not running; continuing without stopping it first."
fi

log_step "Copying SQLite database into local staging"
docker run --rm \
  -v "${REPORTING_TOOL_DB_VOLUME}:/data:ro" \
  alpine:3.22 \
  cat /data/app.db > "${REPORTING_TOOL_STAGING_DIR}/db/app.db"
chmod 600 "${REPORTING_TOOL_STAGING_DIR}/db/app.db"

log_step "Mirroring bucket ${S3_BUCKET} into local staging"
aws s3 sync \
  "s3://${S3_BUCKET}" \
  "${REPORTING_TOOL_STAGING_DIR}/bucket" \
  --endpoint-url "$S3_ENDPOINT" \
  --only-show-errors

backup_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hostname_value="$(hostname -f 2>/dev/null || hostname)"
deployed_commit="unknown"
if [[ -f "${REPORTING_TOOL_COMPOSE_DIR}/.last-deployed-commit" ]]; then
  deployed_commit="$(tr -d '\n' < "${REPORTING_TOOL_COMPOSE_DIR}/.last-deployed-commit")"
fi

log_step "Writing backup manifest"
jq -n \
  --arg backup_timestamp "$backup_timestamp" \
  --arg hostname "$hostname_value" \
  --arg bucket "$S3_BUCKET" \
  --arg endpoint "$S3_ENDPOINT" \
  --arg db_volume "$REPORTING_TOOL_DB_VOLUME" \
  --arg container "$REPORTING_TOOL_CONTAINER" \
  --arg deployed_commit "$deployed_commit" \
  '{
    backup_timestamp: $backup_timestamp,
    hostname: $hostname,
    backup_mode: "full-bucket-with-app-stopped",
    s3_bucket: $bucket,
    s3_endpoint: $endpoint,
    db_volume: $db_volume,
    container: $container,
    deployed_commit: $deployed_commit
  }' > "${REPORTING_TOOL_STAGING_DIR}/manifest.json"

if [[ $app_restart_required -eq 1 ]]; then
  log_step "Starting ${REPORTING_TOOL_CONTAINER} again before Borg archive creation"
  docker start "$REPORTING_TOOL_CONTAINER" >/dev/null
  app_restart_required=0
fi

archive_name="reporting-tool-${backup_timestamp}"
archive_name="${archive_name//:/-}"

log_step "Creating Borg archive ${archive_name}"
(
  cd "$REPORTING_TOOL_STAGING_DIR"
  borg create --compression lz4 "${BORG_REPO}::${archive_name}" .
)

log_step "Pruning Borg archives"
borg prune \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 3 \
  "$BORG_REPO"

log_step "Cleaning staged backup data"
reset_staging_dir

log_info "Backup completed successfully."
