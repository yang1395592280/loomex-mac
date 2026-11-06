#!/usr/bin/env python3
"""Fetch and verify the pinned AltTab baseline without changing the Loomex app."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK_PATH = ROOT / "config/upstreams/alt-tab.json"
DEFAULT_SOURCE = ROOT / ".local-data/upstream/alt-tab-macos"
DERIVED_DATA = ROOT / ".local-data/build/alt-tab"


def git_output(source, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(source), *arguments], text=True, timeout=60
    ).strip()


def fetch_source(source, lock):
    if source.exists():
        return
    source.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "clone", "--depth", "1", "--single-branch", "--branch", lock["tag"],
         "--", lock["repository"], str(source)], check=True, timeout=300
    )


def verify_source(source, lock):
    if not source.is_dir():
        raise RuntimeError("AltTab checkout not found. Run again with --fetch.")
    checkout_root = pathlib.Path(git_output(source, "rev-parse", "--show-toplevel")).resolve()
    if checkout_root != source.resolve():
        raise RuntimeError("The source directory must be a separate AltTab checkout.")
    if git_output(source, "rev-parse", "HEAD") != lock["commit"]:
        raise RuntimeError("AltTab HEAD does not match the lock. Existing checkout was preserved.")
    if git_output(source, "remote", "get-url", "origin") != lock["repository"]:
        raise RuntimeError("AltTab origin does not match the locked repository.")
    if git_output(source, "status", "--porcelain", "--untracked-files=normal"):
        raise RuntimeError("AltTab has local changes. Existing files were preserved.")
    # This ignored override can change signing, API endpoints and telemetry configuration.
    if (source / "config/local.xcconfig").exists():
        raise RuntimeError("config/local.xcconfig is present; use a separate clean baseline checkout.")
    for relative, expected in lock["sha256"].items():
        actual = hashlib.sha256((source / relative).read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError(f"Locked file checksum mismatch: {relative}")
    print(f"SOURCE VERIFIED: {lock['tag']} @ {lock['commit']}", flush=True)


def build_source(source, lock, developer_dir):
    environment = os.environ.copy()
    if developer_dir:
        selected = pathlib.Path(developer_dir).expanduser().resolve()
        if selected.suffix == ".app":
            selected = selected / "Contents/Developer"
        environment["DEVELOPER_DIR"] = str(selected)
    elif not environment.get("DEVELOPER_DIR"):
        installed = pathlib.Path("/Applications/Xcode.app/Contents/Developer")
        if installed.is_dir():
            environment["DEVELOPER_DIR"] = str(installed)
    version = subprocess.run(
        ["xcodebuild", "-version"], capture_output=True, text=True, env=environment, timeout=30
    )
    if version.returncode:
        raise RuntimeError(
            "Full Xcode is unavailable. Install and open Xcode to finish setup, then retry. "
            "For a custom installation, pass --developer-dir /path/to/Xcode.app. "
            "No global developer-directory setting was changed."
        )
    print(version.stdout.strip(), flush=True)
    subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"],
                   check=True, env=environment, timeout=30)
    # Ad-hoc signing keeps the upstream developer's certificate and Keychain out of this build.
    subprocess.run(
        ["xcodebuild", "-project", lock["project"], "-scheme", "Debug",
         "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
         "-derivedDataPath", str(DERIVED_DATA), "-disableAutomaticPackageResolution",
         "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_IDENTITY=-",
         "DEVELOPMENT_TEAM=", "OTHER_CODE_SIGN_FLAGS=--timestamp=none", "build"],
        cwd=source, check=True, env=environment, timeout=1800
    )
    bundle = DERIVED_DATA / "Build/Products/Debug/AltTab.app"
    if not bundle.is_dir():
        raise RuntimeError("xcodebuild completed without the expected AltTab.app.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)],
                   check=True, timeout=60)
    print(f"BUILD VERIFIED (not launched): {bundle}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=pathlib.Path, default=DEFAULT_SOURCE)
    parser.add_argument("--fetch", action="store_true", help="Clone only if the source directory is absent")
    parser.add_argument("--build", action="store_true", help="Build with full Xcode and verify the ad-hoc signature")
    parser.add_argument("--developer-dir", help="Xcode.app or its Contents/Developer directory; process-local only")
    args = parser.parse_args()
    lock = json.loads(LOCK_PATH.read_text(encoding="utf-8"))
    if lock.get("schemaVersion") != 1:
        raise RuntimeError("Unsupported AltTab lock schema version.")
    source = args.source_dir.expanduser().resolve()
    if args.fetch:
        fetch_source(source, lock)
    verify_source(source, lock)
    if args.build:
        build_source(source, lock, args.developer_dir)
    else:
        print("Source verification only. Use --build after full Xcode is ready.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"BASELINE BLOCKED: {error}", file=sys.stderr)
        sys.exit(1)
