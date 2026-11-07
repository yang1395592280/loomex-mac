import Foundation

@main
struct PreviewCaptureStateTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            checks += 1
        }
        var state = PreviewCaptureState()
        expect(state.begin(authorized: true, supported: true, targetAvailable: true) == nil, "Hidden panels cannot capture")
        state.show()
        expect(state.begin(authorized: false, supported: true, targetAvailable: true) == nil, "Denied permission never starts discovery")
        expect(state.begin(authorized: true, supported: false, targetAvailable: true) == nil, "Unsupported systems retain icons")
        expect(state.begin(authorized: true, supported: true, targetAvailable: false) == nil, "Missing targets cannot capture")
        let first = state.begin(authorized: true, supported: true, targetAvailable: true)!
        expect(state.begin(authorized: true, supported: true, targetAvailable: true) == nil, "At most one physical request is admitted")
        expect(state.finish(first, bytes: 1024), "Current visible frame is accepted")
        expect(state.cachedBytes == 1024 && state.inFlight == nil, "Accepted frame is accounted for")
        expect(!state.finish(first, bytes: 1024), "Duplicate callback is rejected")
        state.hide()
        expect(state.cachedBytes == 0, "Hiding releases the cached frame")

        state.show()
        let cancelled = state.begin(authorized: true, supported: true, targetAvailable: true)!
        state.hide()
        state.show()
        expect(state.inFlight == cancelled, "Hiding cannot cancel the underlying OS operation")
        expect(state.begin(authorized: true, supported: true, targetAvailable: true) == nil, "Reopening cannot accumulate outstanding work")
        expect(!state.finish(cancelled, bytes: 1024), "Late callback from a hidden panel cannot refill its cache")
        let timeout = state.begin(authorized: true, supported: true, targetAvailable: true)!
        expect(state.expire(timeout), "Current request can time out")
        expect(state.inFlight == timeout, "Timeout keeps the physical request slot occupied")
        expect(!state.expire(timeout), "Repeated timeout is inert")
        expect(state.begin(authorized: true, supported: true, targetAvailable: true) == nil, "Timeout cannot create an unbounded retry queue")
        expect(!state.finish(timeout, bytes: 1024), "A timed-out result is discarded")
        let fresh = state.begin(authorized: true, supported: true, targetAvailable: true)!
        expect(!state.finish(timeout, bytes: 1024) && state.inFlight == fresh, "Old callback cannot release a new request")
        expect(!state.finish(fresh, bytes: PreviewCaptureState.byteLimit + 1), "Oversized frame is rejected")
        let empty = state.begin(authorized: true, supported: true, targetAvailable: true)!
        expect(!state.finish(empty, bytes: 0), "Failed capture cannot appear as a preview")
        let exact = state.begin(authorized: true, supported: true, targetAvailable: true)!
        expect(state.finish(exact, bytes: PreviewCaptureState.byteLimit), "Exact byte limit is accepted")
        state.clearFrame()
        expect(state.cachedBytes == 0, "A denied refresh must not leave old frame accounting")
        state.hide()
        var released = true
        for _ in 0..<50 {
            state.show()
            let token = state.begin(authorized: true, supported: true, targetAvailable: true)!
            released = released && state.finish(token, bytes: 4096)
            state.hide()
            released = released && state.cachedBytes == 0 && state.inFlight == nil
        }
        expect(released, "Fifty show/capture/hide cycles retain no frame or completed request")

        expect(PreviewPixelSize.fitting(width: 1280, height: 800) == PreviewPixelSize(width: 640, height: 400), "Large images scale to bounded pixels")
        expect(PreviewPixelSize.fitting(width: 320, height: 100) == PreviewPixelSize(width: 320, height: 100), "Small windows are not enlarged")
        expect(PreviewPixelSize.fitting(width: 100, height: 1600) == PreviewPixelSize(width: 25, height: 400), "Portrait aspect ratio is retained")
        for invalid in [0.0, -1, Double.infinity, Double.nan] {
            expect(PreviewPixelSize.fitting(width: invalid, height: 100) == nil, "Invalid dimensions are refused")
        }
        print("Preview capture state: \(checks) passed, 0 failed")
    }
}
