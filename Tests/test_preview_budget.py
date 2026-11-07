"""Guard against sampling unrelated/reused processes and misleading resource math."""
import importlib.util
import os
import pathlib
import platform
import time
import unittest
from unittest.mock import Mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("preview_budget", ROOT / "scripts/preview_budget.py")
BUDGET = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUDGET)


class PreviewBudgetTests(unittest.TestCase):
    def sample(self, wall=1_000_000_000, cpu=30_000_000, footprint=5_000_000):
        return {"path": pathlib.Path("/owned/PreviewExperiment"), "identity": (123, b"fixture"),
                "wall_ns": wall, "cpu_ns": cpu, "footprint_bytes": footprint, "resident_bytes": 9_000_000}

    def test_unrelated_executable_is_rejected(self):
        reader = Mock()
        reader.read.return_value = self.sample()
        with self.assertRaisesRegex(RuntimeError, "not the local Preview Probe"):
            BUDGET.checked_sample(reader, 123, pathlib.Path("/different/PreviewExperiment"))

    def test_reused_pid_is_rejected_even_for_same_binary(self):
        sample = self.sample()
        reader = Mock()
        reader.read.return_value = sample
        with self.assertRaisesRegex(RuntimeError, "identity changed"):
            BUDGET.checked_sample(reader, 123, sample["path"], (999, b"fixture"))

    def test_cpu_uses_delta_over_one_core_wall_time_and_footprint_is_not_rss(self):
        summary = BUDGET.summarize([self.sample(), self.sample(3_000_000_000, 180_000_000, 6_000_000)])
        self.assertEqual(summary["elapsedSeconds"], 2)
        self.assertEqual(summary["cpuSeconds"], 0.15)
        self.assertAlmostEqual(summary["oneCoreCPUPercent"], 7.5)
        self.assertEqual(summary["maxFootprintBytes"], 6_000_000)

    def test_counter_reset_cannot_look_like_idle_cpu(self):
        with self.assertRaisesRegex(ValueError, "Non-monotonic"):
            BUDGET.summarize([self.sample(), self.sample(2_000_000_000, 0)])

    def test_zero_or_backwards_wall_interval_is_rejected(self):
        for wall in [0, 1_000_000_000]:
            with self.subTest(wall=wall), self.assertRaises(ValueError):
                BUDGET.summarize([self.sample(), self.sample(wall)])

    def test_mixed_process_series_is_rejected(self):
        second = self.sample(2_000_000_000)
        second["identity"] = (456, b"fixture")
        with self.assertRaisesRegex(ValueError, "identity changed"):
            BUDGET.summarize([self.sample(), second])

    def test_single_point_is_not_a_cpu_measurement(self):
        with self.assertRaises(ValueError):
            BUDGET.summarize([self.sample()])

    def test_invalid_and_unbounded_sampling_is_rejected(self):
        for values in [(float("nan"), 1, 0), (10, float("inf"), 0), (0, 1, 0),
                       (181, 1, 0), (10, 0, 0), (1, 2, 0), (10, 1, -1), (10, 1, 61)]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                BUDGET.validate_timing(*values)

    @unittest.skipUnless(platform.system() == "Darwin", "Native ABI check requires macOS")
    def test_native_cpu_units_match_independent_process_clock(self):
        reader = BUDGET.NativeReader()
        first = reader.read(os.getpid())
        before = time.process_time_ns()
        while time.process_time_ns() - before < 100_000_000:
            pass
        after = time.process_time_ns()
        second = reader.read(os.getpid())
        self.assertEqual(first["identity"], second["identity"])
        self.assertGreater(first["footprint_bytes"], 0)
        self.assertTrue(first["path"].is_file())
        self.assertAlmostEqual((second["cpu_ns"] - first["cpu_ns"]) / (after - before), 1, delta=0.2)


if __name__ == "__main__":
    unittest.main()
