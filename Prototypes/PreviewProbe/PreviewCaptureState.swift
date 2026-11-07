import Foundation

struct PreviewPixelSize: Equatable {
    let width: Int
    let height: Int

    static func fitting(width: Double, height: Double) -> PreviewPixelSize? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let scale = min(1, 640 / width, 400 / height)
        return PreviewPixelSize(width: max(1, Int((width * scale).rounded(.down))),
                                height: max(1, Int((height * scale).rounded(.down))))
    }
}

// Main-thread state. Logical cancellation never claims to cancel an outstanding OS call.
struct PreviewCaptureState {
    static let byteLimit = 2 * 1024 * 1024
    private var generation = 0
    private(set) var visible = false
    private(set) var inFlight: Int?
    private(set) var cachedBytes = 0

    init() {}

    mutating func show() {
        generation += 1
        visible = true
        cachedBytes = 0
    }

    mutating func hide() {
        generation += 1
        visible = false
        cachedBytes = 0
    }

    mutating func begin(authorized: Bool, supported: Bool, targetAvailable: Bool) -> Int? {
        guard visible, authorized, supported, targetAvailable, inFlight == nil else { return nil }
        generation += 1
        cachedBytes = 0
        inFlight = generation
        return generation
    }

    func accepts(_ token: Int) -> Bool { visible && generation == token && inFlight == token }

    mutating func clearFrame() { cachedBytes = 0 }

    mutating func expire(_ token: Int) -> Bool {
        guard accepts(token) else { return false }
        generation += 1
        cachedBytes = 0
        return true
    }

    mutating func finish(_ token: Int, bytes: Int) -> Bool {
        guard inFlight == token else { return false }
        let accepted = accepts(token) && bytes > 0 && bytes <= Self.byteLimit
        inFlight = nil
        if accepted { cachedBytes = bytes }
        return accepted
    }
}
