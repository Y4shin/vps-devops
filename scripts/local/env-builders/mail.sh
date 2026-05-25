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

extract_optional() {
  local file="$1" path="$2"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "[\"$file\"]$path" "$all_sops" 2>/dev/null || true
}

secrets_file="sops_secrets"
mail_file="sops_mail_secrets"

domain="$(extract "$secrets_file" '["domain"]')"
mail_domain="$(extract_optional "$mail_file" '["MAIL_DOMAIN"]')"
mail_domain="${mail_domain:-$domain}"
mail_hostname="$(extract_optional "$mail_file" '["MAIL_HOSTNAME"]')"
mail_hostname="${mail_hostname:-mail.${mail_domain}}"
mail_postmaster="$(extract_optional "$mail_file" '["MAIL_POSTMASTER_ADDRESS"]')"
mail_postmaster="${mail_postmaster:-postmaster@${mail_domain}}"

cat <<EOF
OVERRIDE_HOSTNAME=${mail_hostname}
POSTMASTER_ADDRESS=${mail_postmaster}
SMTP_ONLY=1
PERMIT_DOCKER=connected-networks
ENABLE_CLAMAV=0
ENABLE_SPAMASSASSIN=0
ENABLE_FETCHMAIL=0
ENABLE_FAIL2BAN=0
ENABLE_UPDATE_CHECK=0
LOG_LEVEL=info
EOF
