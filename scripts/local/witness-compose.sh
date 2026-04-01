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
reporting_tool_secrets_file="${repo_root}/reporting-tool/.env.sops.yaml"

extract_required_secret() {
  local path="$1"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "$path" "$reporting_tool_secrets_file"
}

extract_optional_secret() {
  local path="$1"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "$path" "$reporting_tool_secrets_file" 2>/dev/null || true
}

host="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["all"]["hosts"]["vps"]["ansible_host"]' \
    "${repo_root}/ansible/inventory.sops.yaml"
)"

domain="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["domain"]' "${repo_root}/secrets.sops.yaml"
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
    sops -d --extract '["s3_endpoint"]' "${repo_root}/secrets.sops.yaml"
)
S3_BUCKET=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["s3_bucket"]' "${repo_root}/secrets.sops.yaml"
)
S3_REGION=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["s3_region"]' "${repo_root}/secrets.sops.yaml"
)
S3_ACCESS_KEY_ID=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["S3_ACCESS_KEY_ID"]' "${repo_root}/reporting-tool/.env.sops.yaml"
)
S3_SECRET_ACCESS_KEY=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["S3_SECRET_ACCESS_KEY"]' "${repo_root}/reporting-tool/.env.sops.yaml"
)
EOF
} > "$witness_env_file"

(
  cd "$repo_root"
  sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && scp -o StrictHostKeyChecking=accept-new -i {} \"$witness_env_file\" deploy@${host}:/opt/vps-devops/reporting-tool/.env && ssh -t -i {} deploy@${host} 'bash -lc \"cd /opt/vps-devops/reporting-tool && trap '\''rm -f .env'\'' EXIT && ${remote_command}\"'"
)
