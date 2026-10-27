#!/usr/bin/env python3
"""Put the CIA and the SD-card files into a DRAFT release of this repository.

A draft release is visible only to people with write access to the repository
(you); it is not public as long as you never press "Publish". The script checks
that the release really is a draft and stops otherwise.

GitHub limits every release file to 2 GiB, so the SD-card folder is split into
several ordinary zip files (each under 1.8 GiB, files never split in half). Unzip
ALL of them into the root of the SD card; they merge into sd:/3ds/mkw-3ds.
Only counts and sizes are printed: file names come from the disc.

Needs the `gh` CLI (preinstalled on GitHub-hosted runners) and GH_TOKEN with
contents: write.
"""
import os, subprocess, sys, zipfile
from pathlib import Path

ROOT = Path(os.environ.get("GITHUB_WORKSPACE") or Path(__file__).resolve().parents[2])
RELEASE = ROOT / "build" / "release"
SD_TOP = RELEASE / "sd-card"
MAX_FILE = 2 * 2**30 - 2**20     # GitHub's limit per release file, with margin
PART = int(1.8 * 2**30)          # uncompressed bytes per SD zip


def plan_parts(sizes, limit=PART):
    """Group (key, size) pairs into lists whose sizes sum to at most `limit`."""
    parts, cur, total = [], [], 0
    for key, size in sizes:
        if size > limit:
            raise SystemExit("one SD-card file is bigger than a release file can hold; use the private bucket upload")
        if cur and total + size > limit:
            parts.append(cur)
            cur, total = [], 0
        cur.append(key)
        total += size
    if cur:
        parts.append(cur)
    return parts


def gh(*args, capture=False):
    result = subprocess.run(["gh", *args, "--repo", os.environ["GITHUB_REPOSITORY"]],
                            check=True, text=True, stdout=subprocess.PIPE if capture else subprocess.DEVNULL)
    return result.stdout.strip() if capture else ""


def main():
    for var in ("GH_TOKEN", "GITHUB_REPOSITORY"):
        if not os.environ.get(var):
            raise SystemExit(f"{var} is not set")
    tag = f"private-build-{os.environ.get('GITHUB_RUN_ID', 'manual')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    gh("release", "create", tag, "--draft", "--target", os.environ.get("GITHUB_SHA", "main"),
       "--title", f"PRIVATE build #{os.environ.get('GITHUB_RUN_NUMBER', '?')} - DRAFT, never publish",
       "--notes", "Contains game data built from your own disc. Keep this release a draft and do not share it.")
    if gh("release", "view", tag, "--json", "isDraft", "-q", ".isDraft", capture=True) != "true":
        raise SystemExit("the release is not a draft; refusing to upload anything")

    cia = RELEASE / "mkw-3ds.cia"
    if cia.stat().st_size > MAX_FILE:
        print("upload_draft_release: the CIA is over 2 GiB and cannot go into a release (use the private bucket)")
    else:
        gh("release", "upload", tag, str(cia))
        print(f"upload_draft_release: uploaded the CIA ({cia.stat().st_size / 2**20:.0f} MiB)")

    sd = SD_TOP / "3ds"
    if sd.is_dir():
        files = sorted((p, p.stat().st_size) for p in sd.rglob("*") if p.is_file())
        work = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "mkw-upload"
        work.mkdir(parents=True, exist_ok=True)
        parts = plan_parts(files)
        for number, group in enumerate(parts, 1):
            archive = work / f"sd-card-3ds-part{number:02d}-of-{len(parts):02d}.zip"
            with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as z:
                for path in group:
                    z.write(path, path.relative_to(SD_TOP))
            size = archive.stat().st_size
            if size > MAX_FILE:
                archive.unlink()
                raise SystemExit("an SD zip came out over 2 GiB; use the private bucket upload")
            gh("release", "upload", tag, str(archive))
            archive.unlink()
            print(f"upload_draft_release: uploaded SD zip {number}/{len(parts)} ({len(group)} files, {size / 2**20:.0f} MiB)")
    print("upload_draft_release: done. Open the repository's Releases page; the new entry is marked Draft.")


if __name__ == "__main__":
    main()
