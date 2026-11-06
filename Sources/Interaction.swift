import Foundation

enum PageAnimationStyle: String, Codable, CaseIterable {
    case classic, smooth, quick

    var title: String {
        switch self {
        case .classic: return "经典（接近旧版）"
        case .smooth: return "柔和"
        case .quick: return "快速"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .classic: return 0.26
        case .smooth: return 0.38
        case .quick: return 0.16
        }
    }

    var controlPoints: (Float, Float, Float, Float) {
        switch self {
        case .classic: return (0.20, 0.70, 0.25, 1)
        case .smooth: return (0.22, 0.61, 0.36, 1)
        case .quick: return (0.12, 0.80, 0.30, 1)
        }
    }
}

struct PageMotionPreferences: Codable {
    var style: PageAnimationStyle = .classic
    var followSystemReduceMotion = false

    init(style: PageAnimationStyle = .classic, followSystemReduceMotion: Bool = false) {
        self.style = style
        self.followSystemReduceMotion = followSystemReduceMotion
    }

    private enum CodingKeys: String, CodingKey { case style, followSystemReduceMotion }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(PageAnimationStyle.self, forKey: .style) ?? .classic
        followSystemReduceMotion = try values.decodeIfPresent(Bool.self, forKey: .followSystemReduceMotion) ?? false
    }

    func animationDuration(systemReduceMotion: Bool) -> TimeInterval {
        followSystemReduceMotion && systemReduceMotion ? 0 : style.duration
    }

    static func load(from url: URL) -> Self {
        guard let data = try? Data(contentsOf: url),
              let preferences = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return preferences
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

struct BackgroundPageGesture {
    enum Axis { case undecided, horizontal, vertical }
    let start: CGPoint
    private(set) var current: CGPoint
    private(set) var maximumDistance: CGFloat = 0
    private(set) var axis: Axis = .undecided

    init(start: CGPoint) {
        self.start = start
        current = start
    }

    mutating func update(to point: CGPoint) {
        current = point
        let dx = point.x - start.x
        let dy = point.y - start.y
        maximumDistance = max(maximumDistance, hypot(dx, dy))
        if axis == .undecided && max(abs(dx), abs(dy)) >= 8 {
            if abs(dx) > abs(dy) * 1.25 { axis = .horizontal }
            else if abs(dy) > abs(dx) * 1.25 { axis = .vertical }
        }
    }

    var isClick: Bool { maximumDistance <= 5 }
    var horizontalOffset: CGFloat { axis == .horizontal ? current.x - start.x : 0 }

    func destinationPage(from page: Int, count: Int, width: CGFloat) -> Int {
        let threshold = min(120, max(50, width * 0.1))
        guard axis == .horizontal, abs(horizontalOffset) >= threshold, count > 0 else { return page }
        return min(max(page + (horizontalOffset < 0 ? 1 : -1), 0), count - 1)
    }
}

struct TilePointerGesture {
    static let dragThreshold: CGFloat = 10

    let start: CGPoint
    private(set) var current: CGPoint
    private(set) var maximumDistance: CGFloat = 0
    private(set) var didStartDrag = false

    init(start: CGPoint) {
        self.start = start
        current = start
    }

    mutating func update(to point: CGPoint) {
        current = point
        maximumDistance = max(maximumDistance, hypot(point.x - start.x, point.y - start.y))
    }

    mutating func beginDragIfNeeded(allowsDrag: Bool) -> Bool {
        guard allowsDrag, !didStartDrag, maximumDistance >= Self.dragThreshold else { return false }
        didStartDrag = true
        return true
    }

    func shouldActivate(at point: CGPoint, bounds: CGRect, allowsDrag: Bool) -> Bool {
        guard !didStartDrag, bounds.contains(point) else { return false }
        return !allowsDrag || maximumDistance < Self.dragThreshold
    }
}

enum LauncherPointerRegions {
    static func bottomStripHeight(screenFrame: CGRect, visibleFrame: CGRect) -> CGFloat {
        min(160, max(48, visibleFrame.minY - screenFrame.minY))
    }

    static func isInBottomStrip(_ point: CGPoint, size: CGSize, height: CGFloat) -> Bool {
        point.x >= 0 && point.x < size.width && point.y >= size.height - height && point.y < size.height
    }

    static func shouldDismiss(_ gesture: BackgroundPageGesture, size: CGSize, height: CGFloat) -> Bool {
        gesture.isClick && isInBottomStrip(gesture.start, size: size, height: height)
            && isInBottomStrip(gesture.current, size: size, height: height)
    }

    static func shouldDismissBackground(_ gesture: BackgroundPageGesture, size: CGSize,
                                        itemCount: Int, lastRowBottom: CGFloat) -> Bool {
        let bounds = CGRect(origin: .zero, size: size)
        guard gesture.isClick, bounds.contains(gesture.start), bounds.contains(gesture.current) else { return false }
        // A full grid keeps its main drag area; a sparse page exposes all unused space.
        return itemCount < 35 || (gesture.start.y > lastRowBottom && gesture.current.y > lastRowBottom)
    }

}
