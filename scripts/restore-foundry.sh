#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /opt/vps-devops/scripts/foundry-borg-env
# shellcheck source=/dev/null
source /opt/vps-devops/scripts/foundry-backup-env

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
  mkdir -p "$FOUNDRY_BACKUP_STAGING_DIR"
  find "$FOUNDRY_BACKUP_STAGING_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

select_archive() {
  local selected_archive=""
  local -a archives=()

  log_step "Listing Borg archives for interactive restore selection"
  mapfile -t archives < <(borg list --short "$BORG_REPO" | grep '^'"${FOUNDRY_ARCHIVE_PREFIX}"'-' || true)
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
        --title "Foundry Restore" \
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
      --title "Foundry Restore" \
      --defaultno \
      --yesno "WARNING: You are restoring the Foundry data directory from a backup archive.\n\nArchive: ${archive_name}\nData dir: ${FOUNDRY_DATA_DIR}\n\nThis restore is authoritative.\nAny files currently in the live Foundry data directory but not present in the archive will be removed." \
      20 110 || {
      echo "Restore confirmation not received. Aborting restore." >&2
      exit 1
    }

    whiptail \
      --title "Foundry Restore" \
      --defaultno \
      --yesno "FINAL WARNING: this will overwrite the live Foundry data directory.\n\nProceed with the destructive restore?" \
      16 100 || {
      echo "Final confirmation not received. Aborting restore." >&2
      exit 1
    }
    return
  fi

  echo
  echo "WARNING: You are restoring the Foundry data directory from a backup archive."
  echo "Archive: ${archive_name}"
  echo "Data dir: ${FOUNDRY_DATA_DIR}"
  echo
  echo "This restore is authoritative."
  echo "Any files currently in the live Foundry data directory but not present in the archive will be removed."
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
require_env FOUNDRY_DATA_DIR
require_env FOUNDRY_BACKUP_STAGING_DIR
require_env FOUNDRY_CONTAINER
require_env FOUNDRY_ARCHIVE_PREFIX

require_command borg
require_command docker
require_command flock
require_command rsync

LOCK_FILE="${FOUNDRY_DATA_DIR}.lock"
GLOBAL_LOCK_FILE="/opt/vps-devops/backups/.backup-job.lock"
log_step "Acquiring restore lock at ${LOCK_FILE}"
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

if [[ -z "$archive_name" ]]; then
  select_archive
fi

confirm_restore

cleanup() {
  reset_staging_dir || true
}

trap cleanup EXIT

log_step "Preparing staging directory ${FOUNDRY_BACKUP_STAGING_DIR}"
reset_staging_dir

log_step "Extracting Borg archive ${archive_name}"
(
  cd "$FOUNDRY_BACKUP_STAGING_DIR"
  borg extract "${BORG_REPO}::${archive_name}"
)

log_step "Validating extracted Foundry data"
if [[ ! -d "${FOUNDRY_BACKUP_STAGING_DIR}/data" ]]; then
  echo "Selected archive does not contain a data directory." >&2
  exit 1
fi

log_step "Stopping ${FOUNDRY_CONTAINER} before restore"
docker stop "$FOUNDRY_CONTAINER" >/dev/null 2>&1 || true

log_step "Restoring Foundry data directory"
mkdir -p "$FOUNDRY_DATA_DIR"
find "$FOUNDRY_DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
rsync -a --delete "${FOUNDRY_BACKUP_STAGING_DIR}/data/" "${FOUNDRY_DATA_DIR}/"

log_step "Starting ${FOUNDRY_CONTAINER} again after restore"
docker start "$FOUNDRY_CONTAINER" >/dev/null

log_info "Foundry restore completed successfully."
