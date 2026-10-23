#!/usr/bin/env python3
"""Create Orange's signed Sparkle feed from an already packaged release ZIP."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import email.utils
import html
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED_URL = "https://shamsu07.github.io/orange/appcast.xml"
PRODUCT_URL = "https://shamsu07.github.io/orange/"
ET.register_namespace("sparkle", SPARKLE)


class FeedError(ValueError):
    """An input or signing failure that must stop publication."""


def repo_path(value: str | Path, *, existing: bool = True) -> Path:
    path = Path(value).resolve(strict=existing)
    if not path.is_relative_to(ROOT):
        raise FeedError("Release inputs and outputs must remain inside this repository.")
    return path


def version_numbers(version: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        raise FeedError("A stable release version must have the form 0.1.5.")
    return tuple(int(part) for part in version.split("."))


def read_archive_info(archive: Path, version: str, build: int, minimum_system: str) -> dict:
    version_numbers(version)
    if build < 1:
        raise FeedError("The bundle build must be a positive integer.")
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", minimum_system):
        raise FeedError("The minimum macOS version must be numeric.")
    if archive.name != f"Orange-{version}-macos-arm64.zip":
        raise FeedError("The update archive must use Orange's versioned arm64 ZIP filename.")
    try:
        with zipfile.ZipFile(archive) as package:
            entries = [item for item in package.infolist() if item.filename == "Orange.app/Contents/Info.plist"]
            if len(entries) != 1 or entries[0].file_size > 1_048_576:
                raise FeedError("The archive must contain one bounded Orange.app Info.plist.")
            info = plistlib.loads(package.read(entries[0]))
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException, ValueError) as error:
        if isinstance(error, FeedError):
            raise
        raise FeedError("The update archive or its Info.plist is invalid.") from error
    if not isinstance(info, dict):
        raise FeedError("The archive Info.plist must be a dictionary.")
    expected = {
        "CFBundleIdentifier": "org.orange.converter",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": str(build),
        "LSMinimumSystemVersion": minimum_system,
        "SUFeedURL": FEED_URL,
    }
    for name, value in expected.items():
        if info.get(name) != value:
            raise FeedError(f"The archive's {name} does not match the release configuration.")
    try:
        if len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) != 32:
            raise FeedError("The archive must embed a 32-byte Sparkle public key.")
    except (ValueError, TypeError) as error:
        raise FeedError("The archive must embed a valid Sparkle public key.") from error
    if info.get("SURequireSignedFeed") is not True or info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise FeedError("The app must require signed feeds and verify archives before extraction.")
    return info


def validate_existing_feed(path: Path, version: str, build: int) -> None:
    if not path.exists():
        return
    if path.stat().st_size > 1_048_576:
        raise FeedError("The existing feed is unexpectedly large.")
    try:
        feed = ET.parse(path)
        for item in feed.findall("./channel/item"):
            prior_build = int(item.findtext(f"{{{SPARKLE}}}version", "0"))
            prior_version = item.findtext(f"{{{SPARKLE}}}shortVersionString", "")
            if prior_build > build:
                raise FeedError("Refusing to replace a newer update feed with an older build.")
            if prior_build == build and prior_version != version:
                raise FeedError("A bundle build number cannot identify two different versions.")
            if prior_version and version_numbers(prior_version) > version_numbers(version):
                raise FeedError("Refusing to publish a version downgrade.")
    except (ET.ParseError, OSError, ValueError) as error:
        if isinstance(error, FeedError):
            raise
        raise FeedError("The existing update feed is invalid; inspect it before replacing it.") from error


def feed_bytes(version: str, build: int, archive: Path, signature: str,
               minimum_system: str, notes: str, published_at: dt.datetime) -> bytes:
    version_numbers(version)
    if published_at.tzinfo is None:
        raise FeedError("The release date must include a time zone.")
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise FeedError("The archive signer returned an invalid Ed25519 signature.")
    except (ValueError, TypeError) as error:
        raise FeedError("The archive signer returned invalid signature data.") from error
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Orange updates"
    ET.SubElement(channel, "link").text = PRODUCT_URL
    ET.SubElement(channel, "description").text = "Stable Orange releases for macOS."
    ET.SubElement(channel, "language").text = "en"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Orange {version}"
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(published_at.astimezone(dt.timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = str(build)
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = minimum_system
    ET.SubElement(item, "link").text = f"https://github.com/shamsu07/orange/releases/tag/v{version}"
    # Sparkle interprets description as HTML after XML decoding. Escape the plain
    # release-note text separately so filenames or markup cannot become HTML.
    plain_notes = notes.strip() or f"Orange {version}. See the release page for changes."
    ET.SubElement(item, "description").text = "".join(
        "<p>" + html.escape(paragraph).replace("\n", "<br>") + "</p>"
        for paragraph in plain_notes.split("\n\n"))
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/shamsu07/orange/releases/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(rss, space="  ")
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


def run_tool(arguments: list[str], *, env: dict[str, str] | None = None) -> str:
    try:
        result = subprocess.run(arguments, check=True, capture_output=True, text=True, env=env, timeout=180)
    except (OSError, subprocess.SubprocessError) as error:
        # Signing tools can include key material in diagnostics for malformed inputs.
        # Never forward their output to a CI log or include the private key in argv.
        raise FeedError(f"{Path(arguments[0]).name} failed. No feed was published.") from error
    return result.stdout.strip()


def create_feed(archive: Path, output: Path, key: Path, signer: Path, version: str,
                build: int, minimum_system: str, notes: str, published_at: dt.datetime,
                *, runner=run_tool) -> None:
    info = read_archive_info(archive, version, build, minimum_system)
    validate_existing_feed(output, version, build)
    if key.stat().st_mode & 0o077:
        raise FeedError("The update private key must be readable only by its owner (chmod 600).")
    if key.stat().st_size > 1024:
        raise FeedError("The update private key file is unexpectedly large.")
    signature = runner([str(signer), "--ed-key-file", str(key), "-p", str(archive)])
    content = feed_bytes(version, build, archive, signature, minimum_system, notes, published_at)
    runner([str(signer), "--verify", "--ed-key-file", str(key), str(archive), signature])
    environment = dict(os.environ)
    environment["CLANG_MODULE_CACHE_PATH"] = str(ROOT / ".cache/clang")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(ROOT / ".cache/swift-modules")
    runner(["swift", str(ROOT / "scripts/verify-update-signature.swift"),
            info["SUPublicEDKey"], signature, str(archive)], env=environment)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Sign and verify a private staging file. Replacing the public feed is the last
    # operation, so failures leave the prior signed bytes intact.
    with tempfile.TemporaryDirectory(prefix=".appcast-", dir=output.parent) as temporary:
        staged = Path(temporary) / "appcast.xml"
        staged.write_bytes(content)
        runner([str(signer), "--ed-key-file", str(key), str(staged)])
        runner([str(signer), "--verify", "--ed-key-file", str(key), str(staged)])
        os.chmod(staged, 0o644)
        os.replace(staged, output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, help="Packaged arm64 ZIP inside this repository")
    parser.add_argument("--version", required=True, help="Stable version, for example 0.1.5")
    parser.add_argument("--build", required=True, type=int, help="Monotonically increasing CFBundleVersion")
    parser.add_argument("--key", default=str(ROOT / ".orange-secrets/sparkle-ed25519.key"))
    parser.add_argument("--signer", default=str(ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"))
    parser.add_argument("--output", default=str(ROOT / "site/appcast.xml"))
    parser.add_argument("--minimum-system", default="13.0")
    parser.add_argument("--notes", help="UTF-8 plain text release notes file inside this repository")
    parser.add_argument("--published-at", help="ISO-8601 timestamp including time zone; defaults to now")
    arguments = parser.parse_args()
    try:
        published = (dt.datetime.fromisoformat(arguments.published_at.replace("Z", "+00:00"))
                     if arguments.published_at else dt.datetime.now(dt.timezone.utc))
        notes = repo_path(arguments.notes).read_text(encoding="utf-8") if arguments.notes else ""
        if len(notes.encode("utf-8")) > 65_536:
            raise FeedError("Release notes must be no larger than 64 KiB.")
        create_feed(repo_path(arguments.archive), repo_path(arguments.output, existing=False),
                    repo_path(arguments.key), repo_path(arguments.signer), arguments.version,
                    arguments.build, arguments.minimum_system, notes, published)
    except (FeedError, OSError, ValueError) as error:
        print(f"Update feed failed: {error}", file=sys.stderr)
        return 1
    print("Signed and verified site/appcast.xml. Do not modify it without signing it again.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
