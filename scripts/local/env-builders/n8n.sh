#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
age_key_file="${repo_root}/age.key"
all_sops="${repo_root}/ansible/inventories/prod/group_vars/all.sops.yaml"

extract() {
  local file="$1" path="$2"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "[\"$file\"]$path" "$all_sops"
}

secrets_file="sops_secrets"
app_file="sops_n8n_secrets"

domain="$(extract "$secrets_file" '["domain"]')"

cat <<EOF
N8N_HOST=n8n.${domain}
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://n8n.${domain}/
N8N_ENCRYPTION_KEY=$(extract "$app_file" '["N8N_ENCRYPTION_KEY"]')
EOF
