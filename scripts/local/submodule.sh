#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

key_file="${1:-}"
submodule_path="${2:-}"
action="${3:-}"

if [[ -z "$key_file" || -z "$submodule_path" || -z "$action" ]]; then
  echo "Usage: $0 <key-file> <submodule-path> <init|update>" >&2
  exit 1
fi

case "$action" in
  init)
    git_command="git submodule update --init -- \"${submodule_path}\""
    ;;
  update)
    git_command="git submodule update --remote --merge -- \"${submodule_path}\""
    ;;
  *)
    echo "Unsupported action: ${action}" >&2
    exit 1
    ;;
esac

(
  cd "$repo_root"
  sops exec-file --no-fifo "$key_file" \
    "chmod 600 {} && GIT_SSH_COMMAND=\"ssh -i {} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new\" ${git_command}"
)
