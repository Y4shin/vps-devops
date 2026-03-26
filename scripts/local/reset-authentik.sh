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

echo "This will permanently delete the current Authentik state on ${host}."
echo "It removes the Authentik containers, the PostgreSQL named volume, local data, certs, and /opt/vps-devops/authentik/.env."
echo
read -r -p "Type the VPS host (${host}) to continue: " confirm_host
if [[ "$confirm_host" != "$host" ]]; then
  echo "Host confirmation did not match. Aborting." >&2
  exit 1
fi

read -r -p "Type RESET AUTHENTIK to confirm destructive reset: " confirm_phrase
if [[ "$confirm_phrase" != "RESET AUTHENTIK" ]]; then
  echo "Confirmation phrase did not match. Aborting." >&2
  exit 1
fi

remote_command="set -euo pipefail && cd /opt/vps-devops/authentik && docker compose down -v && docker run --rm -v /opt/vps-devops/authentik:/work alpine:3.22 sh -c 'rm -rf /work/data /work/certs /work/.env'"
remote_command_quoted="$(printf '%q' "$remote_command")"

(
  cd "$repo_root"
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && ssh -o StrictHostKeyChecking=accept-new -i {} deploy@${host} bash -lc ${remote_command_quoted}"
)
