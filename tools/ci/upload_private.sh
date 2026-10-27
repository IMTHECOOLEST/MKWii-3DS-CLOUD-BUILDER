#!/usr/bin/env bash
# Upload the CIA (and the SD-card files as a tar) to a PRIVATE S3-compatible
# bucket. Never to GitHub. Uses curl's built-in SigV4 signing, so there is no
# third-party action or package. Credentials come only from the environment:
#   OUTPUT_S3_ENDPOINT  e.g. https://<account>.r2.cloudflarestorage.com
#   OUTPUT_S3_BUCKET, OUTPUT_S3_ACCESS_KEY_ID, OUTPUT_S3_SECRET_ACCESS_KEY
#   OUTPUT_S3_REGION    optional, default "auto" (R2); use e.g. us-east-1 for AWS
#   OUTPUT_S3_PREFIX    optional key prefix, default "mkw-ci/<run id>/"
# A single PUT is limited to 5 GiB; larger files are skipped with a message.
set -euo pipefail
set +x
workspace="${GITHUB_WORKSPACE:-$(pwd)}"
temp="${RUNNER_TEMP:-/tmp}/mkw-upload"

for v in OUTPUT_S3_ENDPOINT OUTPUT_S3_BUCKET OUTPUT_S3_ACCESS_KEY_ID OUTPUT_S3_SECRET_ACCESS_KEY; do
  if [ -z "${!v:-}" ]; then echo "upload_private: $v is not set; nothing uploaded" >&2; exit 1; fi
done
case "$OUTPUT_S3_ENDPOINT" in https://*) ;; *) echo "upload_private: endpoint must be https://" >&2; exit 1 ;; esac
echo "::add-mask::${OUTPUT_S3_ACCESS_KEY_ID}"
region="${OUTPUT_S3_REGION:-auto}"
prefix="${OUTPUT_S3_PREFIX:-mkw-ci/${GITHUB_RUN_ID:-manual}/}"
limit=5368709120
mkdir -p "$temp"

put() {
  file="$1"; key="$2"
  size="$(wc -c < "$file" | tr -d ' ')"
  if [ "$size" -gt "$limit" ]; then echo "upload_private: $key is over 5 GiB; skipped (use rclone for multipart)"; return 0; fi
  printf 'user = "%s:%s"\n' "$OUTPUT_S3_ACCESS_KEY_ID" "$OUTPUT_S3_SECRET_ACCESS_KEY" |
    curl --fail --silent --show-error --proto '=https' --retry 3 -K - \
      --aws-sigv4 "aws:amz:${region}:s3" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
      -T "$file" "${OUTPUT_S3_ENDPOINT%/}/${OUTPUT_S3_BUCKET}/${key}" >/dev/null 2>&1 \
    || { echo "upload_private: uploading $key failed"; return 1; }
  echo "upload_private: uploaded $key ($size bytes)"
}

put "$workspace/build/release/mkw-3ds.cia" "${prefix}mkw-3ds.cia"
if [ -d "$workspace/build/release/sd-card/3ds" ]; then
  tar -C "$workspace/build/release/sd-card" -cf "$temp/sd-card-3ds.tar" 3ds
  put "$temp/sd-card-3ds.tar" "${prefix}sd-card-3ds.tar"
  rm -f "$temp/sd-card-3ds.tar"
fi
