#!/usr/bin/env bash
set -euo pipefail

required="${1:?usage: $0 <version>}"
arch="$(uname -m)"
case "$arch" in
  x86_64)  lh_arch="amd64" ;;
  aarch64) lh_arch="arm64" ;;
  armv7l)  lh_arch="armhf" ;;
  *)
    echo "Unsupported architecture: $arch"
    exit 1
    ;;
esac

need_install=false
if ! command -v lefthook >/dev/null 2>&1; then
  echo "lefthook not found, installing ${required}..."
  need_install=true
else
  current="$(lefthook version 2>&1 | grep -oP 'v?\d+\.\d+\.\d+' | head -1)"
  current="v${current#v}"
  if [[ "$(printf '%s\n' "$required" "$current" | sort -V | head -1)" != "$required" ]]; then
    echo "lefthook ${current} is older than ${required}, upgrading..."
    need_install=true
  else
    echo "lefthook ${current} already installed and up to date."
  fi
fi

if [[ "$need_install" == true ]]; then
  version_bare="${required#v}"
  curl -fsSL "https://github.com/evilmartians/lefthook/releases/download/${required}/lefthook_${version_bare}_${lh_arch}.deb" -o /tmp/lefthook.deb
  sudo dpkg -i /tmp/lefthook.deb
  sudo apt-get install -f -y
  rm /tmp/lefthook.deb
  echo "lefthook ${required} installed."
fi
