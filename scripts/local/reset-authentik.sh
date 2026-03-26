#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

host="$(
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops -d --extract '["all"]["hosts"]["vps"]["ansible_host"]' \
    "${repo_root}/ansible/inventory.sops.yaml"
)"

echo "This will permanently delete the current Authentik state on ${host}."
echo "It runs 'docker compose down -v' for Authentik and then deletes /opt/vps-devops/authentik."
echo
read -r -p "Type the VPS host (${host}) to continue: " confirm_host
if [[ "$confirm_host" != "$host" ]]; then
  echo "Host confirmation did not match. Aborting." >&2
  exit 1
fi

read -r -p "Type RESET AUTHENTIK to confirm destructive reset: " confirm_phrase
if [[ "$confirm_phrase" != "RESET AUTHENTIK" ]]; then
  echo "Confirmation phrase did not match. Aborting." >&2
  exit 1
fi

remote_command="$(cat <<'EOF'
set -euo pipefail
authentik_root=/opt/vps-devops/authentik

if [[ -d "$authentik_root" ]]; then
  cat > "$authentik_root/.env" <<'ENVEOF'
PG_PASS=reset-temporary-value
AUTHENTIK_SECRET_KEY=reset-temporary-value
AUTHENTIK_BOOTSTRAP_PASSWORD=reset-temporary-value
AUTHENTIK_ERROR_REPORTING__ENABLED=true
AUTHENTIK_IMAGE=ghcr.io/goauthentik/server
AUTHENTIK_TAG=2026.2.1
AUTHENTIK_UID=999
AUTHENTIK_GID=999
ENVEOF

  (
    cd "$authentik_root"
    docker compose down -v --remove-orphans || true
  )
fi

docker volume rm -f authentik_database >/dev/null 2>&1 || true
docker run --rm -v /opt/vps-devops:/work alpine:3.22 sh -c 'rm -rf /work/authentik'
EOF
)"
remote_command_quoted="$(printf '%q' "$remote_command")"

(
  cd "$repo_root"
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && ssh -o StrictHostKeyChecking=accept-new -i {} deploy@${host} bash -lc ${remote_command_quoted}"
)
