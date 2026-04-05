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
app_file="${repo_root}/conference-tool/.env.sops.yaml"

domain="$(extract "$secrets_file" '["domain"]')"

cat <<EOF
ENVIRONMENT=production
HOST=0.0.0.0
PORT=8080
LOG_FORMAT=json
LOG_LEVEL=info
SERVICE_NAME=conference-tool
SESSION_SECRET=$(extract "$app_file" '["SESSION_SECRET"]')
SESSION_EXPIRATION=86400
DATABASE_PATH=/data/conference.db
STORAGE_DIR=/data/uploads
AUTH_PASSWORD_ENABLED=false
AUTH_OAUTH_ENABLED=true
OAUTH_ISSUER_URL=https://authentik.${domain}/application/o/conference-tool/
OAUTH_CLIENT_ID=conference-tool
OAUTH_CLIENT_SECRET=$(extract "$app_file" '["OAUTH_CLIENT_SECRET"]')
OAUTH_REDIRECT_URL=https://conference.${domain}/oauth/callback
OAUTH_SCOPES=openid,profile,email
OAUTH_GROUPS_CLAIM=groups
OAUTH_USERNAME_CLAIMS=preferred_username,email,sub
OAUTH_FULL_NAME_CLAIMS=name,preferred_username,email
OAUTH_PROVISIONING_MODE=auto_create
OAUTH_REQUIRED_GROUPS=conference-user
OAUTH_ADMIN_GROUP=conference-admin
EOF
