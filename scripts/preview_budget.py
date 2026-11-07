#!/usr/bin/env python3
"""Read-only resource sampling of the locally built, owned Preview Probe only."""
import argparse
import ctypes
import json
import math
import pathlib
import platform
import plistlib
import time
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / ".local-data/build/preview-probe/Loomex Preview Probe.app"
EXECUTABLE = APP / "Contents/MacOS/PreviewExperiment"


class RusageInfoV0(ctypes.Structure):
    # sys/resource.h, RUSAGE_INFO_V0. CPU counters use Mach ticks; memory is bytes.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
            "wired_size", "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime")]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


class NativeReader:
    def __init__(self):
        if platform.system() != "Darwin":
            raise RuntimeError("Resource sampling requires macOS")
        self.libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_pidpath.restype = ctypes.c_int
        self.libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.libproc.proc_pid_rusage.restype = ctypes.c_int
        system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        system.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebase)]
        system.mach_timebase_info.restype = ctypes.c_int
        self.timebase = MachTimebase()
        if system.mach_timebase_info(ctypes.byref(self.timebase)) != 0 or not self.timebase.denom:
            raise RuntimeError("Mach clock conversion is unavailable")

    def read(self, pid, expected_path=None):
        path = ctypes.create_string_buffer(4096)
        if self.libproc.proc_pidpath(pid, path, len(path)) <= 0:
            raise RuntimeError("Target process is unavailable; sampling stopped")
        resolved_path = pathlib.Path(path.value.decode()).resolve()
        if expected_path is not None and resolved_path != expected_path:
            raise RuntimeError("Target executable is not the local Preview Probe")
        info = RusageInfoV0()
        if self.libproc.proc_pid_rusage(pid, 0, ctypes.byref(info)) != 0 or info.proc_exit_abstime:
            raise RuntimeError("Target process resource counters are unavailable")
        return {"path": resolved_path,
                "identity": (info.proc_start_abstime, bytes(info.uuid)),
                "wall_ns": time.monotonic_ns(),
                "cpu_ns": (info.user_time + info.system_time) * self.timebase.numer // self.timebase.denom,
                "footprint_bytes": info.phys_footprint, "resident_bytes": info.resident_size}


def checked_sample(reader, pid, expected_path, identity=None):
    sample = reader.read(pid, expected_path)
    if sample["path"] != expected_path:
        raise RuntimeError("Target executable is not the local Preview Probe")
    if identity is not None and sample["identity"] != identity:
        raise RuntimeError("Target process identity changed; discard this measurement")
    return sample


def validate_timing(duration, interval, settle):
    if not all(math.isfinite(value) for value in (duration, interval, settle)):
        raise ValueError("Timing values must be finite")
    if not (1 <= duration <= 180 and 0.1 <= interval <= min(10, duration) and 0 <= settle <= 60):
        raise ValueError("Use duration 1–180s, interval 0.1–10s (<= duration), settle 0–60s")


def summarize(samples):
    if len(samples) < 2:
        raise ValueError("At least two samples are required")
    for previous, current in zip(samples, samples[1:]):
        if current["identity"] != previous["identity"]:
            raise ValueError("Process identity changed")
        if current["wall_ns"] <= previous["wall_ns"] or current["cpu_ns"] < previous["cpu_ns"]:
            raise ValueError("Non-monotonic resource counters")
    elapsed = samples[-1]["wall_ns"] - samples[0]["wall_ns"]
    cpu = samples[-1]["cpu_ns"] - samples[0]["cpu_ns"]
    footprints = [sample["footprint_bytes"] for sample in samples]
    return {"sampleCount": len(samples), "elapsedSeconds": elapsed / 1e9,
            "cpuSeconds": cpu / 1e9, "oneCoreCPUPercent": cpu / elapsed * 100,
            "firstFootprintBytes": footprints[0], "lastFootprintBytes": footprints[-1],
            "minFootprintBytes": min(footprints), "maxFootprintBytes": max(footprints)}


def collect(reader, pid, expected_path, duration, interval, settle):
    validate_timing(duration, interval, settle)
    first = checked_sample(reader, pid, expected_path)
    identity = first["identity"]
    # Settling is excluded from CPU averaging, but still checks exit/PID reuse.
    deadline = time.monotonic() + settle
    while time.monotonic() < deadline:
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
        checked_sample(reader, pid, expected_path, identity)
    samples = [checked_sample(reader, pid, expected_path, identity)]
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
        samples.append(checked_sample(reader, pid, expected_path, identity))
    return samples


def expected_executable():
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    marker = json.loads((APP / "Contents/Resources/BuildInfo.json").read_text())
    if (info.get("CFBundleIdentifier") != "com.loomex.flow.p0.previewprobe"
            or marker.get("name") != "Loomex Preview Probe" or not EXECUTABLE.is_file()):
        raise RuntimeError("Build the recognized local Preview Probe first")
    return EXECUTABLE.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--phase", required=True, choices=["baseline", "preview", "cycles", "idle"])
    parser.add_argument("--duration", type=float, default=10)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--settle", type=float, default=0)
    args = parser.parse_args()
    try:
        validate_timing(args.duration, args.interval, args.settle)
        if args.pid <= 0:
            raise ValueError("PID must be positive")
        executable = expected_executable()
        print(f"Sampling {args.phase}: settle {args.settle}s, measure {args.duration}s", flush=True)
        samples = collect(NativeReader(), args.pid, executable, args.duration, args.interval, args.settle)
        summary = summarize(samples)
        started = samples[0]
        report = {"scope": "owned-preview-probe-process-only", "phase": args.phase,
                  "phaseSource": "operator-observed; collector does not control UI or capture images",
                  "method": "proc_pid_rusage/RUSAGE_INFO_V0; Mach ticks converted via mach_timebase_info; CPU delta / monotonic wall delta",
                  "system": platform.mac_ver()[0], "architecture": platform.machine(),
                  "requestedDurationSeconds": args.duration, "settleSeconds": args.settle,
                  "intervalSeconds": args.interval, "summary": summary,
                  "samples": [{"elapsedSeconds": (sample["wall_ns"] - started["wall_ns"]) / 1e9,
                               "cpuSeconds": (sample["cpu_ns"] - started["cpu_ns"]) / 1e9,
                               "footprintBytes": sample["footprint_bytes"],
                               "residentBytes": sample["resident_bytes"]} for sample in samples]}
        output = ROOT / ".local-data/p0" / ("preview-resources-" + args.phase + "-"
                 + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + ".json")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
        print(f"Local report: {output.relative_to(ROOT)}")
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"Sampling failed: {error}\n")


if __name__ == "__main__":
    main()
