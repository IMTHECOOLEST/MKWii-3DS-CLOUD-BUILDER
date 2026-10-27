#!/usr/bin/env bash
# Remove the disc image and everything derived from it. Run with `if: always()`.
set -uo pipefail
workspace="${GITHUB_WORKSPACE:-$(pwd)}"
temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
rm -f "$temp"/mkw.iso "$temp"/mkw.wbfs "$temp"/mkw.download "$temp"/.mkw-curl-headers
rm -rf "$temp"/mkw-smoke "$temp"/mkw-upload
for d in data assets build sd-card emulator; do rm -rf "${workspace:?}/$d"; done
rm -f "$workspace/build-cia-log.txt"
echo "cleanup: disc image and derived files removed"
