#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

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
  sops exec-file --no-fifo deploy_ssh_private_key.sops \
    "chmod 600 {} && ansible-playbook \"${playbook}\" -i ansible/inventory.yml -e ansible_ssh_private_key_file={}"
)
