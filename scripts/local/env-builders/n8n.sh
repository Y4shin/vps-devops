#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
age_key_file="${repo_root}/age.key"

extract() {
  local file="$1" path="$2"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "$path" "$file"
}

secrets_file="${repo_root}/secrets.sops.yaml"
app_file="${repo_root}/n8n/.env.sops.yaml"

domain="$(extract "$secrets_file" '["domain"]')"

cat <<EOF
N8N_HOST=n8n.${domain}
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://n8n.${domain}/
N8N_ENCRYPTION_KEY=$(extract "$app_file" '["N8N_ENCRYPTION_KEY"]')
EOF
