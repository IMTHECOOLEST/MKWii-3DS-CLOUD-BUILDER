#!/usr/bin/env python3
"""Structural checks of build/release/mkw-3ds.cia (or .cci). Prints sizes only.

    python tools/ci/check_cia.py [--min-bytes N] [--cci]

This proves the file is a well-formed CIA/CCI of this title. It does not prove
the game runs.
"""
import argparse, json, struct, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SIG_SIZES = {0x010000: 0x200, 0x010001: 0x100, 0x010002: 0x3C, 0x010003: 0x200, 0x010004: 0x100, 0x010005: 0x3C}


def align(n, a=0x40):
    return (n + a - 1) // a * a


def cia_title_id(data: bytes) -> int:
    hdr, typ, ver, cert, tik, tmd = struct.unpack_from("<IHHIII", data, 0)
    if hdr != 0x2020 or typ != 0:
        raise ValueError("not a CIA header")
    start = align(hdr) + align(cert) + align(tik)
    sig_type = struct.unpack_from(">I", data, start)[0]
    if sig_type not in SIG_SIZES:
        raise ValueError("unknown TMD signature type")
    header = start + 4 + SIG_SIZES[sig_type]
    header += (0x40 - (4 + SIG_SIZES[sig_type]) % 0x40) % 0x40
    return struct.unpack_from(">Q", data, header + 0x4C)[0]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--min-bytes", type=int, default=100 * 2**20)
    p.add_argument("--cci", action="store_true")
    a = p.parse_args()
    ext = "cci" if a.cci else "cia"
    path = ROOT / "build/release" / f"mkw-3ds.{ext}"
    if not path.is_file():
        raise SystemExit(f"{path.name} was not produced")
    size = path.stat().st_size
    if size < a.min_bytes:
        raise SystemExit(f"{path.name} is only {size} bytes (expected at least {a.min_bytes})")
    with open(path, "rb") as f:
        head = f.read(0x4000)
    if a.cci:
        if head[0x100:0x104] != b"NCSD":
            raise SystemExit("the CCI has no NCSD header")
        print(f"check_cia: {path.name} is an NCSD image, {size} bytes")
        return
    sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tools/release")]
    import package_cia
    got = cia_title_id(head)
    if got != package_cia.TITLE_ID:
        raise SystemExit(f"title ID in the CIA ({got:016X}) is not this port's ({package_cia.TITLE_ID:016X})")
    receipt = path.with_name(path.name + ".receipt.json")
    if receipt.is_file():
        r = json.loads(receipt.read_text())
        if r.get("bytes") != size:
            raise SystemExit("the CIA size differs from its receipt")
    print(f"check_cia: {path.name} is a CIA of title {got:016X}, {size} bytes")


if __name__ == "__main__":
    main()
