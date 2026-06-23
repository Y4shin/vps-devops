#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
age_key_file="${repo_root}/age.key"

if command -v ansible-playbook >/dev/null 2>&1; then
  ansible_playbook_bin="ansible-playbook"
elif [[ -x "${HOME}/.local/bin/ansible-playbook" ]]; then
  ansible_playbook_bin="${HOME}/.local/bin/ansible-playbook"
else
  echo "ansible-playbook not found in PATH or ~/.local/bin" >&2
  exit 127
fi

playbook="${1:-}"
if [[ -z "$playbook" ]]; then
  echo "Usage: $0 <playbook-path> [extra ansible-playbook args...]" >&2
  exit 1
fi
shift

if [[ ! -f "${repo_root}/${playbook}" ]]; then
  echo "Playbook not found: ${playbook}" >&2
  exit 1
fi

# Any remaining args (e.g. --tags traefik) are appended to the
# ansible-playbook invocation, shell-quoted so they survive the sops
# exec-file command string.
extra_args=""
for arg in "$@"; do
  extra_args+=" $(printf '%q' "$arg")"
done

(
  cd "$repo_root"
  # Force our ansible.cfg: the repo dir is often world-writable (WSL2), which makes
  # Ansible silently ignore a cwd ansible.cfg unless ANSIBLE_CONFIG is set. Without
  # it the vars plugins (community.sops) are not enabled and secrets don't resolve.
  export ANSIBLE_CONFIG="${repo_root}/ansible.cfg"
  # Inventory is ansible/inventories/prod: plaintext hosts.yml + group_vars
  # (group_vars/all.sops.yaml is auto-decrypted by the community.sops vars plugin,
  # which inherits SOPS_AGE_KEY_FILE from this command's environment).
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && \"${ansible_playbook_bin}\" \"${playbook}\" -i ansible/inventories/prod -e ansible_ssh_private_key_file={}${extra_args}"
)
