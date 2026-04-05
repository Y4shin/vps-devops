#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

if [[ $# -gt 3 ]]; then
  echo "Usage: $0 [remote-directory] [source-file] [env-builder]" >&2
  echo "" >&2
  echo "  remote-directory  cd into this directory on the server" >&2
  echo "  source-file       source this file before starting bash" >&2
  echo "  env-builder       local script that prints .env content to stdout" >&2
  exit 1
fi

working_dir="${1:-}"
source_file="${2:-}"
env_builder="${3:-}"

host="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["all"]["hosts"]["vps"]["ansible_host"]' \
    "${repo_root}/ansible/inventory.sops.yaml"
)"

local_env_file=""
cleanup() {
  rm -f "$local_env_file"
}
trap cleanup EXIT

# If an env builder script is provided, run it to produce .env content,
# SCP it to the remote working directory, and arrange for cleanup on exit.
scp_cmd=""
remote_cleanup=""
if [[ -n "$env_builder" ]]; then
  local_env_file="$(mktemp /tmp/ssh-shell-env.XXXXXX)"
  bash "$env_builder" > "$local_env_file"

  remote_env_path="${working_dir}/.env"
  scp_cmd="scp -o StrictHostKeyChecking=accept-new -i {} \"${local_env_file}\" deploy@${host}:${remote_env_path} && "
  remote_cleanup="trap 'rm -f ${remote_env_path}' EXIT && "
fi

remote_script=""
if [[ -n "$working_dir" ]]; then
  remote_script+="cd $(printf '%q' "$working_dir") && "
fi
remote_script+="${remote_cleanup}"
if [[ -n "$source_file" ]]; then
  remote_script+="source $(printf '%q' "$source_file") && "
fi
remote_script+="exec bash -i"

remote_script_quoted="$(printf '%q' "$remote_script")"

(
  cd "$repo_root"
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && ${scp_cmd}ssh -t -o StrictHostKeyChecking=accept-new -i {} deploy@${host} ${remote_script_quoted}"
)
