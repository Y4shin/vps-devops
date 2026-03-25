#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/vps-devops/scripts/reporting-tool-borg-env
# shellcheck source=/dev/null
source /opt/vps-devops/scripts/reporting-tool-backup-env

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

reset_staging_dir() {
  mkdir -p "$REPORTING_TOOL_STAGING_DIR"
  find "$REPORTING_TOOL_STAGING_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

select_archive() {
  local selected_archive=""
  local -a archives=()

  log_step "Listing Borg archives for interactive restore selection"
  mapfile -t archives < <(borg list --short "$BORG_REPO")
  if [[ ${#archives[@]} -eq 0 ]]; then
    echo "No Borg archives are available in ${BORG_REPO}." >&2
    exit 1
  fi

  log_info "Borg repository information:"
  borg info "$BORG_REPO"
  echo

  if command -v whiptail >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    local -a menu_items=()
    local archive=""
    for archive in "${archives[@]}"; do
      menu_items+=("$archive" "")
    done

    selected_archive="$(
      whiptail \
        --title "Witness Restore" \
        --menu "Select a Borg archive to restore" \
        20 100 10 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3
    )" || {
      echo "Archive selection cancelled." >&2
      exit 1
    }
  else
    local archive=""
    echo "Available Borg archives:"
    for archive in "${archives[@]}"; do
      echo "  - ${archive}"
    done
    echo

    PS3="Select an archive to restore by number: "
    select selected_archive in "${archives[@]}"; do
      if [[ -n "${selected_archive:-}" ]]; then
        break
      fi
      echo "Please choose a valid archive number." >&2
    done
  fi

  archive_name="$selected_archive"
  echo "Selected archive: ${archive_name}"
}

confirm_authoritative_bucket_restore() {
  local response=""

  echo
  echo "WARNING: You are restoring the reporting-tool bucket from a backup archive."
  echo "Archive: ${archive_name}"
  echo "Bucket: ${S3_BUCKET}"
  echo "Endpoint: ${S3_ENDPOINT}"
  echo
  echo "This restore is authoritative."
  echo "Objects that exist remotely but are not present in the archive WILL BE DELETED."
  echo
  read -r -p "Type the exact bucket name to continue: " response
  if [[ "$response" != "$S3_BUCKET" ]]; then
    echo "Bucket confirmation did not match. Aborting restore." >&2
    exit 1
  fi

  echo
  echo "SECOND WARNING: remote bucket contents will be made to match the archive exactly."
  echo "Any newer or extra objects in ${S3_BUCKET} will be removed."
  echo
  read -r -p "Type DELETE to confirm the destructive S3 sync: " response
  if [[ "$response" != "DELETE" ]]; then
    echo "Deletion confirmation not received. Aborting restore." >&2
    exit 1
  fi

  echo
  echo "FINAL WARNING: this cannot be undone by this script."
  echo "The bucket restore will now run with --delete."
  echo
  read -r -p "Type RESTORE EXACTLY to proceed: " response
  if [[ "$response" != "RESTORE EXACTLY" ]]; then
    echo "Final confirmation not received. Aborting restore." >&2
    exit 1
  fi
}

usage() {
  echo "Usage: $0 [borg-archive-name]" >&2
  exit 1
}

archive_name="${1:-}"
reporting_tool_image=""

require_env BORG_REPO
require_env BORG_PASSPHRASE
require_env BORG_RSH
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

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"

LOCK_FILE="${REPORTING_TOOL_STAGING_DIR}.lock"
log_step "Acquiring restore lock at ${LOCK_FILE}"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another reporting-tool backup or restore appears to be running." >&2
  exit 1
fi

if [[ -z "$archive_name" ]]; then
  select_archive
fi

log_step "Inspecting ${REPORTING_TOOL_CONTAINER} image for restore helper"
reporting_tool_image="$(docker inspect -f '{{.Config.Image}}' "$REPORTING_TOOL_CONTAINER")"
if [[ -z "$reporting_tool_image" ]]; then
  echo "Could not determine image for ${REPORTING_TOOL_CONTAINER}." >&2
  exit 1
fi

log_step "Preparing staging directory ${REPORTING_TOOL_STAGING_DIR}"
reset_staging_dir
trap 'reset_staging_dir' EXIT

log_step "Extracting Borg archive ${archive_name} into staging"
(
  cd "$REPORTING_TOOL_STAGING_DIR"
  borg extract "${BORG_REPO}::${archive_name}"
)

if [[ ! -f "${REPORTING_TOOL_STAGING_DIR}/db/app.db" ]]; then
  echo "Archive ${archive_name} does not contain db/app.db." >&2
  exit 1
fi

mkdir -p "${REPORTING_TOOL_STAGING_DIR}/bucket"

log_step "Requesting confirmation for authoritative restore"
confirm_authoritative_bucket_restore

log_step "Stopping ${REPORTING_TOOL_CONTAINER} before restore"
docker stop "$REPORTING_TOOL_CONTAINER" >/dev/null 2>&1 || true

log_step "Restoring SQLite database into ${REPORTING_TOOL_DB_VOLUME}"
docker run --rm \
  --entrypoint sh \
  --user 0:0 \
  -v "${REPORTING_TOOL_DB_VOLUME}:/data" \
  -v "${REPORTING_TOOL_STAGING_DIR}/db:/restore:ro" \
  "$reporting_tool_image" \
  -c 'cp /restore/app.db /data/app.db && chown app:app /data/app.db && chmod 600 /data/app.db'

log_step "Restoring staged bucket contents into ${S3_BUCKET} with deletion"
aws s3 sync \
  "${REPORTING_TOOL_STAGING_DIR}/bucket" \
  "s3://${S3_BUCKET}" \
  --endpoint-url "$S3_ENDPOINT" \
  --only-show-errors \
  --delete

log_step "Starting ${REPORTING_TOOL_CONTAINER} after restore"
docker start "$REPORTING_TOOL_CONTAINER" >/dev/null

log_info "Restore completed successfully."
