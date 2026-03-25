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
  echo "Usage: $0 <playbook-path>" >&2
  exit 1
fi

if [[ ! -f "${repo_root}/${playbook}" ]]; then
  echo "Playbook not found: ${playbook}" >&2
  exit 1
fi

(
  cd "$repo_root"
  SOPS_AGE_KEY_FILE="$age_key_file" \
    sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && \"${ansible_playbook_bin}\" \"${playbook}\" -i ansible/inventory.yml -e ansible_ssh_private_key_file={}"
)
