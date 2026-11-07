#!/usr/bin/env python3
"""Build the isolated, observation-only Dock input experiment and its policy tests."""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".local-data/build/dock-probe"
NAME = "Loomex Dock Input Probe"


def compile_swift(sources, executable, library=False):
    command = ["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos13.0"]
    if library:
        command.append("-parse-as-library")
    subprocess.run([*command, *map(str, sources), "-o", str(executable)], check=True)


def test_policy():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dock-policy-", dir=OUTPUT) as directory:
        executable = pathlib.Path(directory) / "DockClickPolicyTests"
        compile_swift([ROOT / "Prototypes/DockProbe/DockClickPolicy.swift",
                       ROOT / "Tests/dock_click_policy.swift"], executable, library=True)
        subprocess.run([str(executable)], check=True)


def build():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dock-probe-", dir=OUTPUT) as directory:
        bundle = pathlib.Path(directory) / f"{NAME}.app"
        executable = bundle / "Contents/MacOS/DockInputExperiment"
        executable.parent.mkdir(parents=True)
        resources = bundle / "Contents/Resources"
        resources.mkdir()
        compile_swift(sorted((ROOT / "Prototypes/DockProbe").glob("*.swift")), executable)
        info = {"CFBundleIdentifier": "com.loomex.flow.p0.dockprobe", "CFBundleName": NAME,
                "CFBundleDisplayName": NAME, "CFBundleExecutable": executable.name,
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication"}
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (resources / "BuildInfo.json").write_text(json.dumps({"name": NAME, "purpose": "P0 Dock observation"}))
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
        destination = OUTPUT / bundle.name
        if destination.exists():
            marker = destination / "Contents/Resources/BuildInfo.json"
            if not marker.exists() or json.loads(marker.read_text()).get("name") != NAME:
                raise RuntimeError("Refusing to replace an unrecognized existing application")
            shutil.rmtree(destination)
        shutil.copytree(bundle, destination)
        print(f"BUILT: {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true", help="Run policy tests without GUI or permissions")
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--launch", action="store_true")
    args = parser.parse_args()
    if args.test:
        test_policy()
    if args.build or not (args.test or args.launch):
        build()
    if args.launch:
        bundle = OUTPUT / f"{NAME}.app"
        if not bundle.is_dir():
            raise RuntimeError("Build the Dock experiment with --build first")
        subprocess.run(["open", str(bundle)], check=True)


if __name__ == "__main__":
    main()
