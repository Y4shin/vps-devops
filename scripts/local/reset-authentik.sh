#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

host="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["all"]["hosts"]["vps"]["ansible_host"]' \
    "${repo_root}/ansible/inventory.sops.yaml"
)"

remote_command="set -euo pipefail && cd /opt/vps-devops/authentik && docker compose down -v && docker run --rm -v /opt/vps-devops/authentik:/work alpine:3.22 sh -c 'rm -rf /work/data /work/certs /work/.env'"
remote_command_quoted="$(printf '%q' "$remote_command")"

(
  cd "$repo_root"
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && ssh -o StrictHostKeyChecking=accept-new -i {} deploy@${host} bash -lc ${remote_command_quoted}"
)
