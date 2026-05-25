#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <up|down>" >&2
  exit 1
}

action="${1:-}"
case "$action" in
  up)
    remote_command="docker compose up -d"
    ;;
  down)
    remote_command="docker compose down"
    ;;
  *)
    usage
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"
all_sops="${repo_root}/ansible/inventories/prod/group_vars/all.sops.yaml"
reporting_tool_secrets_file="sops_reporting_tool_secrets"

extract_required_secret() {
  local path="$1"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "[\"$reporting_tool_secrets_file\"]$path" "$all_sops"
}

extract_optional_secret() {
  local path="$1"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "[\"$reporting_tool_secrets_file\"]$path" "$all_sops" 2>/dev/null || true
}

host="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["sops_connection"]["ansible_host"]' \
    "$all_sops"
)"

domain="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["sops_secrets"]["domain"]' "$all_sops"
)"

admin_auth_mode="$(extract_optional_secret '["ADMIN_AUTH_MODE"]')"
admin_password="$(extract_optional_secret '["ADMIN_PASSWORD"]')"
admin_oidc_client_secret="$(extract_optional_secret '["ADMIN_OIDC_CLIENT_SECRET"]')"

if [ -z "$admin_auth_mode" ]; then
  if [ -n "$admin_oidc_client_secret" ]; then
    admin_auth_mode="oidc"
  else
    admin_auth_mode="password"
  fi
fi

if [ "$admin_auth_mode" = "password" ] && [ -z "$admin_password" ]; then
  echo "ADMIN_PASSWORD is required for Witness password admin auth." >&2
  exit 1
fi

if [ "$admin_auth_mode" = "oidc" ]; then
  if [ -z "$admin_oidc_client_secret" ]; then
    echo "ADMIN_OIDC_CLIENT_SECRET is required for Witness OIDC admin auth." >&2
    exit 1
  fi
fi

witness_env_file="$(mktemp /tmp/witness-env.XXXXXX)"
cleanup() {
  rm -f "$witness_env_file"
}
trap cleanup EXIT

{
cat <<EOF
ORIGIN=https://witness.${domain}
DATABASE_URL=file:/data/app.db
SESSION_SECRET=$(extract_required_secret '["SESSION_SECRET"]')
ADMIN_AUTH_MODE=${admin_auth_mode}
EOF

if [ "$admin_auth_mode" = "password" ]; then
cat <<EOF
ADMIN_PASSWORD=${admin_password}
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
S3_ENDPOINT=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["sops_secrets"]["s3_endpoint"]' "$all_sops"
)
S3_BUCKET=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["sops_secrets"]["s3_bucket"]' "$all_sops"
)
S3_REGION=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["sops_secrets"]["s3_region"]' "$all_sops"
)
S3_ACCESS_KEY_ID=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["sops_reporting_tool_secrets"]["S3_ACCESS_KEY_ID"]' "$all_sops"
)
S3_SECRET_ACCESS_KEY=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["sops_reporting_tool_secrets"]["S3_SECRET_ACCESS_KEY"]' "$all_sops"
)
EOF
} > "$witness_env_file"

(
  cd "$repo_root"
  sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && scp -o StrictHostKeyChecking=accept-new -i {} \"$witness_env_file\" deploy@${host}:/opt/vps-devops/reporting-tool/.env && ssh -t -i {} deploy@${host} 'bash -lc \"cd /opt/vps-devops/reporting-tool && trap '\''rm -f .env'\'' EXIT && ${remote_command}\"'"
)
