#!/usr/bin/env python3
"""Fail fast on a bad disc, before the 30-60 minute build.

    python tools/ci/preflight_disc.py DISC

`build_cia.py --check` is not a usable preflight on a fresh tree: after it has
unpacked and verified the disc it stops at the first cook step ("Cook step
'Node packages' has not run"). This runs the same first stages of the builder's
main() (tools, disc, game code) by calling its own functions, unchanged. The
verified extraction (data/extracted) is kept, so the real build skips it.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tools" / "release")]
import build_cia  # noqa: E402


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: preflight_disc.py DISC")
    disc = Path(sys.argv[1])
    print("[preflight] checking tools and the toolchain", flush=True)
    build_cia.stage_tools()
    print("[preflight] unpacking and verifying the disc (a few minutes, no output)", flush=True)
    build_cia.stage_disc(disc)
    build_cia.check_game_code(disc)
    print("[preflight] disc and game code verified", flush=True)


if __name__ == "__main__":
    main()
