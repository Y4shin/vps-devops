#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
cd "$repo_root"

pager="${PAGER:-less}"
if ! command -v "$pager" >/dev/null 2>&1; then
  pager="cat"
fi

reporting_tool_admin_auth_mode="$(sops -d --extract '["sops_reporting_tool_secrets"]["ADMIN_AUTH_MODE"]' ansible/inventories/prod/group_vars/all.sops.yaml 2>/dev/null || true)"
reporting_tool_admin_password="$(sops -d --extract '["sops_reporting_tool_secrets"]["ADMIN_PASSWORD"]' ansible/inventories/prod/group_vars/all.sops.yaml 2>/dev/null || true)"
reporting_tool_admin_oidc_client_secret="$(sops -d --extract '["sops_reporting_tool_secrets"]["ADMIN_OIDC_CLIENT_SECRET"]' ansible/inventories/prod/group_vars/all.sops.yaml 2>/dev/null || true)"

if [ -z "$reporting_tool_admin_auth_mode" ]; then
  if [ -n "$reporting_tool_admin_oidc_client_secret" ]; then
    reporting_tool_admin_auth_mode="oidc"
  else
    reporting_tool_admin_auth_mode="password"
  fi
fi

{
  echo "Reporting Tool"
  echo "=============="
  printf 'Admin auth mode: %s\n' "$reporting_tool_admin_auth_mode"
  if [ "$reporting_tool_admin_auth_mode" = "password" ]; then
    printf 'Admin password: %s\n' "$reporting_tool_admin_password"
  else
    printf 'Admin OIDC client secret: %s\n' "$reporting_tool_admin_oidc_client_secret"
    printf 'Admin access group: %s\n' "reporting-tool-admin-access"
  fi
  printf 'Session secret: %s\n' "$(sops -d --extract '["sops_reporting_tool_secrets"]["SESSION_SECRET"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'S3 access key id: %s\n' "$(sops -d --extract '["sops_reporting_tool_secrets"]["S3_ACCESS_KEY_ID"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'S3 secret access key: %s\n' "$(sops -d --extract '["sops_reporting_tool_secrets"]["S3_SECRET_ACCESS_KEY"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'Borg path: %s\n' "$(sops -d --extract '["sops_reporting_tool_secrets"]["borg_path"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'Borg passphrase: %s\n' "$(sops -d --extract '["sops_reporting_tool_secrets"]["borg_passphrase"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  echo
  echo "Global Infra"
  echo "============"
  printf 'Domain: %s\n' "$(sops -d --extract '["sops_secrets"]["domain"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'LetsEncrypt email: %s\n' "$(sops -d --extract '["sops_secrets"]["letsencrypt_email"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'S3 endpoint: %s\n' "$(sops -d --extract '["sops_secrets"]["s3_endpoint"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'S3 bucket: %s\n' "$(sops -d --extract '["sops_secrets"]["s3_bucket"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'S3 region: %s\n' "$(sops -d --extract '["sops_secrets"]["s3_region"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'Borg host: %s\n' "$(sops -d --extract '["sops_secrets"]["borg_host"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  printf 'Borg user: %s\n' "$(sops -d --extract '["sops_secrets"]["borg_user"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
  echo
  echo "Traefik"
  echo "======="
  printf 'Dashboard access group: %s\n' "traefik-dashboard-access"
  printf 'Dashboard auth source: %s\n' "Authentik forward auth"
  if sops -d --extract '["sops_authentik_secrets"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
    echo
    echo "Authentik"
    echo "========="
    printf 'PostgreSQL password: %s\n' "$(sops -d --extract '["sops_authentik_secrets"]["PG_PASS"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    printf 'Authentik secret key: %s\n' "$(sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_SECRET_KEY"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    printf 'Bootstrap password: %s\n' "$(sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_BOOTSTRAP_PASSWORD"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    printf 'Borg path: %s\n' "$(sops -d --extract '["sops_authentik_secrets"]["borg_path"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    printf 'Borg passphrase: %s\n' "$(sops -d --extract '["sops_authentik_secrets"]["borg_passphrase"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    if sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_BOOTSTRAP_EMAIL"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
      printf 'Bootstrap email: %s\n' "$(sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_BOOTSTRAP_EMAIL"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    fi
    if sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_ADMIN_USERNAME"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
      printf 'Additional admin username: %s\n' "$(sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_ADMIN_USERNAME"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    fi
    if sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_ADMIN_PASSWORD"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
      printf 'Additional admin password: %s\n' "$(sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_ADMIN_PASSWORD"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    fi
    if sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_ADMIN_EMAIL"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
      printf 'Additional admin email: %s\n' "$(sops -d --extract '["sops_authentik_secrets"]["AUTHENTIK_ADMIN_EMAIL"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    fi
  fi
  if sops -d --extract '["sops_mail_secrets"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
    echo
    echo "Mail"
    echo "===="
    if sops -d --extract '["sops_mail_secrets"]["MAIL_DOMAIN"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
      printf 'Mail domain: %s\n' "$(sops -d --extract '["sops_mail_secrets"]["MAIL_DOMAIN"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    else
      printf 'Mail domain: %s\n' "$(sops -d --extract '["sops_secrets"]["domain"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    fi
    if sops -d --extract '["sops_mail_secrets"]["MAIL_HOSTNAME"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
      printf 'Mail hostname: %s\n' "$(sops -d --extract '["sops_mail_secrets"]["MAIL_HOSTNAME"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    else
      printf 'Mail hostname: %s\n' "mail.$(sops -d --extract '["sops_secrets"]["domain"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    fi
    if sops -d --extract '["sops_mail_secrets"]["MAIL_SUBMISSION_ACCOUNT"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
      printf 'Submission account: %s\n' "$(sops -d --extract '["sops_mail_secrets"]["MAIL_SUBMISSION_ACCOUNT"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    else
      printf 'Submission account: %s\n' "authentik@$(sops -d --extract '["sops_secrets"]["domain"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    fi
    printf 'Submission password: %s\n' "$(sops -d --extract '["sops_mail_secrets"]["MAIL_SUBMISSION_PASSWORD"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    if sops -d --extract '["sops_mail_secrets"]["MAIL_AUTHENTIK_FROM"]' ansible/inventories/prod/group_vars/all.sops.yaml >/dev/null 2>&1; then
      printf 'Authentik from: %s\n' "$(sops -d --extract '["sops_mail_secrets"]["MAIL_AUTHENTIK_FROM"]' ansible/inventories/prod/group_vars/all.sops.yaml)"
    fi
  fi
} | "$pager"
