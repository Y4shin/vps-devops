#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
age_key_file="${repo_root}/age.key"

extract() {
  local file="$1" path="$2"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "$path" "$file"
}

extract_optional() {
  local file="$1" path="$2"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "$path" "$file" 2>/dev/null || true
}

secrets_file="${repo_root}/secrets.sops.yaml"
mail_file="${repo_root}/mail/.env.sops.yaml"

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
