#!/usr/bin/env python3
"""Run application settings persistence/state tests without GUI or system permissions."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    output = ROOT / ".local-data/build/app-settings-tests"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="settings-", dir=output) as directory:
        executable = pathlib.Path(directory) / "AppSettingsTests"
        sources = [ROOT / "Sources/LauncherProduct.swift", ROOT / "App/FlowSettings.swift",
                   ROOT / "Tests/app_settings.swift"]
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos13.0",
                        "-parse-as-library", *map(str, sources), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
