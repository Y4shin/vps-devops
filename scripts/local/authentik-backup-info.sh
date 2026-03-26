#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

borg_repo="ssh://$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["borg_user"]' "${repo_root}/secrets.sops.yaml"
)@$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["borg_host"]' "${repo_root}/secrets.sops.yaml"
):23/$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["borg_path"]' "${repo_root}/authentik/.env.sops.yaml"
)"
borg_passphrase_value="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["borg_passphrase"]' "${repo_root}/authentik/.env.sops.yaml"
)"

(
  cd "$repo_root"
  sops exec-file --no-fifo borg/ssh_key.sops \
    "chmod 600 {} && BORG_RSH='ssh -i {} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' BORG_REPO='${borg_repo}' BORG_PASSPHRASE='${borg_passphrase_value}' borg info \"\$BORG_REPO\" && echo && (BORG_RSH='ssh -i {} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' BORG_REPO='${borg_repo}' BORG_PASSPHRASE='${borg_passphrase_value}' borg list --short \"\$BORG_REPO\" | grep '^authentik-' || true)"
)
