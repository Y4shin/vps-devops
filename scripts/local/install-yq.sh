#!/usr/bin/env bash
set -euo pipefail

required="${1:?usage: $0 <version>}"
arch="$(uname -m)"
case "$arch" in
  x86_64)  yq_arch="amd64" ;;
  aarch64) yq_arch="arm64" ;;
  armv7l)  yq_arch="arm" ;;
  *)
    echo "Unsupported architecture: $arch"
    exit 1
    ;;
esac

need_install=false
if ! command -v yq >/dev/null 2>&1; then
  echo "yq not found, installing ${required}..."
  need_install=true
else
  current="$(yq --version 2>&1 | grep -oP 'v\d+\.\d+\.\d+' | head -1)"
  if [[ "$(printf '%s\n' "$required" "$current" | sort -V | head -1)" != "$required" ]]; then
    echo "yq ${current} is older than ${required}, upgrading..."
    need_install=true
  else
    echo "yq ${current} already installed and up to date."
  fi
fi

if [[ "$need_install" == true ]]; then
  curl -fsSL "https://github.com/mikefarah/yq/releases/download/${required}/yq_linux_${yq_arch}" -o /tmp/yq
  sudo install -m 755 /tmp/yq /usr/local/bin/yq
  rm /tmp/yq
  echo "yq ${required} installed."
fi
