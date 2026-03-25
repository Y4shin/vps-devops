#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <remote-command>" >&2
  exit 1
fi

remote_command="$*"

host="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["all"]["hosts"]["vps"]["ansible_host"]' \
    "${repo_root}/ansible/inventory.sops.yaml"
)"

remote_command_quoted="$(printf '%q' "$remote_command")"

(
  cd "$repo_root"
  sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && ssh -t -o StrictHostKeyChecking=accept-new -i {} deploy@${host} bash -lc ${remote_command_quoted}"
)
