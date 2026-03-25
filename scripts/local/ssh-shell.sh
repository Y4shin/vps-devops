#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

if [[ $# -gt 2 ]]; then
  echo "Usage: $0 [remote-directory] [source-file]" >&2
  exit 1
fi

working_dir="${1:-}"
source_file="${2:-}"

host="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["all"]["hosts"]["vps"]["ansible_host"]' \
    "${repo_root}/ansible/inventory.sops.yaml"
)"

remote_script=""
if [[ -n "$working_dir" ]]; then
  remote_script+="cd $(printf '%q' "$working_dir") && "
fi
if [[ -n "$source_file" ]]; then
  remote_script+="source $(printf '%q' "$source_file") && "
fi
remote_script+="exec bash -i"

remote_script_quoted="$(printf '%q' "$remote_script")"

(
  cd "$repo_root"
  sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && ssh -t -o StrictHostKeyChecking=accept-new -i {} deploy@${host} bash -lc ${remote_script_quoted}"
)
