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
app_file="sops_ntfy_secrets"

domain="$(extract "$secrets_file" '["domain"]')"

cat <<EOF
NTFY_ADMIN_USER=$(extract "$app_file" '["admin_user"]')
NTFY_ADMIN_PASSWORD=$(extract "$app_file" '["admin_password"]')
NTFY_BASE_URL=https://ntfy.${domain}
EOF
