#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

raw="$(bash "${repo_root}/scripts/local/ssh-run.sh" "cd /opt/vps-devops/mail && docker compose exec -T mailserver find /tmp/docker-mailserver/opendkim/keys -type f -name '*.txt' -exec cat {} \;" 2>/dev/null)"

if [[ -z "$raw" ]]; then
  echo "No DKIM keys found. Deploy the mail relay first: task deploy:mail" >&2
  exit 1
fi

# Extract selector and domain from the comment line
selector="$(echo "$raw" | grep -oP '(?<=DKIM key )\S+' || echo "mail")"
domain="$(echo "$raw" | grep -oP '(?<=DKIM key \S{1,64} for )\S+' || echo "unknown")"

# Concatenate the quoted fragments into a single TXT value
value="$(echo "$raw" | grep -oP '"[^"]*"' | sed 's/"//g' | tr -d '\n')"

echo "DNS record to add:"
echo ""
echo "  Type:  TXT"
echo "  Name:  ${selector}._domainkey.${domain}"
echo "  Value: ${value}"
