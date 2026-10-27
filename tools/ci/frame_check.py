#!/usr/bin/env python3
"""Numeric check that a screenshot shows something rendered. Prints metrics only.

    python tools/ci/frame_check.py BASELINE.png FRAME.png

BASELINE is the screen before the emulator started, FRAME the screen while it
runs. Passes when FRAME is not blank/black, has real variation, and differs
from BASELINE over a meaningful share of pixels (so a bare desktop does not
pass). It cannot tell a title screen from an emulator error dialog: treat a
pass as "something was drawn", not "the game works". The images are deleted by
the caller and are never uploaded.
"""
import sys
import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: frame_check.py BASELINE.png FRAME.png")
    base, frame = load(sys.argv[1]), load(sys.argv[2])
    if base.shape != frame.shape:
        print("frame_check: image sizes differ; cannot compare")
        return 1
    luma = frame.mean(axis=2)
    std = float(luma.std())
    mean = float(luma.mean())
    colors = len({tuple(p) for p in frame.reshape(-1, 3)[:: max(1, frame.shape[0] * frame.shape[1] // 20000)]})
    changed = float((np.abs(frame - base).max(axis=2) > 24).mean())
    print(f"frame_check: mean={mean:.1f} std={std:.1f} colors~{colors} changed={changed:.1%}")
    ok = mean > 8 and std > 12 and colors > 64 and changed > 0.05
    print("frame_check: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
