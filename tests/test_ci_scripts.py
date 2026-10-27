"""CI glue checks (no disc, no network): python -m unittest discover tests"""

import http.server
import os
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / "tools" / "ci"
sys.path[:0] = [str(CI)]
import check_cia  # noqa: E402
import public_log_filter  # noqa: E402

SECRET_PATH = "private-bucket-name/secret-object-key"
TOKEN = "tok-9f8e7d6c5b4a"


def fake_iso(game_id=b"RMCE01", nkit=False, size=4096):
    data = bytearray(size)
    data[0:6] = game_id
    if nkit:
        data[0x200:0x204] = b"NKIT"
    return bytes(data)


def fake_wbfs(game_id=b"RMCE01", size=4096):
    data = bytearray(size)
    data[0:4] = b"WBFS"
    data[8] = 9
    data[0x200:0x206] = game_id
    return bytes(data)


class Handler(http.server.BaseHTTPRequestHandler):
    body = b""
    seen = []

    def do_GET(self):
        Handler.seen.append(dict(self.headers))
        self.send_response(200)
        self.send_header("Content-Length", str(len(Handler.body)))
        self.end_headers()
        self.wfile.write(Handler.body)

    def log_message(self, *args):
        pass


class FetchDiscTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def fetch(self, body, **extra):
        Handler.body = body
        Handler.seen.clear()
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(
                os.environ,
                RUNNER_TEMP=tmp,
                GITHUB_ENV=str(Path(tmp) / "env"),
                FETCH_DISC_ALLOW_LOCAL="1",
                DISC_MIN_BYTES="1024",
                DISC_URL=f"http://127.0.0.1:{self.port}/{SECRET_PATH}?sig=abc123",
                DISC_AUTH_HEADER=f"Authorization: Bearer {TOKEN}",
            )
            env.update(extra)
            result = subprocess.run(["bash", str(CI / "fetch_disc.sh")], env=env, capture_output=True, text=True)
            files = sorted(p.name for p in Path(tmp).iterdir())
            env_file = Path(tmp, "env").read_text() if Path(tmp, "env").exists() else ""
        return result, files, env_file

    def assertQuiet(self, result):
        everything = result.stdout + result.stderr
        for secret in (SECRET_PATH, "127.0.0.1", str(self.port)):
            self.assertNotIn(secret, everything)
        self.assertNotIn(f"Bearer {TOKEN}", everything.replace(f"::add-mask::{TOKEN}", "").replace(f"::add-mask::Bearer {TOKEN}", ""))

    def test_good_iso_and_wbfs(self):
        for body, ext in ((fake_iso(), "mkw.iso"), (fake_wbfs(), "mkw.wbfs")):
            result, files, env_file = self.fetch(body)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(ext, files)
            self.assertIn(f"DISC=", env_file)
            self.assertQuiet(result)
        self.assertEqual(Handler.seen[0].get("Authorization"), f"Bearer {TOKEN}")

    def test_secret_values_are_masked(self):
        result, _, _ = self.fetch(fake_iso())
        self.assertIn("::add-mask::sig=abc123", result.stdout)
        self.assertIn(f"::add-mask::{TOKEN}", result.stdout)

    def test_truncated(self):
        result, files, _ = self.fetch(b"x" * 100)
        self.assertEqual(result.returncode, 12)
        self.assertEqual(files, [])
        self.assertQuiet(result)

    def test_wrong_region_and_not_a_disc(self):
        for game_id in (b"RMCP01", b"RMCJ01", b"RMCK01", b"ABCD12"):
            result, files, _ = self.fetch(fake_iso(game_id))
            self.assertEqual(result.returncode, 13)
            self.assertEqual(files, [])
            self.assertQuiet(result)
        result, _, _ = self.fetch(fake_wbfs(b"RMCP01"))
        self.assertEqual(result.returncode, 13)

    def test_nkit(self):
        result, files, _ = self.fetch(fake_iso(nkit=True))
        self.assertEqual(result.returncode, 14)
        self.assertEqual(files, [])

    def test_hash_mismatch_and_match(self):
        import hashlib

        body = fake_iso()
        result, files, _ = self.fetch(body, DISC_SHA256="0" * 64)
        self.assertEqual(result.returncode, 15)
        self.assertEqual(files, [])
        self.assertQuiet(result)
        result, files, _ = self.fetch(body, DISC_SHA256=hashlib.sha256(body).hexdigest().upper())
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_download_failure_never_shows_the_host(self):
        result, _, _ = self.fetch(b"", DISC_URL=f"http://127.0.0.1:1/{SECRET_PATH}")
        self.assertEqual(result.returncode, 11)
        self.assertQuiet(result)

    def test_input_validation(self):
        for url in ("", "http://example.com/disc.iso", "ftp://example.com/disc.iso", "file:///etc/passwd"):
            result, _, _ = self.fetch(fake_iso(), DISC_URL=url, FETCH_DISC_ALLOW_LOCAL="0")
            self.assertEqual(result.returncode, 10, url)
        result, _, _ = self.fetch(fake_iso(), DISC_AUTH_HEADER="no-colon-here")
        self.assertEqual(result.returncode, 10)
        result, _, _ = self.fetch(fake_iso(), DISC_SHA256="not-hex")
        self.assertEqual(result.returncode, 10)

    def test_github_api_asset_sends_octet_stream(self):
        # Only the Accept rule is checked here: it keys on the https://api.github.com/ prefix.
        text = (CI / "fetch_disc.sh").read_text()
        self.assertIn("https://api.github.com/*) printf 'Accept: application/octet-stream", text)


class LogFilterTests(unittest.TestCase):
    def run_filter(self, script, verbose="0"):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "log.txt"
            env = dict(os.environ, MKW_CI_VERBOSE=verbose)
            result = subprocess.run(
                [sys.executable, str(CI / "public_log_filter.py"), str(log), "--", sys.executable, "-c", script],
                env=env, capture_output=True, text=True)
            return result, log.read_text()

    def test_only_progress_reaches_the_public_log(self):
        script = (
            "print('Scene/UI/Title.szs 123456')\n"
            "print('[build_cia] $ python tools/extract_disc.py x data/extracted --file rel/StaticR.rel')\n"
            "print('[build_cia] step 3/57: game module')\n"
            "print('{\"sha256\": \"abc\", \"title_id\": \"0004\"}')\n"
            "print('[build_cia] disc verified: RMCE01 revision 0, 53 files')\n")
        result, log = self.run_filter(script)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), ["[build_cia] step 3/57: game module",
                                                      "[build_cia] disc verified: RMCE01 revision 0, 53 files"])
        self.assertIn("Title.szs", log)

    def test_failure_shows_a_redacted_last_line(self):
        script = ("import sys\nprint('first')\n"
                  "sys.exit(\"2 extracted files differ (first: Scene/UI/Title.szs). Use data/extracted/x now\")")
        result, _ = self.run_filter(script)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Title.szs", result.stdout)
        self.assertNotIn("data/extracted", result.stdout)
        self.assertIn("::error::", result.stdout)

    def test_verbose_prints_everything(self):
        result, _ = self.run_filter("print('Scene/UI/Title.szs 1')", verbose="1")
        self.assertIn("Title.szs", result.stdout)


class CiaCheckTests(unittest.TestCase):
    def synthetic_cia(self, title_id):
        # The 0x2020-byte header is padded to the next 0x40 boundary (0x2040), as in a real CIA.
        header = struct.pack("<IHHIII", 0x2020, 0, 0, 0x40, 0x40, 0x100) + bytes(0x2040 - 20)
        cert, ticket = bytes(0x40), bytes(0x40)
        tmd = struct.pack(">I", 0x010004) + bytes(0x100) + bytes(0x3C)
        tmd += bytes(0x4C) + struct.pack(">Q", title_id) + bytes(0x100)
        return header + cert + ticket + tmd

    def test_title_id_is_read_from_the_tmd(self):
        self.assertEqual(check_cia.cia_title_id(self.synthetic_cia(0x000400000F4B5700)), 0x000400000F4B5700)

    def test_rejects_non_cia(self):
        with self.assertRaises(ValueError):
            check_cia.cia_title_id(bytes(0x4000))


class RedactionTests(unittest.TestCase):
    def test_redact(self):
        self.assertNotIn("Title.szs", public_log_filter.redact("bad file Title.szs in build/x/y"))
        self.assertNotIn("build/x", public_log_filter.redact("bad file Title.szs in build/x/y"))


if __name__ == "__main__":
    unittest.main()
