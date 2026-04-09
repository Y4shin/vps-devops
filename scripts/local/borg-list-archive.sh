#!/usr/bin/env bash
# List the files inside a specific Borg archive.
# Usage: borg-list-archive.sh <service-env-sops-file> <archive-name>
# Example: borg-list-archive.sh reporting-tool/.env.sops.yaml witness-2026-04-08T20-13-45Z
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

service_env_file="${repo_root}/$1"
archive="$2"

borg_repo="ssh://$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["borg_user"]' "${repo_root}/secrets.sops.yaml"
)@$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["borg_host"]' "${repo_root}/secrets.sops.yaml"
):23/$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["borg_path"]' "${service_env_file}"
)"
borg_passphrase_value="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["borg_passphrase"]' "${service_env_file}"
)"

(
  cd "$repo_root"
  sops exec-file --no-fifo borg/ssh_key.sops \
    "chmod 600 {} && BORG_RSH='ssh -i {} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' BORG_PASSPHRASE='${borg_passphrase_value}' borg list '${borg_repo}::${archive}'"
)
