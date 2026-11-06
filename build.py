#!/usr/bin/env python3
"""Build a standalone local macOS .app with Command Line Tools, without Xcode or third-party packages."""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent


def run(*arguments):
    subprocess.run([str(argument) for argument in arguments], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "dist")
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="classic-build-", dir=output) as scratch:
        scratch = pathlib.Path(scratch)
        swift_flags = ["-target", "arm64-apple-macos13.0"]
        compiler = pathlib.Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
        includes = compiler.parent.parent / "include/swift"
        module_map = includes / "module.modulemap"
        bridging_map = includes / "bridging.modulemap"
        if (module_map.exists() and bridging_map.exists()
                and "module SwiftBridging" in module_map.read_text()
                and "module SwiftBridging" in bridging_map.read_text()):
            # Some CLT installations retain the old modulemap after upgrading. Hide the duplicate
            # in a compiler-only virtual filesystem; never alter the installed toolchain.
            empty_map = scratch / "empty.modulemap"
            empty_map.write_text("// Duplicate SwiftBridging module hidden for this build.\n")
            overlay = scratch / "overlay.json"
            overlay.write_text(json.dumps({"version": 0, "roots": [{"type": "file", "name": str(module_map),
                                                                   "external-contents": str(empty_map)}]}))
            swift_flags += ["-vfsoverlay", str(overlay)]
        if args.test:
            binary = scratch / "ModelTests"
            run("xcrun", "swiftc", *swift_flags, "-swift-version", "5",
                *sorted(path for path in (ROOT / "Sources").glob("*.swift") if path.name != "main.swift"),
                ROOT / "Tests/main.swift", "-o", binary)
            run(binary)
        bundle = scratch / "经典启动台.app"
        executable = bundle / "Contents/MacOS/ClassicLaunchpad"
        resources = bundle / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        run("xcrun", "swiftc", "-O", "-whole-module-optimization", "-swift-version", "5",
            *swift_flags, "-module-name", "ClassicLaunchpad",
            *sorted((ROOT / "Sources").glob("*.swift")), "-o", executable)
        info = {
            "CFBundleIdentifier": "local.classiclaunchpad.desktop",
            "CFBundleName": "经典启动台", "CFBundleDisplayName": "经典启动台",
            "CFBundleExecutable": "ClassicLaunchpad", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.6", "CFBundleVersion": "7",
            "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
            "NSSupportsAutomaticGraphicsSwitching": True,
            "CFBundleDevelopmentRegion": "zh_CN", "CFBundleIconFile": "AppIcon",
            "NSHumanReadableCopyright": "Classic Launchpad — independent local replacement. Not affiliated with Apple.",
        }
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        run("xcrun", "swift", *swift_flags, ROOT / "make_icon.swift", scratch / "icon.png")
        iconset = scratch / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                run("sips", "-z", size * scale, size * scale, scratch / "icon.png", "--out", iconset / f"icon_{size}x{size}{suffix}.png")
        run("iconutil", "-c", "icns", iconset, "-o", resources / "AppIcon.icns")
        (resources / "BuildInfo.json").write_text(json.dumps({"name": "ClassicLaunchpad", "version": "1.0.6", "architecture": "arm64", "signing": "ad-hoc"}), encoding="utf-8")
        run("codesign", "--force", "--sign", "-", "--timestamp=none", bundle)
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", bundle)
        destination = output / bundle.name
        if destination.exists():
            marker = destination / "Contents/Resources/BuildInfo.json"
            if not marker.exists() or json.loads(marker.read_text()).get("name") != "ClassicLaunchpad":
                raise RuntimeError("Refusing to replace an unrecognized existing application")
            shutil.rmtree(destination)
        shutil.copytree(bundle, destination)
        print(f"BUILT: {destination}")


if __name__ == "__main__":
    main()
