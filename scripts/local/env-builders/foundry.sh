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
app_file="${repo_root}/foundry/.env.sops.yaml"

domain="$(extract "$secrets_file" '["domain"]')"

release_url="$(extract_optional "$app_file" '["FOUNDRY_RELEASE_URL"]')"
if [[ -n "$release_url" ]]; then
  echo "FOUNDRY_RELEASE_URL=${release_url}"
else
  echo "FOUNDRY_USERNAME=$(extract "$app_file" '["FOUNDRY_USERNAME"]')"
  echo "FOUNDRY_PASSWORD=$(extract "$app_file" '["FOUNDRY_PASSWORD"]')"
fi

hostname="$(extract_optional "$app_file" '["FOUNDRY_PUBLIC_HOSTNAME"]')"
hostname="${hostname:-foundry.${domain}}"

cat <<EOF
FOUNDRY_ADMIN_KEY=$(extract "$app_file" '["FOUNDRY_ADMIN_KEY"]')
FOUNDRY_HOSTNAME=${hostname}
FOUNDRY_PROXY_PORT=$(extract_optional "$app_file" '["FOUNDRY_PROXY_PORT"]' || echo 443)
FOUNDRY_PROXY_SSL=$(extract_optional "$app_file" '["FOUNDRY_PROXY_SSL"]' || echo true)
FOUNDRY_UPNP=$(extract_optional "$app_file" '["FOUNDRY_UPNP"]' || echo false)
CONTAINER_CACHE=$(extract_optional "$app_file" '["CONTAINER_CACHE"]' || echo /data/container_cache)
CONTAINER_PRESERVE_CONFIG=$(extract_optional "$app_file" '["CONTAINER_PRESERVE_CONFIG"]' || echo false)
TZ=$(extract_optional "$app_file" '["TZ"]' || echo UTC)
EOF

license_key="$(extract_optional "$app_file" '["FOUNDRY_LICENSE_KEY"]')"
[[ -n "$license_key" ]] && echo "FOUNDRY_LICENSE_KEY=${license_key}"

password_salt="$(extract_optional "$app_file" '["FOUNDRY_PASSWORD_SALT"]')"
[[ -n "$password_salt" ]] && echo "FOUNDRY_PASSWORD_SALT=${password_salt}"

world="$(extract_optional "$app_file" '["FOUNDRY_WORLD"]')"
[[ -n "$world" ]] && echo "FOUNDRY_WORLD=${world}"
