#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

mode="${1:-password}"
case "$mode" in
  password|askpass)
    ;;
  *)
    echo "Usage: $0 [password|askpass]" >&2
    exit 1
    ;;
esac

bootstrap_inventory="$(mktemp /tmp/bootstrap-inventory.XXXXXX.yml)"
cleanup() {
  rm -f "$bootstrap_inventory"
}
trap cleanup EXIT

host="$(
  SOPS_AGE_KEY_FILE="${repo_root}/age.key" \
    sops -d --extract '["all"]["hosts"]["vps"]["ansible_host"]' \
    "${repo_root}/ansible/inventory.sops.yaml"
)"
host_escaped="$(printf '%s' "$host" | sed "s/'/''/g")"

if [[ "$mode" == "password" ]]; then
  root_password="$(
    SOPS_AGE_KEY_FILE="${repo_root}/age.key" \
      sops -d --extract '["bootstrap_root_password"]' \
      "${repo_root}/secrets.sops.yaml"
  )"
  root_password_escaped="$(printf '%s' "$root_password" | sed "s/'/''/g")"
  cat > "$bootstrap_inventory" <<EOF
all:
  hosts:
    vps:
      ansible_host: '$host_escaped'
      ansible_user: root
      ansible_password: '$root_password_escaped'
      ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'
EOF
  ansible-playbook "${repo_root}/ansible/bootstrap.yml" -i "$bootstrap_inventory"
else
  cat > "$bootstrap_inventory" <<EOF
all:
  hosts:
    vps:
      ansible_host: '$host_escaped'
      ansible_user: root
      ansible_ssh_common_args: '-o StrictHostKeyChecking=accept-new'
EOF
  ansible-playbook "${repo_root}/ansible/bootstrap.yml" -i "$bootstrap_inventory" --ask-pass
fi
