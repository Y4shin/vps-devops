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
app_file="sops_reporting_tool_secrets"

domain="$(extract "$secrets_file" '["domain"]')"

admin_auth_mode="$(extract_optional "$app_file" '["ADMIN_AUTH_MODE"]')"
admin_oidc_client_secret="$(extract_optional "$app_file" '["ADMIN_OIDC_CLIENT_SECRET"]')"

if [[ -z "$admin_auth_mode" ]]; then
  if [[ -n "$admin_oidc_client_secret" ]]; then
    admin_auth_mode="oidc"
  else
    admin_auth_mode="password"
  fi
fi

cat <<EOF
ORIGIN=https://witness.${domain}
DATABASE_URL=file:/data/app.db
SESSION_SECRET=$(extract "$app_file" '["SESSION_SECRET"]')
ADMIN_AUTH_MODE=${admin_auth_mode}
EOF

if [[ "$admin_auth_mode" = "password" ]]; then
  cat <<EOF
ADMIN_PASSWORD=$(extract_optional "$app_file" '["ADMIN_PASSWORD"]')
ADMIN_OIDC_DISCOVERY_URL=
ADMIN_OIDC_CLIENT_ID=
ADMIN_OIDC_CLIENT_SECRET=
ADMIN_OIDC_SCOPES=
ADMIN_OIDC_ALLOWED_EMAILS=
ADMIN_OIDC_ALLOWED_SUBJECTS=
EOF
else
  cat <<EOF
ADMIN_PASSWORD=
ADMIN_OIDC_DISCOVERY_URL=https://authentik.${domain}/application/o/reporting-tool-admin/
ADMIN_OIDC_CLIENT_ID=reporting-tool-admin
ADMIN_OIDC_CLIENT_SECRET=${admin_oidc_client_secret}
ADMIN_OIDC_SCOPES=openid profile email
ADMIN_OIDC_ALLOWED_EMAILS=
ADMIN_OIDC_ALLOWED_SUBJECTS=
ADMIN_OIDC_ALLOWED_GROUPS=reporting-tool-admin-access
EOF
fi

cat <<EOF
LOG_PRETTY=false
S3_ENDPOINT=$(extract "$secrets_file" '["s3_endpoint"]')
S3_BUCKET=$(extract "$secrets_file" '["s3_bucket"]')
S3_REGION=$(extract "$secrets_file" '["s3_region"]')
S3_ACCESS_KEY_ID=$(extract "$app_file" '["S3_ACCESS_KEY_ID"]')
S3_SECRET_ACCESS_KEY=$(extract "$app_file" '["S3_SECRET_ACCESS_KEY"]')
EOF
