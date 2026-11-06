"""Behavior checks for protecting a local upstream checkout during verification."""
import hashlib
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("alt_tab_baseline", ROOT / "scripts/alt_tab_baseline.py")
BASELINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASELINE)


class BaselineVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="loomex-baseline-test-")
        self.addCleanup(self.temporary.cleanup)
        self.source = pathlib.Path(self.temporary.name) / "upstream"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Baseline Test")
        self.git("config", "user.email", "baseline@example.invalid")
        self.git("remote", "add", "origin", "https://example.invalid/upstream.git")
        (self.source / "LICENCE.md").write_text("Fixture license\n", encoding="utf-8")
        (self.source / ".gitignore").write_text("/config/local.xcconfig\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "Fixture baseline")
        self.lock = {
            "repository": "https://example.invalid/upstream.git", "tag": "v1.0.0",
            "commit": self.git("rev-parse", "HEAD"),
            "sha256": {"LICENCE.md": hashlib.sha256(b"Fixture license\n").hexdigest()}
        }

    def git(self, *arguments):
        return subprocess.check_output(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
             "-C", str(self.source), *arguments], text=True
        ).strip()

    def test_clean_pinned_checkout_verifies(self):
        BASELINE.verify_source(self.source, self.lock)

    def test_tracked_edit_is_rejected_and_preserved(self):
        license_file = self.source / "LICENCE.md"
        license_file.write_text("Local edit\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "local changes"):
            BASELINE.verify_source(self.source, self.lock)
        self.assertEqual(license_file.read_text(), "Local edit\n")

    def test_wrong_commit_is_rejected_without_reset(self):
        self.git("commit", "--allow-empty", "-q", "-m", "Local work")
        local_head = self.git("rev-parse", "HEAD")
        with self.assertRaisesRegex(RuntimeError, "HEAD does not match"):
            BASELINE.verify_source(self.source, self.lock)
        self.assertEqual(self.git("rev-parse", "HEAD"), local_head)

    def test_untracked_source_is_rejected_and_preserved(self):
        local_file = self.source / "Local.swift"
        local_file.write_text("let localWork = true\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "local changes"):
            BASELINE.verify_source(self.source, self.lock)
        self.assertTrue(local_file.exists())

    def test_ignored_local_build_override_is_rejected(self):
        (self.source / "config").mkdir()
        override = self.source / "config/local.xcconfig"
        override.write_text("DOMAIN = example.invalid\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "local.xcconfig is present"):
            BASELINE.verify_source(self.source, self.lock)
        self.assertTrue(override.exists())

    def test_fetch_preserves_an_existing_directory(self):
        local_file = self.source / "Local.swift"
        local_file.write_text("let localWork = true\n", encoding="utf-8")
        BASELINE.fetch_source(self.source, self.lock)
        self.assertEqual(local_file.read_text(), "let localWork = true\n")

    def test_checksum_mismatch_is_rejected(self):
        self.lock["sha256"]["LICENCE.md"] = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
            BASELINE.verify_source(self.source, self.lock)

    def test_wrong_origin_is_rejected_without_replacing_it(self):
        replacement = "https://example.invalid/different-upstream.git"
        self.git("remote", "set-url", "origin", replacement)
        with self.assertRaisesRegex(RuntimeError, "origin does not match"):
            BASELINE.verify_source(self.source, self.lock)
        self.assertEqual(self.git("remote", "get-url", "origin"), replacement)


if __name__ == "__main__":
    unittest.main()
