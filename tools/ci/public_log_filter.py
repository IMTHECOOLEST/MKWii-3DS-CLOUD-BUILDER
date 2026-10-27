#!/usr/bin/env python3
"""Run a command, keep its full output in a PRIVATE file, show only progress in the public log.

    python tools/ci/public_log_filter.py LOGFILE -- command [args...]

The builder prints, among other things, the name and size of every file it reads
from the disc (tools/extract_disc.py) and, in its package step, a receipt with
hashes of the finished CIA. Those are derived from the disc and must not sit in
a public Actions log. This wrapper writes everything to LOGFILE (never uploaded;
removed by tools/ci/cleanup.sh) and echoes only step-progress lines. If the
command fails, it also echoes the last line of output with path-like and
file-name-like pieces removed. Set MKW_CI_VERBOSE=1 to echo everything (the log
of a public repository is then readable by anyone).
"""
import os, re, subprocess, sys

ALLOW = re.compile(
    r'^(\[preflight\] '
    r'|\[build_cia\] (step \d+/\d+: |cooked: |cooked \(|disc verified|check passed|cook complete|done: |'
    r'unpacking and checking|replacing the previous|SD card files for update CIAs))')
PATHS = re.compile(r"(?<![\w/.-])(?:data|assets|build|sd-card|vendor)/[^\s'\")\],]*")
NAMES = re.compile(r"[\w.-]+\.(?:szs|brres|brlyt|brlan|brctr|brstm|brsar|rel|thp|tpl|arc|u8|bin|pak)\b", re.I)
FIRST = re.compile(r"\(first: [^)]*\)")


def redact(line: str) -> str:
    line = FIRST.sub("(first: <name>)", line)
    line = PATHS.sub("<path>", line)
    line = NAMES.sub("<file>", line)
    return line.strip()[:300]


def last_line(path: str) -> str:
    last = ""
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            if raw.strip():
                last = raw
    return redact(last)


def main(argv):
    if len(argv) < 4 or argv[2] != "--":
        print("usage: public_log_filter.py LOGFILE -- command [args...]", file=sys.stderr)
        return 2
    log_path, cmd = argv[1], argv[3:]
    verbose = os.environ.get("MKW_CI_VERBOSE") == "1"
    if verbose:
        print("::warning::MKW_CI_VERBOSE=1: the full builder output is in the public log")
    with open(log_path, "a", encoding="utf-8", errors="replace") as log:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors="replace", bufsize=1)
        for line in proc.stdout:
            log.write(line)
            log.flush()
            if verbose or ALLOW.match(line):
                sys.stdout.write(line if line.endswith("\n") else line + "\n")
                sys.stdout.flush()
        code = proc.wait()
    if code != 0:
        print(f"::error::command failed with exit code {code}; last message: {last_line(log_path)}")
        print("The full output stays in the private build-cia-log.txt on the runner (never uploaded). "
              "Re-run with the verbose_log input only if you accept that it lands in the public log.")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
