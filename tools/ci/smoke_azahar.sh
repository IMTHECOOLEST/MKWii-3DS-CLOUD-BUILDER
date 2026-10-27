#!/usr/bin/env bash
# BEST-EFFORT boot check of build/release/mkw-3ds.cci in the Azahar emulator
# with the software renderer. Everything here is unverified until it has run
# on a real runner: the asset name, the config location and key, and whether
# `screencapture` may read the screen of a hosted VM.
#
# It prints "runtime verified" only when the frame check passed, and otherwise
# "runtime NOT verified: <reason>" and exits 1 (the workflow step uses
# continue-on-error). The screenshots are deleted and never uploaded.
#
#   AZAHAR_TAG     release to use (default 2126.1; its release is immutable)
#   AZAHAR_SHA256  optional pin of the downloaded macOS asset
#   AZAHAR_SECONDS how long to let it run (default 45)
#   GH_TOKEN       optional, avoids API rate limits and enables `gh release verify-asset`
set -uo pipefail
workspace="${GITHUB_WORKSPACE:-$(pwd)}"
work="${RUNNER_TEMP:-/tmp}/mkw-smoke"
tag="${AZAHAR_TAG:-2126.1}"
secs="${AZAHAR_SECONDS:-45}"
cci="$workspace/build/release/mkw-3ds.cci"
pid=""
mkdir -p "$work"

finish() {
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -rf "$work"/*.png
}
trap finish EXIT
notverified() {
  echo "::warning::runtime NOT verified: $1"
  echo "runtime NOT verified: $1"
  exit 1
}

[ -f "$cci" ] || notverified "no CCI was built (run with smoke_test so the builder adds --cci)"
cd "$work" || notverified "no work directory"

# 1. Find the macOS asset of the pinned release.
auth=()
[ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
curl --fail --silent --show-error ${auth[@]+"${auth[@]}"} \
  "https://api.github.com/repos/azahar-emu/azahar/releases/tags/$tag" -o release.json 2>/dev/null \
  || notverified "could not read the Azahar $tag release"
arch="$(uname -m)"
asset="$(python3 - "$arch" <<'PY'
import json, sys
arch = sys.argv[1]
names = [(a["name"], a["browser_download_url"]) for a in json.load(open("release.json"))["assets"]]
want = ["universal", "arm64" if arch == "arm64" else "x86_64"]
for key in want:
    for n, u in names:
        low = n.lower()
        if "macos" in low and key in low and low.endswith((".zip", ".dmg")):
            print(n + "\t" + u); sys.exit()
PY
)"
[ -n "$asset" ] || notverified "no macOS asset found in the Azahar $tag release"
name="${asset%%$'\t'*}"; url="${asset#*$'\t'}"
curl --fail --location --silent --show-error -o "$name" "$url" || notverified "download of $name failed"
have="$(shasum -a 256 "$name" | cut -d' ' -f1)"
echo "azahar asset: $name sha256=$have"
if [ -n "${AZAHAR_SHA256:-}" ] && [ "$have" != "$AZAHAR_SHA256" ]; then notverified "Azahar download does not match AZAHAR_SHA256"; fi
if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
  if gh release verify-asset "$tag" "$name" -R azahar-emu/azahar >/dev/null 2>&1; then echo "azahar attestation: verified"
  else echo "azahar attestation: not verified (no attestation, or gh too old)"; fi
fi

# 2. Unpack to an .app.
case "$name" in
  *.zip) unzip -q "$name" -d app ;;
  *.dmg) hdiutil attach -nobrowse -readonly -mountpoint "$work/dmg" "$name" >/dev/null && mkdir -p app && cp -R "$work"/dmg/*.app app/ ; hdiutil detach "$work/dmg" >/dev/null 2>&1 ;;
esac
app="$(find app -maxdepth 3 -name '*.app' -type d | head -n 1)"
[ -n "$app" ] || notverified "no .app inside $name"
bin="$(find "$app/Contents/MacOS" -type f -perm +111 | head -n 1)"
[ -n "$bin" ] || notverified "no executable inside the app"
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

# 3. Software renderer (graphics_api 0), first-run dialogs off. The user
#    directory differs between builds and platforms, so write every candidate.
conf='[Renderer]
graphics_api\default=false
graphics_api=0
use_hw_shader\default=false
use_hw_shader=false
[UI]
firstStart\default=false
firstStart=false
confirmClose\default=false
confirmClose=false
[Updater]
check_for_update_on_start\default=false
check_for_update_on_start=false'
for dir in "$HOME/Library/Application Support/Azahar/config" "$HOME/.config/azahar-emu" \
           "$HOME/.local/share/azahar-emu/config" "$(dirname "$app")/user/config" "$(dirname "$bin")/user/config"; do
  mkdir -p "$dir" && printf '%s\n' "$conf" > "$dir/qt-config.ini"
done

# 4. Baseline screen, launch, wait, capture.
screencapture -x -t png baseline.png 2>/dev/null || notverified "screencapture is not allowed on this runner"
env -u GH_TOKEN -u GITHUB_TOKEN "$bin" "$cci" >emulator-stdout.txt 2>&1 &
pid=$!
sleep "$secs"
kill -0 "$pid" 2>/dev/null || notverified "the emulator exited before the capture"
screencapture -x -t png frame.png 2>/dev/null || notverified "screencapture failed while the emulator ran"

# 5. Judge. Metrics only; no image leaves this directory.
if grep -rqs -E "Failed to load|<Critical>" "$HOME/Library/Application Support/Azahar" "$HOME/.local/share/azahar-emu" "$HOME/.config/azahar-emu" 2>/dev/null; then
  notverified "the emulator log reports a load failure or a critical error"
fi
venv_python="$workspace/.venv/bin/python"; [ -x "$venv_python" ] || venv_python=python3
if "$venv_python" "$workspace/tools/ci/frame_check.py" baseline.png frame.png; then
  echo "runtime verified: the emulator drew a non-blank frame with the software renderer (this is not a playability test)"
  exit 0
fi
notverified "the captured frame is blank or unchanged"
