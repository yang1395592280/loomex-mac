import ApplicationServices
import Foundation

@main
struct WindowProbeConfirmationTests {
    static func main() throws {
        let service = FixtureWindowService()
        var checks = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }

        var reads = 0
        var pauses = 0
        try service.waitFor(pause: { pauses += 1 }) {
            reads += 1
            if reads < 3 { throw ProbeError.accessibility("AXIdentifier", AXError.cannotComplete.rawValue) }
            return true
        }
        expect(reads == 3 && pauses == 2, "Temporary AX failures must recover before success")
        checks += 1

        reads = 0
        try service.waitFor(pause: {}) {
            reads += 1
            return reads == 3
        }
        expect(reads == 3, "Unconfirmed state must be checked again")
        checks += 1

        reads = 0
        pauses = 0
        do {
            try service.waitFor(pause: { pauses += 1 }) {
                reads += 1
                throw ProbeError.permissionRequired
            }
            fatalError("Permission failure cannot become success")
        } catch ProbeError.permissionRequired {
            expect(reads == 1 && pauses == 0, "Permission failures must not retry")
        }
        checks += 1

        reads = 0
        do {
            try service.waitFor(pause: {}) {
                reads += 1
                throw ProbeError.accessibility("AXIdentifier", AXError.attributeUnsupported.rawValue)
            }
            fatalError("Unsupported attribute cannot become success")
        } catch ProbeError.accessibility(_, let code) {
            expect(reads == 1 && code == AXError.attributeUnsupported.rawValue, "Permanent AX failures must preserve the error")
        }
        checks += 1

        reads = 0
        pauses = 0
        do {
            try service.waitFor(pause: { pauses += 1 }) {
                reads += 1
                throw ProbeError.accessibility("AXIdentifier", AXError.cannotComplete.rawValue)
            }
            fatalError("Persistent AX failure cannot become success")
        } catch ProbeError.accessibility(_, let code) {
            expect(reads == 10 && pauses == 9 && code == AXError.cannotComplete.rawValue, "AX retries must terminate and preserve the failure")
        }
        checks += 1

        reads = 0
        pauses = 0
        do {
            try service.waitFor(pause: { pauses += 1 }) {
                reads += 1
                return false
            }
            fatalError("Unconfirmed state cannot become success")
        } catch ProbeError.stateNotConfirmed {
            expect(reads == 10 && pauses == 9, "State confirmation must terminate without claiming success")
        }
        checks += 1

        do {
            try service.waitFor(context: "应用已解除隐藏", pause: {}) { false }
            fatalError("A contextual failure cannot become success")
        } catch ProbeError.stateNotConfirmedAt(let state) {
            expect(state == "应用已解除隐藏", "Confirmation failure must identify the unresolved state")
        }
        checks += 1
        print("Window probe confirmation: \(checks) passed, 0 failed")
    }
}
