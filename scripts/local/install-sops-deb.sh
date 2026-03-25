#!/usr/bin/env bash
set -euo pipefail

required="${1:?usage: $0 <version>}"
arch="$(uname -m)"
case "$arch" in
  x86_64)  sops_arch="amd64" ;;
  aarch64) sops_arch="arm64" ;;
  armv7l)  sops_arch="armhf" ;;
  *)
    echo "Unsupported architecture: $arch"
    exit 1
    ;;
esac

need_install=false
if ! command -v sops >/dev/null 2>&1; then
  echo "sops not found, installing ${required}..."
  need_install=true
else
  current="$(sops --version 2>&1 | grep -oP 'v?\d+\.\d+\.\d+' | head -1)"
  current="v${current#v}"
  if [[ "$(printf '%s\n' "$required" "$current" | sort -V | head -1)" != "$required" ]]; then
    echo "sops ${current} is older than ${required}, upgrading..."
    need_install=true
  else
    echo "sops ${current} already installed and up to date."
  fi
fi

if [[ "$need_install" == true ]]; then
  version_bare="${required#v}"
  curl -fsSL "https://github.com/getsops/sops/releases/download/${required}/sops_${version_bare}_${sops_arch}.deb" -o /tmp/sops.deb
  sudo dpkg -i /tmp/sops.deb
  sudo apt-get install -f -y
  rm /tmp/sops.deb
  echo "sops ${required} installed."
fi
