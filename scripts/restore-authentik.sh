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

prompt_read() {
  local prompt="$1"
  local __var_name="$2"
  local response=""

  printf '%s' "$prompt"
  IFS= read -r response || true

  response="${response%$'\r'}"
  printf -v "$__var_name" '%s' "$response"
}

reset_restore_staging_dir() {
  mkdir -p "$AUTHENTIK_RESTORE_STAGING_DIR"
  find "$AUTHENTIK_RESTORE_STAGING_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

select_archive() {
  local selected_archive=""
  local -a archives=()

  log_step "Listing Authentik Borg archives for restore selection"
  mapfile -t archives < <(borg list --short "$BORG_REPO" | grep "^${AUTHENTIK_ARCHIVE_PREFIX}-" || true)
  if [[ ${#archives[@]} -eq 0 ]]; then
    echo "No Authentik Borg archives are available in ${BORG_REPO}." >&2
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
        --title "Authentik Restore" \
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
    echo "Available Authentik Borg archives:"
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
      --title "Authentik Restore" \
      --defaultno \
      --yesno "WARNING: You are restoring Authentik from a backup archive.\n\nArchive: ${archive_name}\n\nThis will replace the current Authentik database, media, certs, and custom templates." \
      18 100 || {
      echo "Confirmation cancelled. Aborting restore." >&2
      exit 1
    }

    whiptail \
      --title "Authentik Restore" \
      --defaultno \
      --yesno "FINAL WARNING: existing Authentik state on this host will be overwritten.\n\nArchive: ${archive_name}\n\nProceed with the destructive restore?" \
      18 100 || {
      echo "Final confirmation not received. Aborting restore." >&2
      exit 1
    }
    return
  fi

  echo
  echo "WARNING: You are restoring Authentik from a backup archive."
  echo "Archive: ${archive_name}"
  echo "This will replace the current Authentik database, media, certs, and custom templates."
  echo
  prompt_read "Type AUTHENTIK to continue: " response
  if [[ "$response" != "AUTHENTIK" ]]; then
    echo "Confirmation did not match. Aborting restore." >&2
    exit 1
  fi

  echo
  echo "SECOND WARNING: existing Authentik state on this host will be overwritten."
  echo
  prompt_read "Type RESTORE AUTHENTIK to proceed: " response
  if [[ "$response" != "RESTORE AUTHENTIK" ]]; then
    echo "Final confirmation not received. Aborting restore." >&2
    exit 1
  fi
}

restore_directory() {
  local src="$1"
  local dest="$2"

  rm -rf "$dest"
  mkdir -p "$dest"
  if [[ -d "$src" ]]; then
    cp -a "$src"/. "$dest"/
  fi
}

archive_name="${1:-}"

require_env BORG_REPO
require_env BORG_PASSPHRASE
require_env BORG_RSH
require_env AUTHENTIK_ROOT
require_env AUTHENTIK_DATA_ROOT
require_env AUTHENTIK_MEDIA_DIR
require_env AUTHENTIK_CERTS_DIR
require_env AUTHENTIK_TEMPLATES_DIR
require_env AUTHENTIK_RESTORE_STAGING_DIR
require_env AUTHENTIK_POSTGRES_CONTAINER
require_env AUTHENTIK_SERVER_CONTAINER
require_env AUTHENTIK_WORKER_CONTAINER
require_env AUTHENTIK_ARCHIVE_PREFIX

require_command borg
require_command docker
require_command flock

LOCK_FILE="${AUTHENTIK_DATA_ROOT}.lock"
log_step "Acquiring restore lock at ${LOCK_FILE}"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another Authentik backup or restore appears to be running." >&2
  exit 1
fi

if [[ -z "$archive_name" ]]; then
  select_archive
fi

log_step "Preparing restore staging directory ${AUTHENTIK_RESTORE_STAGING_DIR}"
reset_restore_staging_dir
trap 'reset_restore_staging_dir' EXIT

log_step "Extracting Borg archive ${archive_name} into staging"
(
  cd "$AUTHENTIK_RESTORE_STAGING_DIR"
  borg extract "${BORG_REPO}::${archive_name}"
)

if [[ ! -f "${AUTHENTIK_RESTORE_STAGING_DIR}/data/.backup-tmp/postgresql.dump" ]]; then
  echo "Archive ${archive_name} does not contain data/.backup-tmp/postgresql.dump." >&2
  exit 1
fi

log_step "Requesting confirmation for destructive restore"
confirm_restore

log_step "Stopping Authentik application containers"
docker stop "$AUTHENTIK_SERVER_CONTAINER" >/dev/null 2>&1 || true
docker stop "$AUTHENTIK_WORKER_CONTAINER" >/dev/null 2>&1 || true

log_step "Restoring Authentik bind-mounted directories"
restore_directory "${AUTHENTIK_RESTORE_STAGING_DIR}/data/media" "$AUTHENTIK_MEDIA_DIR"
restore_directory "${AUTHENTIK_RESTORE_STAGING_DIR}/data/certs" "$AUTHENTIK_CERTS_DIR"
restore_directory "${AUTHENTIK_RESTORE_STAGING_DIR}/data/custom-templates" "$AUTHENTIK_TEMPLATES_DIR"

log_step "Starting PostgreSQL container for database restore"
docker start "$AUTHENTIK_POSTGRES_CONTAINER" >/dev/null 2>&1 || true

log_step "Waiting for PostgreSQL readiness"
until docker exec "$AUTHENTIK_POSTGRES_CONTAINER" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_isready -d "$POSTGRES_DB" -U "$POSTGRES_USER"' >/dev/null 2>&1; do
  sleep 2
done

log_step "Resetting Authentik database"
docker exec "$AUTHENTIK_POSTGRES_CONTAINER" sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" dropdb -U "$POSTGRES_USER" --if-exists "$POSTGRES_DB" && PGPASSWORD="$POSTGRES_PASSWORD" createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'

log_step "Restoring PostgreSQL dump into Authentik database"
docker exec -i "$AUTHENTIK_POSTGRES_CONTAINER" sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges --exit-on-error' \
  < "${AUTHENTIK_RESTORE_STAGING_DIR}/data/.backup-tmp/postgresql.dump"

log_step "Starting Authentik application containers"
docker start "$AUTHENTIK_SERVER_CONTAINER" >/dev/null
docker start "$AUTHENTIK_WORKER_CONTAINER" >/dev/null

log_info "Authentik restore completed successfully."
