#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

source_spec="${SOURCE:-}"
delete_mode="${DELETE:-}"
source_ssh_key="${SOURCE_SSH_KEY:-}"
source_ssh_port="${SOURCE_SSH_PORT:-22}"
source_compose_dir="${SOURCE_COMPOSE_DIR:-}"
source_compose_service="${SOURCE_COMPOSE_SERVICE:-foundry}"
target_host=""
target_dir="/opt/vps-devops/foundry/data"
target_container="foundry-foundry-1"

usage() {
  cat >&2 <<'EOF'
Usage:
  SOURCE=/path/to/foundry-data bash ./scripts/local/migrate-foundry-data.sh
  SOURCE=user@old-host:/path/to/data/foundry DELETE=1 bash ./scripts/local/migrate-foundry-data.sh

Optional environment variables:
  DELETE=1                    Mirror the source exactly on the VPS with rsync --delete
  SOURCE_SSH_KEY=...          SSH key to use when SOURCE is a remote rsync source
  SOURCE_SSH_PORT=22          SSH port to use when SOURCE is a remote rsync source
  SOURCE_COMPOSE_DIR=...      docker compose project directory on the source host;
                              when set, the script stops SOURCE_COMPOSE_SERVICE before
                              syncing and leaves it stopped
  SOURCE_COMPOSE_SERVICE=...  compose service name to stop (default: foundry)
EOF
  exit 1
}

log_info() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Required command '$name' is not installed." >&2
    exit 1
  fi
}

if [[ -z "$source_spec" ]]; then
  usage
fi

require_command rsync
require_command ssh
require_command sops

target_host="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["all"]["hosts"]["vps"]["ansible_host"]' \
    "${repo_root}/ansible/inventory.sops.yaml"
)"

tmp_dir="$(mktemp -d)"
stage_dir="${tmp_dir}/data"

cleanup() {
  rm -rf "$tmp_dir"
}

trap cleanup EXIT INT TERM

mkdir -p "$stage_dir"

if [[ -d "$source_spec" ]]; then
  log_info "Staging Foundry data from local path ${source_spec}"
  rsync -a --delete --info=progress2 "${source_spec%/}/" "${stage_dir}/"
elif [[ "$source_spec" == *:* ]]; then
  source_host="${source_spec%%:*}"
  source_rsh=(ssh -p "$source_ssh_port" -o StrictHostKeyChecking=accept-new)
  if [[ -n "$source_ssh_key" ]]; then
    source_rsh+=(-i "$source_ssh_key")
  fi

  if [[ -n "$source_compose_dir" ]]; then
    log_info "Stopping ${source_compose_service} on ${source_host} (will remain stopped)"
    "${source_rsh[@]}" "$source_host" \
      "cd $(printf '%q' "$source_compose_dir") && docker compose stop $(printf '%q' "$source_compose_service")"
  fi

  log_info "Staging Foundry data from remote source ${source_spec}"
  rsync -a --delete --info=progress2 -e "$(printf '%q ' "${source_rsh[@]}")" "${source_spec%/}/" "${stage_dir}/"
else
  echo "SOURCE must be an existing local directory or a remote rsync source like user@host:/path." >&2
  exit 1
fi

if [[ ! -d "${stage_dir}/Config" && ! -d "${stage_dir}/Data" ]]; then
  echo "Staged source does not look like a Foundry data directory. Expected Config/ or Data/ at the root." >&2
  exit 1
fi

delete_flag=()
if [[ "$delete_mode" == "1" ]]; then
  delete_flag+=(--delete)
  log_info "DELETE=1 set; destination will be mirrored exactly."
else
  log_info "DELETE not set; destination files not present in the staged source will be preserved."
fi

log_info "Stopping ${target_container} on ${target_host} before sync"
(
  cd "$repo_root"
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && ssh -o StrictHostKeyChecking=accept-new -i {} deploy@${target_host} $(printf '%q' "mkdir -p ${target_dir} && docker stop ${target_container} >/dev/null 2>&1 || true")"
)

log_info "Syncing staged Foundry data to deploy@${target_host}:${target_dir}"
(
  cd "$repo_root"
  rsync_flags_quoted="$(printf ' %q' "${delete_flag[@]}")"
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && rsync -a --info=progress2${rsync_flags_quoted} -e 'ssh -o StrictHostKeyChecking=accept-new -i {}' $(printf '%q' "${stage_dir}/") deploy@${target_host}:${target_dir}/"
)

log_info "Starting ${target_container} on ${target_host} after sync"
(
  cd "$repo_root"
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && ssh -o StrictHostKeyChecking=accept-new -i {} deploy@${target_host} $(printf '%q' "docker start ${target_container} >/dev/null 2>&1 || true")"
)

log_info "Foundry data migration sync completed."
