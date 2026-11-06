import AppKit
import QuartzCore

@available(macOS 14.0, *)
final class PageDisplayDriver: NSObject {
    private var link: CADisplayLink?
    private var onFrame: (() -> Void)?

    init(view: NSView, onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
        super.init()
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        let rate = Float(view.window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        MotionTrace.shared.tick(at: CACurrentMediaTime())
        onFrame?()
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }
}

// Opt-in diagnostics measure app work and callback cadence, not GPU presentation FPS.
final class MotionTrace {
    static let shared = MotionTrace()
    private let enabled = ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_MOTION_TRACE"] == "1"
    private(set) var active = false
    private var kind = ""
    private var started: CFTimeInterval = 0
    private var lastTick: CFTimeInterval?
    private var intervals: [Double] = []
    private var draws = 0
    private var events = 0
    private var maximumHz = 0

    func begin(kind: String, screen: NSScreen?) {
        guard enabled else { return }
        self.kind = kind
        started = CACurrentMediaTime()
        lastTick = nil
        intervals = []
        draws = 0
        events = 0
        maximumHz = screen?.maximumFramesPerSecond ?? 0
        active = true
    }

    func draw() { if active { draws += 1 } }
    func event() { if active { events += 1 } }
    func tick(at time: CFTimeInterval) {
        guard active else { return }
        if let previous = lastTick { intervals.append((time - previous) * 1000) }
        lastTick = time
    }

    func finish() {
        guard active else { return }
        active = false
        let sorted = intervals.sorted()
        let mean = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        fputs(String(format: "MOTION kind=%@ duration_ms=%.2f events=%d tile_draws=%d max_hz=%d callback_count=%d callback_mean_ms=%.2f callback_p95_ms=%.2f system_reduce_motion=%d\n",
                     kind, (CACurrentMediaTime() - started) * 1000, events, draws, maximumHz, intervals.count, mean, p95,
                     NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0), stderr)
    }
}
