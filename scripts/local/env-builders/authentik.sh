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

authentik_file="sops_authentik_secrets"
secrets_file="sops_secrets"
mail_file="sops_mail_secrets"

pg_pass="$(extract "$authentik_file" '["PG_PASS"]')"
secret_key="$(extract "$authentik_file" '["AUTHENTIK_SECRET_KEY"]')"
bootstrap_password="$(extract "$authentik_file" '["AUTHENTIK_BOOTSTRAP_PASSWORD"]')"
bootstrap_email="$(SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_BOOTSTRAP_EMAIL"]' "$all_sops" 2>/dev/null || true)"

# Get deploy user UID/GID from the server via a quick SSH call
deploy_uid="$(id -u 2>/dev/null || echo 1000)"
deploy_gid="$(id -g 2>/dev/null || echo 1000)"

cat <<EOF
PG_PASS=${pg_pass}
AUTHENTIK_SECRET_KEY=${secret_key}
AUTHENTIK_BOOTSTRAP_PASSWORD=${bootstrap_password}
${bootstrap_email:+AUTHENTIK_BOOTSTRAP_EMAIL=${bootstrap_email}}
AUTHENTIK_ERROR_REPORTING__ENABLED=true
AUTHENTIK_IMAGE=ghcr.io/goauthentik/server
AUTHENTIK_TAG=2026.2.1
EOF

if SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract '["sops_mail_secrets"]' "$all_sops" >/dev/null 2>&1; then
  domain="$(extract "$secrets_file" '["domain"]')"
  mail_domain="$(SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract '["sops_mail_secrets"]["MAIL_DOMAIN"]' "$all_sops" 2>/dev/null || echo "$domain")"
  mail_from="$(SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract '["sops_mail_secrets"]["MAIL_AUTHENTIK_FROM"]' "$all_sops" 2>/dev/null || echo "authentik@${mail_domain}")"
  cat <<EOF
AUTHENTIK_EMAIL__HOST=mailserver
AUTHENTIK_EMAIL__PORT=25
AUTHENTIK_EMAIL__USERNAME=
AUTHENTIK_EMAIL__PASSWORD=
AUTHENTIK_EMAIL__USE_TLS=false
AUTHENTIK_EMAIL__USE_SSL=false
AUTHENTIK_EMAIL__TIMEOUT=10
AUTHENTIK_EMAIL__FROM=${mail_from}
EOF
fi
