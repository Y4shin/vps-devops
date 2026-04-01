#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

bash "${repo_root}/scripts/local/ssh-run.sh" "find /opt/vps-devops/mail/config/rspamd/dkim -maxdepth 1 -type f -name '*.txt' -print -exec cat {} \;"
