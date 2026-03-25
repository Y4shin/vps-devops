#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

age_pubkey="$(grep -oP 'age1[a-z0-9]+' .sops.yaml | head -1)"
if [[ ! -f age.key ]]; then
  echo "Age key not found at ${repo_root}/age.key"
  echo
  echo "Copy the age private key with public key:"
  echo "  ${age_pubkey}"
  echo "to:"
  echo "  ${repo_root}/age.key"
  exit 1
fi

chmod 600 age.key
echo "Age key present and permissions set to 600."
