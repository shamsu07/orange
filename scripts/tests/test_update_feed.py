"""Release feed boundaries; runs with Python's standard library on macOS or Linux."""
import base64
import datetime as dt
import importlib.util
from pathlib import Path
import plistlib
import os
import subprocess
import sys
import tempfile
import unittest
import warnings
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("update_feed", ROOT / "scripts/make-update-feed.py")
feed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feed)


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".cache/feed-tests"
        cache.mkdir(parents=True, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=cache)
        self.root = Path(self.directory.name)
        self.archive = self.root / "Orange-0.1.5-macos-arm64.zip"
        self.key = self.root / "private.key"
        self.key.write_text("test-placeholder-key")
        self.key.chmod(0o600)
        self.output = self.root / "appcast.xml"
        self.signer = self.root / "sign_update"
        self.signature = base64.b64encode(bytes(range(64))).decode()
        self.date = dt.datetime(2026, 10, 23, 10, 0, tzinfo=dt.timezone.utc)
        self.info = {
            "CFBundleIdentifier": "org.orange.converter",
            "CFBundleShortVersionString": "0.1.5", "CFBundleVersion": "6",
            "LSMinimumSystemVersion": "13.0", "SUFeedURL": feed.FEED_URL,
            "SUPublicEDKey": base64.b64encode(bytes(range(32))).decode(),
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
        }
        self.write_archive()

    def tearDown(self):
        self.directory.cleanup()

    def write_archive(self):
        with zipfile.ZipFile(self.archive, "w") as package:
            package.writestr("Orange.app/Contents/Info.plist", plistlib.dumps(self.info))

    def test_archive_version_and_security_requirements_match(self):
        self.assertEqual(feed.read_archive_info(self.archive, "0.1.5", 6, "13.0"), self.info)
        for name, wrong_value in [("CFBundleVersion", "7"), ("CFBundleIdentifier", "other.app"),
                                  ("SUFeedURL", "http://insecure.example/feed"),
                                  ("SURequireSignedFeed", False), ("SUVerifyUpdateBeforeExtraction", False),
                                  ("SUPublicEDKey", "malformed")]:
            with self.subTest(field=name):
                original = self.info[name]
                self.info[name] = wrong_value
                self.write_archive()
                with self.assertRaises(feed.FeedError):
                    feed.read_archive_info(self.archive, "0.1.5", 6, "13.0")
                self.info[name] = original

    def test_archive_rejects_duplicate_or_oversized_plist(self):
        with zipfile.ZipFile(self.archive, "w") as package:
            package.writestr("Orange.app/Contents/Info.plist", b"x" * 1_048_577)
        with self.assertRaises(feed.FeedError):
            feed.read_archive_info(self.archive, "0.1.5", 6, "13.0")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "w") as package:
                package.writestr("Orange.app/Contents/Info.plist", plistlib.dumps(self.info))
                package.writestr("Orange.app/Contents/Info.plist", plistlib.dumps(self.info))
        with self.assertRaises(feed.FeedError):
            feed.read_archive_info(self.archive, "0.1.5", 6, "13.0")
        with zipfile.ZipFile(self.archive, "w") as package:
            package.writestr("different.app/Contents/Info.plist", plistlib.dumps(self.info))
        with self.assertRaises(feed.FeedError):
            feed.read_archive_info(self.archive, "0.1.5", 6, "13.0")

    def test_feed_uses_actual_bytes_and_escapes_notes(self):
        content = feed.feed_bytes("0.1.5", 6, self.archive, self.signature, "13.0",
                                  'Fix <video> & "images"', self.date)
        parsed = ET.fromstring(content)
        item = parsed.find("./channel/item")
        self.assertEqual(item.findtext("description"), '<p>Fix &lt;video&gt; &amp; &quot;images&quot;</p>')
        self.assertEqual(item.findtext(f"{{{feed.SPARKLE}}}version"), "6")
        self.assertEqual(item.findtext(f"{{{feed.SPARKLE}}}minimumSystemVersion"), "13.0")
        enclosure = item.find("enclosure")
        self.assertEqual(int(enclosure.get("length")), self.archive.stat().st_size)
        self.assertEqual(enclosure.get(f"{{{feed.SPARKLE}}}edSignature"), self.signature)
        self.assertEqual(enclosure.get("url"),
                         "https://github.com/shamsu07/orange/releases/download/v0.1.5/Orange-0.1.5-macos-arm64.zip")

    def test_invalid_versions_signatures_and_dates_fail(self):
        for version in ["1.2", "01.2.3", "1.2.3-beta", "../../release", "1.2.3?x=1"]:
            with self.subTest(version=version), self.assertRaises(feed.FeedError):
                feed.version_numbers(version)
        with self.assertRaises(feed.FeedError):
            feed.feed_bytes("0.1.5", 6, self.archive, "invalid", "13.0", "", self.date)
        with self.assertRaises(feed.FeedError):
            feed.feed_bytes("0.1.5", 6, self.archive, self.signature, "13.0", "", dt.datetime(2026, 1, 1))

    def test_refuses_downgrade_or_reused_build(self):
        self.output.write_bytes(feed.feed_bytes("0.1.5", 6, self.archive, self.signature, "13.0", "", self.date))
        feed.validate_existing_feed(self.output, "0.1.5", 6)
        feed.validate_existing_feed(self.output, "0.1.6", 7)
        for version, build in [("0.1.4", 5), ("0.1.4", 7), ("0.1.6", 6)]:
            with self.subTest(version=version, build=build), self.assertRaises(feed.FeedError):
                feed.validate_existing_feed(self.output, version, build)

    def test_atomic_publish_requires_archive_feed_and_embedded_key_verification(self):
        calls = []
        def runner(arguments, **kwargs):
            calls.append(arguments)
            return self.signature if "-p" in arguments else ""
        feed.create_feed(self.archive, self.output, self.key, self.signer, "0.1.5", 6,
                         "13.0", "Release", self.date, runner=runner)
        self.assertEqual(len(calls), 5)
        self.assertEqual(calls[0][-2:], ["-p", str(self.archive)])
        self.assertIn("--verify", calls[1])
        self.assertEqual(calls[2][0], "swift")
        self.assertEqual(calls[2][-3:], [self.info["SUPublicEDKey"], self.signature, str(self.archive)])
        self.assertEqual(calls[3][-1], calls[4][-1])
        self.assertIn("--verify", calls[4])
        self.assertTrue(self.output.is_file())
        self.assertNotIn(self.key.read_text(), str(calls))
        self.assertFalse(list(self.root.glob(".appcast-*")))

    def test_signing_failure_preserves_previous_feed_and_cleans_stage(self):
        previous = feed.feed_bytes("0.1.5", 6, self.archive, self.signature, "13.0", "Previous", self.date)
        self.output.write_bytes(previous)
        def runner(arguments, **kwargs):
            if "--verify" in arguments and arguments[-1].endswith("appcast.xml"):
                raise feed.FeedError("signature verification failed")
            return self.signature if "-p" in arguments else ""
        with self.assertRaises(feed.FeedError):
            feed.create_feed(self.archive, self.output, self.key, self.signer, "0.1.5", 6,
                             "13.0", "Changed", self.date, runner=runner)
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertFalse(list(self.root.glob(".appcast-*")))

    def test_rejects_readable_private_key(self):
        self.key.chmod(0o644)
        with self.assertRaises(feed.FeedError):
            feed.create_feed(self.archive, self.output, self.key, self.signer, "0.1.5", 6,
                             "13.0", "", self.date, runner=lambda *args, **kwargs: self.fail("must not sign"))

    @unittest.skipUnless(sys.platform == "darwin" and (ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update").is_file(),
                         "Real signature integration requires macOS and resolved Sparkle artifacts")
    def test_real_signatures_reject_tampered_feed_and_wrong_embedded_key(self):
        generator = self.root / "generate-test-key.swift"
        generator.write_text('''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
try Data((key.rawRepresentation.base64EncodedString() + "\\n").utf8)
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
''')
        environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(ROOT / ".cache/clang"),
                           SWIFTPM_MODULECACHE_OVERRIDE=str(ROOT / ".cache/swift-modules"))
        self.info["SUPublicEDKey"] = subprocess.check_output(
            ["swift", str(generator), str(self.key)], text=True, env=environment).strip()
        self.key.chmod(0o600)
        self.write_archive()
        signer = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        feed.create_feed(self.archive, self.output, self.key, signer, "0.1.5", 6,
                         "13.0", "Signed test release", self.date)
        original = self.output.read_bytes()
        self.assertIn(b"Signed test release", original)
        self.output.write_bytes(original.replace(b"Signed test release", b"Altered test release"))
        rejected = subprocess.run([str(signer), "--verify", "--ed-key-file", str(self.key), str(self.output)],
                                  capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        self.output.unlink()
        self.info["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()
        self.write_archive()
        with self.assertRaises(feed.FeedError):
            feed.create_feed(self.archive, self.output, self.key, signer, "0.1.5", 6,
                             "13.0", "", self.date)
        self.assertFalse(self.output.exists())

    def test_paths_cannot_escape_repository(self):
        with self.assertRaises(feed.FeedError):
            feed.repo_path(ROOT.parent, existing=True)
        self.assertEqual(feed.repo_path(self.archive), self.archive)


if __name__ == "__main__":
    unittest.main()
