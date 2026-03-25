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

host="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["all"]["hosts"]["vps"]["ansible_host"]' \
    "${repo_root}/ansible/inventory.sops.yaml"
)"

witness_env_file="$(mktemp /tmp/witness-env.XXXXXX)"
cleanup() {
  rm -f "$witness_env_file"
}
trap cleanup EXIT

cat > "$witness_env_file" <<EOF
ORIGIN=https://witness.$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["domain"]' "${repo_root}/secrets.sops.yaml"
)
DATABASE_URL=file:/data/app.db
SESSION_SECRET=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["SESSION_SECRET"]' "${repo_root}/reporting-tool/.env.sops.yaml"
)
ADMIN_PASSWORD=$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["ADMIN_PASSWORD"]' "${repo_root}/reporting-tool/.env.sops.yaml"
)
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

(
  cd "$repo_root"
  sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && scp -o StrictHostKeyChecking=accept-new -i {} \"$witness_env_file\" deploy@${host}:/opt/vps-devops/reporting-tool/.env && ssh -t -i {} deploy@${host} 'bash -lc \"cd /opt/vps-devops/reporting-tool && trap '\''rm -f .env'\'' EXIT && ${remote_command}\"'"
)
