import Foundation

enum DockHit: Equatable {
    case fixture(dockPID: Int32)
    case other
    case unavailable
}

enum DockDecision: String {
    case pending, wouldHide, pendingRestore, wouldRestore, background, noWindows, nonTarget
    case modifiers, drag, longPress, rapidClick, uncertain, interrupted
}

struct DockPress {
    let sequence: Int
    let time: TimeInterval
    let rapid: Bool
}

struct DockGesture {
    let press: DockPress
    let upTime: TimeInterval
    let downHit: DockHit
    let upHit: DockHit
    let foregroundBefore: Bool
    let ordinaryWindowsBefore: Int
    let hadModifiers: Bool
    let dragged: Bool
    let distance: Double
    let clickCount: Int
    var hasOwnedRecovery = false
}

// This experiment decides what it would do; it never consumes input or controls a window.
struct DockClickPolicy {
    let doubleClickInterval: TimeInterval
    private var sequence = 0
    private var lastDown: TimeInterval?
    private var deadline: TimeInterval?
    private var settledDecision = DockDecision.wouldHide

    init(doubleClickInterval: TimeInterval) {
        self.doubleClickInterval = doubleClickInterval
    }

    mutating func begin(at time: TimeInterval) -> DockPress {
        sequence += 1
        deadline = nil
        let rapid = lastDown.map { time - $0 >= 0 && time - $0 <= doubleClickInterval } ?? false
        lastDown = time
        return DockPress(sequence: sequence, time: time, rapid: rapid)
    }

    mutating func finish(_ gesture: DockGesture) -> DockDecision {
        guard gesture.press.sequence == sequence else { return .interrupted }
        guard case .fixture(let downPID) = gesture.downHit else {
            return gesture.downHit == .other ? .nonTarget : .uncertain
        }
        guard gesture.upHit == .fixture(dockPID: downPID) else { return .uncertain }
        guard !gesture.hadModifiers else { return .modifiers }
        guard !gesture.dragged && gesture.distance <= 4 else { return .drag }
        let duration = gesture.upTime - gesture.press.time
        guard duration >= 0 && duration <= 0.5 else { return .longPress }
        guard !gesture.press.rapid && gesture.clickCount == 1 else { return .rapidClick }
        guard gesture.ordinaryWindowsBefore > 0 else { return .noWindows }
        guard gesture.foregroundBefore || gesture.hasOwnedRecovery else { return .background }
        // Wait after mouse-up so a second down can cancel the entire click burst.
        deadline = gesture.upTime + doubleClickInterval
        settledDecision = gesture.hasOwnedRecovery ? .wouldRestore : .wouldHide
        return gesture.hasOwnedRecovery ? .pendingRestore : .pending
    }

    mutating func settle(at time: TimeInterval, for press: DockPress) -> DockDecision? {
        guard press.sequence == sequence, let deadline, time >= deadline else { return nil }
        self.deadline = nil
        return settledDecision
    }

    mutating func cancel() {
        sequence += 1
        deadline = nil
        lastDown = nil
    }
}
