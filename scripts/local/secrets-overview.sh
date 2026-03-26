#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
cd "$repo_root"

pager="${PAGER:-less}"
if ! command -v "$pager" >/dev/null 2>&1; then
  pager="cat"
fi

{
  echo "Reporting Tool"
  echo "=============="
  printf 'Admin password: %s\n' "$(sops -d --extract '["ADMIN_PASSWORD"]' reporting-tool/.env.sops.yaml)"
  printf 'Session secret: %s\n' "$(sops -d --extract '["SESSION_SECRET"]' reporting-tool/.env.sops.yaml)"
  printf 'S3 access key id: %s\n' "$(sops -d --extract '["S3_ACCESS_KEY_ID"]' reporting-tool/.env.sops.yaml)"
  printf 'S3 secret access key: %s\n' "$(sops -d --extract '["S3_SECRET_ACCESS_KEY"]' reporting-tool/.env.sops.yaml)"
  printf 'Borg path: %s\n' "$(sops -d --extract '["borg_path"]' reporting-tool/.env.sops.yaml)"
  printf 'Borg passphrase: %s\n' "$(sops -d --extract '["borg_passphrase"]' reporting-tool/.env.sops.yaml)"
  echo
  echo "Global Infra"
  echo "============"
  printf 'Domain: %s\n' "$(sops -d --extract '["domain"]' secrets.sops.yaml)"
  printf 'LetsEncrypt email: %s\n' "$(sops -d --extract '["letsencrypt_email"]' secrets.sops.yaml)"
  printf 'S3 endpoint: %s\n' "$(sops -d --extract '["s3_endpoint"]' secrets.sops.yaml)"
  printf 'S3 bucket: %s\n' "$(sops -d --extract '["s3_bucket"]' secrets.sops.yaml)"
  printf 'S3 region: %s\n' "$(sops -d --extract '["s3_region"]' secrets.sops.yaml)"
  printf 'Borg host: %s\n' "$(sops -d --extract '["borg_host"]' secrets.sops.yaml)"
  printf 'Borg user: %s\n' "$(sops -d --extract '["borg_user"]' secrets.sops.yaml)"
  echo
  echo "Traefik"
  echo "======="
  printf 'Dashboard user: %s\n' "$(sops -d --extract '["TRAEFIK_DASHBOARD_USER"]' traefik/.env.sops.yaml)"
  if [ -f authentik/.env.sops.yaml ]; then
    echo
    echo "Authentik"
    echo "========="
    printf 'Bootstrap password: %s\n' "$(sops -d --extract '["AUTHENTIK_BOOTSTRAP_PASSWORD"]' authentik/.env.sops.yaml)"
    if sops -d --extract '["AUTHENTIK_BOOTSTRAP_EMAIL"]' authentik/.env.sops.yaml >/dev/null 2>&1; then
      printf 'Bootstrap email: %s\n' "$(sops -d --extract '["AUTHENTIK_BOOTSTRAP_EMAIL"]' authentik/.env.sops.yaml)"
    fi
    if sops -d --extract '["AUTHENTIK_ADMIN_USERNAME"]' authentik/.env.sops.yaml >/dev/null 2>&1; then
      printf 'Additional admin username: %s\n' "$(sops -d --extract '["AUTHENTIK_ADMIN_USERNAME"]' authentik/.env.sops.yaml)"
    fi
    if sops -d --extract '["AUTHENTIK_ADMIN_PASSWORD"]' authentik/.env.sops.yaml >/dev/null 2>&1; then
      printf 'Additional admin password: %s\n' "$(sops -d --extract '["AUTHENTIK_ADMIN_PASSWORD"]' authentik/.env.sops.yaml)"
    fi
    if sops -d --extract '["AUTHENTIK_ADMIN_EMAIL"]' authentik/.env.sops.yaml >/dev/null 2>&1; then
      printf 'Additional admin email: %s\n' "$(sops -d --extract '["AUTHENTIK_ADMIN_EMAIL"]' authentik/.env.sops.yaml)"
    fi
  fi
} | "$pager"
