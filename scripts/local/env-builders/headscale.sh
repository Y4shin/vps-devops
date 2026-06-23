#!/usr/bin/env bash
set -euo pipefail

# Prints the headscale .env content for `task ssh:headscale`. Mirrors the env the
# ansible role writes: just the OIDC client secret, which viper binds onto
# oidc.client_secret. Everything else lives in the persisted config.yaml.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
age_key_file="${repo_root}/age.key"
all_sops="${repo_root}/ansible/inventories/prod/group_vars/all.sops.yaml"

extract() {
  local file="$1" path="$2"
  SOPS_AGE_KEY_FILE="$age_key_file" sops -d --extract "[\"$file\"]$path" "$all_sops"
}

cat <<EOF
HEADSCALE_OIDC_CLIENT_SECRET=$(extract "sops_headscale_secrets" '["OIDC_CLIENT_SECRET"]')
EOF
