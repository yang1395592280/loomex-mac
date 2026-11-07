import Foundation

@main
struct DockObservationSessionTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            checks += 1
        }
        var session = DockObservationSession()
        expect(session.current == nil, "No callback is admitted before start")
        let old = session.begin(dockPID: 100)
        expect(session.permits(old, dockPID: 100), "Current Dock and session may proceed")
        expect(!session.permits(old, dockPID: nil), "A missing Dock must fail open")
        expect(!session.permits(old, dockPID: 101), "Dock changing after mouse-up must reject settlement")
        session.end()
        expect(!session.accepts(old), "Stopping invalidates queued AX results and timers")
        let fresh = session.begin(dockPID: 100)
        expect(fresh != old, "Restarting with the same Dock PID must still create a new session")
        expect(!session.accepts(old), "Old callbacks cannot use a fresh tap")
        // This is the admission used by delayed tap-disabled and timeout callbacks.
        if session.accepts(old) { session.end() }
        expect(session.permits(fresh, dockPID: 100), "An old disabled notification cannot stop the new tap")
        let replacement = session.begin(dockPID: 101)
        expect(!session.permits(fresh, dockPID: 100), "Old process identity cannot outlive a new session")
        expect(session.permits(replacement, dockPID: 101), "Explicit start accepts the new Dock")

        for restoring in [false, true] {
            var policy = DockClickPolicy(doubleClickInterval: 0.5)
            let token = session.begin(dockPID: 200)
            let press = policy.begin(at: 1)
            var gesture = DockGesture(press: press, upTime: 1.1,
                downHit: .fixture(dockPID: 200), upHit: .fixture(dockPID: 200),
                foregroundBefore: !restoring, ordinaryWindowsBefore: 2, hadModifiers: false,
                dragged: false, distance: 0, clickCount: 1)
            gesture.hasOwnedRecovery = restoring
            expect(policy.finish(gesture) == (restoring ? .pendingRestore : .pending), "Create a real policy candidate")
            // Same down/up PID is insufficient: the Dock can restart during the double-click interval.
            if !session.permits(token, dockPID: 201) { session.end(); policy.cancel() }
            expect(policy.settle(at: 2, for: press) == nil, "Environment loss cancels both action kinds")
            let next = session.begin(dockPID: 201)
            expect(!session.accepts(token), "Environment loss invalidates in-flight work")
            let nextPress = policy.begin(at: 3)
            var nextGesture = DockGesture(press: nextPress, upTime: 3.1,
                downHit: .fixture(dockPID: 201), upHit: .fixture(dockPID: 201),
                foregroundBefore: !restoring, ordinaryWindowsBefore: 2, hadModifiers: false,
                dragged: false, distance: 0, clickCount: 1)
            nextGesture.hasOwnedRecovery = restoring
            _ = policy.finish(nextGesture)
            expect(session.permits(next, dockPID: 201), "Restart must revalidate the environment")
            expect(policy.settle(at: 4, for: nextPress) == (restoring ? .wouldRestore : .wouldHide),
                   "A fresh eligible gesture still works after restart")
        }
        session.end()
        session.end()
        expect(session.current == nil, "Repeated teardown is harmless")
        print("Dock observation session: \(checks) passed, 0 failed")
    }
}
