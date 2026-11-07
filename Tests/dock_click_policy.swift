import Foundation

@main
struct DockClickPolicyTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        func gesture(_ press: DockPress, up: Double? = nil, downHit: DockHit = .fixture(dockPID: 100),
                     upHit: DockHit = .fixture(dockPID: 100), foreground: Bool = true, windows: Int = 2,
                     modifiers: Bool = false, dragged: Bool = false, distance: Double = 0,
                     clicks: Int = 1) -> DockGesture {
            DockGesture(press: press, upTime: up ?? press.time + 0.1, downHit: downHit, upHit: upHit,
                        foregroundBefore: foreground, ordinaryWindowsBefore: windows,
                        hadModifiers: modifiers, dragged: dragged, distance: distance, clickCount: clicks)
        }
        var policy = DockClickPolicy(doubleClickInterval: 0.5)
        var press = policy.begin(at: 1)
        expect(policy.finish(gesture(press)) == .pending, "Single foreground click must wait")
        expect(policy.settle(at: 1.59, for: press) == nil, "Must wait the full double-click interval after up")
        expect(policy.settle(at: 1.61, for: press) == .wouldHide, "Eligible single click must settle once")
        expect(policy.settle(at: 2, for: press) == nil, "Settlement must not repeat")

        press = policy.begin(at: 3)
        expect(policy.finish(gesture(press, foreground: false)) == .background,
               "Background before down must stay passthrough even if activated before up")
        press = policy.begin(at: 3.3)
        expect(policy.finish(gesture(press, clicks: 2)) == .rapidClick,
               "A quick second click after activation must not hide")
        press = policy.begin(at: 4)
        expect(policy.finish(gesture(press)) == .pending, "A later single click may be eligible")
        press = policy.begin(at: 4.3)
        expect(policy.settle(at: 5, for: press) == nil, "Second down must cancel the first pending candidate")
        expect(policy.finish(gesture(press)) == .rapidClick, "Rapid clicks are excluded even with clickCount=1")

        let cases: [(String, (DockPress) -> DockGesture, DockDecision)] = [
            ("No windows must preserve reopen", { gesture($0, windows: 0) }, .noWindows),
            ("Modifiers must preserve system action", { gesture($0, modifiers: true) }, .modifiers),
            ("A tiny drag event is still a drag", { gesture($0, dragged: true, distance: 0.1) }, .drag),
            ("Moved pointer must not become click", { gesture($0, distance: 4.1) }, .drag),
            ("Long press must preserve Dock menu", { gesture($0, up: $0.time + 0.6) }, .longPress),
            ("Other Dock items stay passthrough", { gesture($0, downHit: .other) }, .nonTarget),
            ("Unknown hit fails open", { gesture($0, downHit: .unavailable) }, .uncertain),
            ("Unknown release fails open", { gesture($0, upHit: .unavailable) }, .uncertain),
            ("Release on different item fails open", { gesture($0, upHit: .other) }, .uncertain),
            ("Dock restart invalidates hit", { gesture($0, upHit: .fixture(dockPID: 101)) }, .uncertain),
            ("System multiple-click count is excluded", { gesture($0, clicks: 3) }, .rapidClick),
        ]
        for (index, item) in cases.enumerated() {
            press = policy.begin(at: Double(10 + index * 2))
            expect(policy.finish(item.1(press)) == item.2, item.0)
            expect(policy.settle(at: Double(12 + index * 2), for: press) == nil, "Passthrough must not leave a candidate")
        }
        press = policy.begin(at: 40)
        _ = policy.begin(at: 41)
        expect(policy.finish(gesture(press)) == .interrupted, "Late AX results must not revive old input")
        press = policy.begin(at: 42)
        _ = policy.finish(gesture(press))
        policy.cancel()
        expect(policy.settle(at: 43, for: press) == nil, "Permission loss/pause/tap disable must cancel pending work")
        expect(policy.finish(gesture(press)) == .interrupted, "Cancellation must invalidate in-flight AX results")
        let oldPress = press
        press = policy.begin(at: 45)
        _ = policy.finish(gesture(press))
        expect(policy.settle(at: 46, for: oldPress) == nil, "An old timer cannot settle a new gesture")
        expect(policy.settle(at: 46, for: press) == .wouldHide, "The matching timer must still settle")
        func recoveryGesture(_ press: DockPress, modifiers: Bool = false, dragged: Bool = false,
                             windows: Int = 2, hit: DockHit = .fixture(dockPID: 100)) -> DockGesture {
            var value = gesture(press, upHit: hit, foreground: false, windows: windows,
                                modifiers: modifiers, dragged: dragged)
            value.hasOwnedRecovery = true
            return value
        }
        press = policy.begin(at: 50)
        expect(policy.finish(recoveryGesture(press)) == .pendingRestore, "Owned recovery must work from background")
        expect(policy.settle(at: 50.59, for: press) == nil, "Restoration must wait for multi-click cancellation")
        expect(policy.settle(at: 50.61, for: press) == .wouldRestore, "Recovery must remain distinct from collapse")
        expect(policy.settle(at: 51, for: press) == nil, "Restoration must settle once")
        press = policy.begin(at: 52)
        _ = policy.finish(recoveryGesture(press))
        press = policy.begin(at: 52.2)
        expect(policy.finish(recoveryGesture(press)) == .rapidClick, "A recovery double-click must be excluded")
        expect(policy.settle(at: 53, for: press) == nil, "Double-click must cancel pending restoration")
        for (index, item) in [(DockDecision.modifiers, true, false, 2, DockHit.fixture(dockPID: 100)),
                               (.drag, false, true, 2, .fixture(dockPID: 100)),
                               (.noWindows, false, false, 0, .fixture(dockPID: 100)),
                               (.uncertain, false, false, 2, .unavailable)].enumerated() {
            press = policy.begin(at: Double(60 + index * 2))
            expect(policy.finish(recoveryGesture(press, modifiers: item.1, dragged: item.2, windows: item.3, hit: item.4)) == item.0,
                   "Recovery cannot bypass input/identity guards")
            expect(policy.settle(at: Double(62 + index * 2), for: press) == nil, "Rejected restoration leaves no candidate")
        }
        press = policy.begin(at: 70)
        _ = policy.finish(recoveryGesture(press))
        policy.cancel()
        expect(policy.settle(at: 71, for: press) == nil, "Stopping must cancel restoration as well as collapse")
        print("Dock click policy: \(checks) passed, 0 failed")
    }
}
