#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/vps-devops/scripts/conference-tool-borg-env
# shellcheck source=/dev/null
source /opt/vps-devops/scripts/conference-tool-backup-env

TOTAL_STEPS=7
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

prompt_read() {
  local prompt="$1"
  local __var_name="$2"
  local response=""

  printf '%s' "$prompt"
  IFS= read -r response || true
  response="${response%$'\r'}"
  printf -v "$__var_name" '%s' "$response"
}

reset_staging_dir() {
  mkdir -p "$CT_STAGING_DIR"
  find "$CT_STAGING_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

select_archive() {
  local selected_archive=""
  local -a archives=()

  log_step "Listing Borg archives for interactive restore selection"
  mapfile -t archives < <(borg list --short "$BORG_REPO" | grep '^'"${CT_ARCHIVE_PREFIX}"'-' || true)
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
        --title "Conference Tool Restore" \
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

confirm_restore() {
  local response=""

  if command -v whiptail >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]; then
    whiptail \
      --title "Conference Tool Restore" \
      --defaultno \
      --yesno "WARNING: You are restoring the conference-tool data volume from a backup archive.\n\nArchive: ${archive_name}\nVolume: ${CT_DB_VOLUME}\n\nThis restore is authoritative.\nAny data currently in the volume but not present in the archive will be removed." \
      20 110 || {
      echo "Restore confirmation not received. Aborting restore." >&2
      exit 1
    }

    whiptail \
      --title "Conference Tool Restore" \
      --defaultno \
      --yesno "FINAL WARNING: this will overwrite the live conference-tool data volume.\n\nProceed with the destructive restore?" \
      16 100 || {
      echo "Final confirmation not received. Aborting restore." >&2
      exit 1
    }
    return
  fi

  echo
  echo "WARNING: You are restoring the conference-tool data volume from a backup archive."
  echo "Archive: ${archive_name}"
  echo "Volume: ${CT_DB_VOLUME}"
  echo
  echo "This restore is authoritative."
  echo "Any data currently in the volume but not present in the archive will be removed."
  echo
  prompt_read "Type the exact archive name to continue: " response
  if [[ "$response" != "$archive_name" ]]; then
    echo "Restore confirmation did not match. Aborting restore." >&2
    exit 1
  fi

  echo
  prompt_read "Type RESTORE EXACTLY to proceed: " response
  if [[ "$response" != "RESTORE EXACTLY" ]]; then
    echo "Final confirmation not received. Aborting restore." >&2
    exit 1
  fi
}

archive_name="${1:-}"

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

LOCK_FILE="${CT_STAGING_DIR}.lock"
GLOBAL_LOCK_FILE="/opt/vps-devops/backups/.backup-job.lock"
log_step "Acquiring restore lock at ${LOCK_FILE}"
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

if [[ -z "$archive_name" ]]; then
  select_archive
fi

confirm_restore

cleanup() {
  reset_staging_dir || true
}

trap cleanup EXIT

log_step "Preparing staging directory ${CT_STAGING_DIR}"
reset_staging_dir

log_step "Extracting Borg archive ${archive_name}"
(
  cd "$CT_STAGING_DIR"
  borg extract "${BORG_REPO}::${archive_name}"
)

log_step "Validating extracted data"
if [[ ! -f "${CT_STAGING_DIR}/data/conference.db" ]]; then
  echo "Selected archive does not contain data/conference.db." >&2
  exit 1
fi

log_step "Stopping ${CT_CONTAINER} before restore"
docker stop "$CT_CONTAINER" >/dev/null 2>&1 || true

log_step "Restoring data volume ${CT_DB_VOLUME}"
docker run --rm \
  -v "${CT_DB_VOLUME}:/data" \
  -v "${CT_STAGING_DIR}/data:/restore:ro" \
  alpine:3.22 sh -c 'rm -rf /data/* && cp -a /restore/. /data/'

log_step "Starting ${CT_CONTAINER} after restore"
docker start "$CT_CONTAINER" >/dev/null

log_info "Conference-tool restore completed successfully."
