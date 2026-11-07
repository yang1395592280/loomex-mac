struct DockObservationToken: Equatable {
    let generation: Int
    let dockPID: Int32
}

// Owned on the main thread. A queued callback must keep the token from its original tap.
struct DockObservationSession {
    private var generation = 0
    private(set) var current: DockObservationToken?

    init() {}

    mutating func begin(dockPID: Int32) -> DockObservationToken {
        generation += 1
        let token = DockObservationToken(generation: generation, dockPID: dockPID)
        current = token
        return token
    }

    mutating func end() { current = nil }

    func accepts(_ token: DockObservationToken) -> Bool { current == token }

    func permits(_ token: DockObservationToken, dockPID: Int32?) -> Bool {
        accepts(token) && dockPID == token.dockPID
    }
}
