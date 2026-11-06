#!/usr/bin/env python3
"""Build and optionally open the isolated Loomex window-control experiment."""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".local-data/build/window-probe"


def test_confirmation():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="confirmation-test-", dir=OUTPUT) as directory:
        executable = pathlib.Path(directory) / "WindowProbeConfirmationTests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                        "-target", "arm64-apple-macos13.0",
                        str(ROOT / "Prototypes/WindowProbe/Controller/FixtureWindowService.swift"),
                        str(ROOT / "Tests/window_probe_confirmation.swift"), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


def build():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="window-probe-", dir=OUTPUT) as directory:
        scratch = pathlib.Path(directory)
        for name, identifier, folder in [
            ("Loomex Window Fixture", "com.loomex.flow.p0.fixture", "Fixture"),
            ("Loomex Window Probe", "com.loomex.flow.p0.windowprobe", "Controller"),
        ]:
            bundle = scratch / f"{name}.app"
            executable = bundle / "Contents/MacOS/WindowExperiment"
            resources = bundle / "Contents/Resources"
            executable.parent.mkdir(parents=True)
            resources.mkdir()
            sources = sorted((ROOT / "Prototypes/WindowProbe" / folder).glob("*.swift"))
            subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos13.0",
                            *map(str, sources), "-o", str(executable)], check=True)
            info = {"CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleDisplayName": name,
                    "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1",
                    "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
                    "NSPrincipalClass": "NSApplication"}
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            (resources / "BuildInfo.json").write_text(json.dumps({"name": name, "purpose": "P0 window experiment"}))
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)], check=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
            destination = OUTPUT / bundle.name
            if destination.exists():
                marker = destination / "Contents/Resources/BuildInfo.json"
                if not marker.exists() or json.loads(marker.read_text()).get("name") != name:
                    raise RuntimeError("Refusing to replace an unrecognized existing application")
                shutil.rmtree(destination)
            shutil.copytree(bundle, destination)
            print(f"BUILT: {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--test", action="store_true", help="Test bounded AX state confirmation without GUI or permissions")
    parser.add_argument("--launch", action="store_true")
    parser.add_argument("--verify", action="store_true", help="Create owned fixture windows and run the permission-gated checks")
    args = parser.parse_args()
    if args.test:
        test_confirmation()
    if args.build or not (args.launch or args.verify or args.test):
        build()
    if args.launch or args.verify:
        bundle = OUTPUT / "Loomex Window Probe.app"
        if not bundle.is_dir():
            raise RuntimeError("Build the window experiment with --build first")
        command = ["open", str(bundle)]
        if args.verify:
            command += ["--args", "--verify"]
        subprocess.run(command, check=True)


if __name__ == "__main__":
    main()
