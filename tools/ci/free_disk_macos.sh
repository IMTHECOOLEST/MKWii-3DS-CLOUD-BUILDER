#!/usr/bin/env bash
# Free disk space on a macOS runner before the build (the builder wants ~15 GB).
# PROVISIONAL: the list below is the usual set of large, unneeded runner
# contents; tune it with the numbers from probe-macos-runner.yml.
set -uo pipefail

# On macOS `df -h /` shows the read-only system volume. The writable data
# volume (the one that holds the workspace and $RUNNER_TEMP) is what counts,
# so measure the volume that holds the work directory.
here="${GITHUB_WORKSPACE:-$HOME}"
free_gib() { df -Pk "$here" | awk 'NR==2 {printf "%d", $4/1048576}'; }
show() { echo "$1 $(df -h "$here" | awk 'NR==2 {print $4 " free of " $2}') (work volume)"; }

show before:

sel="$(xcode-select -p 2>/dev/null || true)"           # e.g. /Applications/Xcode_16.4.app/Contents/Developer
keep_app="${sel%%/Contents/Developer}"
for app in /Applications/Xcode*.app; do
  [ -e "$app" ] || continue
  if [ "$app" != "$keep_app" ]; then
    echo "removing extra $(basename "$app")"
    sudo rm -rf "$app"
  fi
done

# Simulators and their runtimes (iOS/watchOS/tvOS/visionOS): several GB each.
xcrun simctl delete all >/dev/null 2>&1 || true
sudo xcrun simctl runtime delete all >/dev/null 2>&1 || true
sudo rm -rf /Library/Developer/CoreSimulator/Volumes/* /Library/Developer/CoreSimulator/Images/* 2>/dev/null || true
rm -rf "$HOME/Library/Developer/CoreSimulator" "$HOME/Library/Developer/Xcode/DerivedData" \
       "$HOME/Library/Developer/Xcode/iOS DeviceSupport" 2>/dev/null || true

# Toolchains this build does not use (Python and Node stay: setup-python/-node put theirs there).
rm -rf "$HOME/Library/Android" "$HOME/hostedtoolcache/go" "$HOME/hostedtoolcache/Ruby" \
       "$HOME/hostedtoolcache/PyPy" "$HOME/hostedtoolcache/CodeQL" 2>/dev/null || true
sudo rm -rf /Users/runner/hostedtoolcache/go /Users/runner/hostedtoolcache/Ruby \
            /Users/runner/hostedtoolcache/PyPy /Users/runner/hostedtoolcache/CodeQL 2>/dev/null || true

command -v brew >/dev/null 2>&1 && rm -rf "$(brew --cache)" 2>/dev/null || true
rm -rf "$HOME/Library/Caches/Homebrew" 2>/dev/null || true

show after:

# The disc image (about 4.7 GB) plus the builder's ~15 GB plus devkitPro need
# room at once. Fail now rather than hours into the build. MKW_MIN_FREE_GB=0 skips.
min="${MKW_MIN_FREE_GB:-22}"
have="$(free_gib)"
if [ "$min" -gt 0 ] && [ "$have" -lt "$min" ]; then
  echo "::error::Only $have GiB free on the work volume after cleanup; this build wants about $min GiB (15 for the builder, 4.7 for the disc, 2 for devkitPro). See docs/CI_MACOS.md, section Costs, limits, caveats."
  exit 1
fi
