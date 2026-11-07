#!/usr/bin/env python3
"""Build the isolated, same-process sample preview experiment and lifecycle tests."""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".local-data/build/preview-probe"
NAME = "Loomex Preview Probe"


def compile_swift(sources, executable, library=False, screenshot_api=False):
    command = ["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos13.0"]
    if library:
        command.append("-parse-as-library")
    if screenshot_api:
        command += ["-D", "LOOMEX_SCREENSHOT_API"]
    subprocess.run([*command, *map(str, sources), "-o", str(executable)], check=True)


def test_state():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="preview-state-", dir=OUTPUT) as directory:
        executable = pathlib.Path(directory) / "PreviewCaptureStateTests"
        compile_swift([ROOT / "Prototypes/PreviewProbe/PreviewCaptureState.swift",
                       ROOT / "Tests/preview_capture_state.swift"], executable, library=True)
        subprocess.run([str(executable)], check=True)


def build():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="preview-probe-", dir=OUTPUT) as directory:
        bundle = pathlib.Path(directory) / f"{NAME}.app"
        executable = bundle / "Contents/MacOS/PreviewExperiment"
        resources = bundle / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir()
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
        screenshot_api = int(sdk.split(".")[0]) >= 26
        compile_swift(sorted((ROOT / "Prototypes/PreviewProbe").glob("*.swift")), executable,
                      screenshot_api=screenshot_api)
        info = {"CFBundleIdentifier": "com.loomex.flow.p0.previewprobe", "CFBundleName": NAME,
                "CFBundleDisplayName": NAME, "CFBundleExecutable": executable.name,
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication"}
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (resources / "BuildInfo.json").write_text(json.dumps({"name": NAME, "purpose": "P0 owned preview experiment",
                                                               "sdk": sdk, "screenshotAPICompiled": screenshot_api}))
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
    parser.add_argument("--test", action="store_true", help="Test capture admission and release without permissions")
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args()
    if args.test:
        test_state()
    if args.build or not args.test:
        build()


if __name__ == "__main__":
    main()
