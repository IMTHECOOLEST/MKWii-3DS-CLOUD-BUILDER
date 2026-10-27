#!/usr/bin/env bash
# Install devkitPro (pacman .pkg + the 3ds-dev group) on a macOS runner and
# export DEVKITPRO / DEVKITARM / PATH for the later steps. Idempotent.
#
# The installer is pinned by version and SHA-256 (override DKP_PACMAN_VERSION and
# DKP_PACMAN_SHA256 together to move to a newer one). The .pkg carries both
# x86_64 and arm64 builds of dkp-pacman, so no Rosetta is needed for devkitPro.
#
# Note: devkitPro asks that pacman not be used in CI (their release notes point
# to the devkitpro/devkitarm Docker images, which a macOS runner cannot run).
# This is one install per manual dispatch; see docs/CI_MACOS.md.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then echo "install_devkitpro_macos.sh is for macOS" >&2; exit 1; fi

version="${DKP_PACMAN_VERSION:-v6.0.2}"
sha_pin="${DKP_PACMAN_SHA256:-da74156211cd3d8664ba7fb95544fbc0a2fbef1dd87b1a6bfafb30d2d446cd30}"
root=/opt/devkitpro

ready() { [ -d "$root/devkitARM" ] && [ -d "$root/libctru" ] && [ -x "$root/tools/bin/tex3ds" ]; }

if ready; then
  echo "devkitPro 3ds-dev already installed"
else
  tmp="${RUNNER_TEMP:-/tmp}"
  pkg="$tmp/devkitpro-pacman-installer.pkg"
  curl --fail --location --retry 5 --silent --show-error \
    --output "$pkg" "https://github.com/devkitPro/pacman/releases/download/$version/devkitpro-pacman-installer.pkg"
  have="$(shasum -a 256 "$pkg" | cut -d' ' -f1)"
  if [ "$have" != "$sha_pin" ]; then
    echo "devkitpro-pacman-installer.pkg ($version) has SHA-256 $have, expected $sha_pin." >&2
    echo "If you moved to a newer release on purpose, set DKP_PACMAN_VERSION and DKP_PACMAN_SHA256." >&2
    exit 1
  fi
  sudo installer -pkg "$pkg" -target /
  rm -f "$pkg"
  pacman_bin=""
  for candidate in "$(command -v dkp-pacman 2>/dev/null || true)" "$root/pacman/bin/dkp-pacman" "$root/pacman/bin/pacman"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then pacman_bin="$candidate"; break; fi
  done
  if [ -z "$pacman_bin" ]; then echo "dkp-pacman not found after the install" >&2; exit 1; fi
  # Never put $root/pacman/bin on PATH (devkitPro's own warning).
  sudo "$pacman_bin" -Syu --noconfirm 3ds-dev
fi

for need in "$root/devkitARM" "$root/libctru" "$root/tools/bin/tex3ds"; do
  if [ ! -e "$need" ]; then echo "Missing $need after installing 3ds-dev" >&2; exit 1; fi
done

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "DEVKITPRO=$root"
    echo "DEVKITARM=$root/devkitARM"
  } >> "$GITHUB_ENV"
fi
if [ -n "${GITHUB_PATH:-}" ]; then echo "$root/tools/bin" >> "$GITHUB_PATH"; fi
echo "devkitPro ready: $("$root/devkitARM/bin/arm-none-eabi-gcc" --version | head -n 1)"
