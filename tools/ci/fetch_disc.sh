#!/usr/bin/env bash
# Download the owner's own Mario Kart Wii (USA, RMCE01) disc image from private
# storage into $RUNNER_TEMP (outside the workspace) and sanity-check it.
#
# Inputs, from the environment only (this script takes no arguments):
#   DISC_URL          required  HTTPS location of the ISO/WBFS. Never printed.
#   DISC_AUTH_HEADER  optional  a full header line, e.g. "Authorization: Bearer ...". Never printed.
#   DISC_SHA256       optional  expected SHA-256 of the image.
#   RUNNER_TEMP       directory for the download (a temp dir is made when unset).
#   DISC_MIN_BYTES    optional  override of the 1 GiB size floor (tests).
#   FETCH_DISC_ALLOW_LOCAL=1    also accept file:// and http://localhost (tests only).
#
# Result: $RUNNER_TEMP/mkw.iso or mkw.wbfs, path exported as DISC via $GITHUB_ENV.
# Exit codes: 10 bad input, 11 download failed, 12 too small, 13 not a USA
# RMCE01 image, 14 NKit image, 15 SHA-256 mismatch.
#
# Written for bash 3.2 (the macOS default). Never enable tracing (set -x) here.
set -euo pipefail
set +x
umask 077
export LC_ALL=C

dest_dir="${RUNNER_TEMP:-}"
if [ -z "$dest_dir" ]; then dest_dir="$(mktemp -d)"; fi
mkdir -p "$dest_dir"
out="$dest_dir/mkw.download"
hdr_file="$dest_dir/.mkw-curl-headers"

cleanup() { rm -f "$hdr_file"; }
trap cleanup EXIT

# Failure messages never contain the URL, the header, or curl's own error text
# (curl prints host names). They are plain facts about the file.
fail() {
  code="$1"; shift
  rm -f "$out"
  echo "::error::fetch_disc: $*"
  exit "$code"
}

mask() {
  if [ -n "${1:-}" ]; then echo "::add-mask::$1"; fi
  return 0
}

url="${DISC_URL:-}"
if [ -z "$url" ]; then
  fail 10 "DISC_URL is not set (add it as a secret of the disc-build environment, or as a repository secret)"
fi

# Values derived from secrets: GitHub masks a secret only as a whole string.
case "$url" in
  *\?*) q="${url#*\?}"; mask "${q%%#*}" ;;
esac
hdr="${DISC_AUTH_HEADER:-}"
if [ -n "$hdr" ]; then
  case "$hdr" in
    *:*) ;;
    *) fail 10 "DISC_AUTH_HEADER must look like 'Name: value'" ;;
  esac
  hval="${hdr#*:}"; hval="${hval# }"
  mask "$hval"
  case "$hval" in *" "*) mask "${hval#* }" ;; esac
fi

proto_args=()
case "$url" in
  https://*) proto_args=(--proto '=https' --proto-redir '=https') ;;
  file://*|http://localhost*|http://127.0.0.1*)
    if [ "${FETCH_DISC_ALLOW_LOCAL:-}" != "1" ]; then fail 10 "DISC_URL must start with https://"; fi ;;
  *) fail 10 "DISC_URL must start with https://" ;;
esac

# The header goes through a private file so it never appears in a process list.
: > "$hdr_file"
if [ -n "$hdr" ]; then printf '%s\n' "$hdr" >> "$hdr_file"; fi
case "$url" in
  https://api.github.com/*) printf 'Accept: application/octet-stream\n' >> "$hdr_file" ;;
esac
header_args=()
if [ -s "$hdr_file" ]; then header_args=(-H "@$hdr_file"); fi

rm -f "$dest_dir/mkw.iso" "$dest_dir/mkw.wbfs" "$out"
echo "fetch_disc: downloading the disc image (location not shown)"
status=0
http_code="$(curl --fail --location --retry 5 --retry-delay 5 --silent --show-error \
  ${proto_args[@]+"${proto_args[@]}"} ${header_args[@]+"${header_args[@]}"} \
  --output "$out" --write-out '%{http_code}' "$url" 2>/dev/null)" || status=$?
if [ "$status" -ne 0 ]; then
  fail 11 "download failed (curl exit $status, HTTP ${http_code:-000})"
fi

size="$(wc -c < "$out" | tr -d ' ')"
min="${DISC_MIN_BYTES:-1073741824}"
if [ "$size" -lt "$min" ]; then
  fail 12 "the download is only $size bytes (a disc image is over $min): truncated, or an error page"
fi

read_bytes() { dd if="$out" bs=1 skip="$1" count="$2" 2>/dev/null | tr -d '\000'; }

ext=iso
id=""
nkit=""
if [ "$(read_bytes 0 4)" = "WBFS" ]; then
  ext=wbfs
  shift_bits="$(od -An -tu1 -j8 -N1 "$out" | tr -d ' ')"
  if [ -n "$shift_bits" ] && [ "$shift_bits" -ge 9 ] && [ "$shift_bits" -le 15 ]; then
    id="$(read_bytes $((1 << shift_bits)) 6)"
  fi
else
  id="$(read_bytes 0 6)"
  nkit="$(read_bytes 512 4)"
fi

if [ "$ext" = "iso" ] && [ "$nkit" = "NKIT" ]; then
  fail 14 "this is an NKit image; convert it to a normal ISO in Dolphin first"
fi
case "$id" in
  RMCE01) ;;
  RMCP01) fail 13 "this is the Europe (PAL) disc; only the USA version (RMCE01) works" ;;
  RMCJ01) fail 13 "this is the Japan disc; only the USA version (RMCE01) works" ;;
  RMCK01) fail 13 "this is the Korea disc; only the USA version (RMCE01) works" ;;
  *)
    # WBFS with an unusual sector size: leave the identity check to the builder.
    if [ "$ext" = "wbfs" ] && [ -z "$id" ]; then :; else
      fail 13 "this is not a Mario Kart Wii USA (RMCE01) disc image"
    fi ;;
esac

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
if [ -n "${DISC_SHA256:-}" ]; then
  want="$(printf '%s' "$DISC_SHA256" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$want" in
    *[!0-9a-f]*|"") fail 10 "DISC_SHA256 is not a hex string" ;;
  esac
  if [ "${#want}" -ne 64 ]; then fail 10 "DISC_SHA256 must be 64 hex characters"; fi
  have="$(sha256_of "$out")"
  if [ "$have" != "$want" ]; then fail 15 "SHA-256 of the download does not match DISC_SHA256"; fi
  echo "fetch_disc: SHA-256 matches"
fi

final="$dest_dir/mkw.$ext"
mv "$out" "$final"
chmod 600 "$final"
if [ -n "${GITHUB_ENV:-}" ]; then printf 'DISC=%s\n' "$final" >> "$GITHUB_ENV"; fi
echo "fetch_disc: ok ($ext image, $size bytes)"
