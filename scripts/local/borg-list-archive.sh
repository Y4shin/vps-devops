#!/usr/bin/env bash
# List the files inside a specific Borg archive.
# Usage: borg-list-archive.sh <service-env-sops-file> <archive-name>
# Example: borg-list-archive.sh reporting-tool/.env.sops.yaml witness-2026-04-08T20-13-45Z
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

all_sops="${repo_root}/ansible/inventories/prod/group_vars/all.sops.yaml"

case "$1" in
  reporting-tool/.env.sops.yaml) service_dict="sops_reporting_tool_secrets" ;;
  authentik/.env.sops.yaml) service_dict="sops_authentik_secrets" ;;
  foundry/.env.sops.yaml) service_dict="sops_foundry_secrets" ;;
  conference-tool/.env.sops.yaml) service_dict="sops_conference_tool_secrets" ;;
  n8n/.env.sops.yaml) service_dict="sops_n8n_secrets" ;;
  mail/.env.sops.yaml) service_dict="sops_mail_secrets" ;;
  *)
    echo "Unknown service env file: $1" >&2
    exit 1
    ;;
esac
archive="$2"

borg_repo="ssh://$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["sops_secrets"]["borg_user"]' "${all_sops}"
)@$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["sops_secrets"]["borg_host"]' "${all_sops}"
):23/$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract "[\"$service_dict\"][\"borg_path\"]" "${all_sops}"
)"
borg_passphrase_value="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract "[\"$service_dict\"][\"borg_passphrase\"]" "${all_sops}"
)"

(
  cd "$repo_root"
  sops exec-file --no-fifo borg/ssh_key.sops \
    "chmod 600 {} && BORG_RSH='ssh -i {} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' BORG_PASSPHRASE='${borg_passphrase_value}' borg list '${borg_repo}::${archive}'"
)
