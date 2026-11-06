import AppKit
import CoreImage
import ImageIO
import QuartzCore

let launchItemPasteboardType = NSPasteboard.PasteboardType("local.classiclaunchpad.item")

final class LaunchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class MenuBarCoverWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class MenuBarCoverView: LayerContainerView {
    weak var canvas: LaunchCanvas?
    private let background = CALayer()
    private let tint = CALayer()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        background.contentsGravity = .resizeAspectFill
        layer?.addSublayer(background)
        layer?.addSublayer(tint)
        tint.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(wallpaper: WallpaperView, screenSize: NSSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = NSRect(origin: .zero, size: screenSize)
        background.contents = wallpaper.layer?.contents
        background.isHidden = wallpaper.isHidden
        tint.frame = bounds
        CATransaction.commit()
    }

    func releaseContents() { background.contents = nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func forward(_ event: NSEvent) {
        guard let canvas = canvas, let target = canvas.window, let source = window else { return }
        let point = target.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow))
        guard let forwarded = NSEvent.mouseEvent(with: event.type, location: point, modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp, windowNumber: target.windowNumber, context: nil,
                    eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) else { return }
        switch event.type {
        case .leftMouseDown: canvas.mouseDown(with: forwarded)
        case .leftMouseDragged: canvas.mouseDragged(with: forwarded)
        case .leftMouseUp: canvas.mouseUp(with: forwarded)
        case .rightMouseDown: canvas.rightMouseDown(with: forwarded)
        default: break
        }
    }
    override func mouseDown(with event: NSEvent) { forward(event) }
    override func mouseDragged(with event: NSEvent) { forward(event) }
    override func mouseUp(with event: NSEvent) { forward(event) }
    override func rightMouseDown(with event: NSEvent) { forward(event) }
    override func scrollWheel(with event: NSEvent) { canvas?.scrollWheel(with: event) }
    override func swipe(with event: NSEvent) { canvas?.swipe(with: event) }
}

final class IconCache {
    private var images: [String: NSImage] = [:]
    func image(for item: LaunchItem) -> NSImage {
        guard let path = item.path else { return NSImage() }
        if let image = images[path] { return image }
        // Keep only the largest size the grid can display, rather than every source representation.
        let source: NSImage
        if let bundle = Bundle(path: path), bundle.bundleIdentifier?.hasPrefix("com.apple.") != true,
           let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = bundle.url(forResource: name, withExtension: nil) ?? bundle.url(forResource: name, withExtension: "icns"),
           let original = NSImage(contentsOf: url) {
            // Preserve legacy third-party artwork. Apple's modern resources need Icon Services'
            // masking/composition, so drawing those raw can expose square texture backgrounds.
            source = original
        } else { source = NSWorkspace.shared.icon(forFile: path) }
        source.size = NSSize(width: 128, height: 128)
        // Proposed bounds are in image points; pixel dimensions belong to the output context.
        var sourceRect = NSRect(origin: .zero, size: source.size)
        guard let pixels = source.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return source
        }
        // Rasterize in pixel coordinates, independent of the current view's graphics context.
        context.interpolationQuality = .high
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let rendered = context.makeImage() else { return source }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        bitmap.size = NSSize(width: 128, height: 128)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        images[path] = image
        return image
    }

    var count: Int { images.count }
    func removeAll() { images.removeAll() }
}

class LayerContainerView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { }
}

final class LaunchTile: NSButton, NSDraggingSource {
    let item: LaunchItem
    let icons: IconCache
    var iconSide: CGFloat = 68
    var highlightedForDrop = false { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var activateItem: ((LaunchItem) -> Void)?
    var showItemMenu: ((LaunchItem, NSEvent) -> Void)?
    var dragDidEnd: (() -> Void)?
    var allowsDrag = true
    private var pointerGesture: TilePointerGesture?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(item: LaunchItem, icons: IconCache) {
        self.item = item
        self.icons = icons
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isBordered = false
        title = item.name
        toolTip = item.name
        focusRingType = .none
        target = self
        action = #selector(pressed)
        setAccessibilityLabel(item.name)
        setAccessibilityHelp(item.kind == .folder ? "打开文件夹" : "打开应用程序")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var iconRect: NSRect {
        NSRect(x: (bounds.width - iconSide) / 2, y: 5, width: iconSide, height: iconSide)
    }

    private var labelFont: NSFont { .systemFont(ofSize: iconSide >= 64 ? 13 : 12) }

    var folderPreviewRect: NSRect { iconRect.insetBy(dx: iconSide * 0.09375, dy: iconSide * 0.09375) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let font = labelFont
        let labelWidth = min(bounds.width - 4, (item.name as NSString).size(withAttributes: [.font: font]).width + 16)
        let label = NSRect(x: (bounds.width - labelWidth) / 2, y: iconRect.maxY + 1, width: labelWidth, height: 24)
        guard iconRect.insetBy(dx: -9, dy: -5).contains(local) || label.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        MotionTrace.shared.draw()
        if selected || highlightedForDrop {
            NSColor.white.withAlphaComponent(highlightedForDrop ? 0.28 : 0.13).setFill()
            NSBezierPath(roundedRect: iconRect.insetBy(dx: -9, dy: -9), xRadius: 18, yRadius: 18).fill()
        }
        if item.kind == .app {
            // The source icon already includes its own edge treatment; extra shadows soften it.
            icons.image(for: item).draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            // App icon canvases include transparent padding. Match the folder's visible outline to them.
            let preview = folderPreviewRect
            NSColor(calibratedWhite: 0.76, alpha: 0.72).setFill()
            NSBezierPath(roundedRect: preview, xRadius: preview.width * 0.21, yRadius: preview.height * 0.21).fill()
            let gap = preview.width * 0.0475
            let side = preview.width * 0.27
            for (index, child) in item.children.prefix(9).enumerated() {
                let rect = NSRect(x: preview.minX + gap + CGFloat(index % 3) * (side + gap),
                                  y: preview.minY + gap + CGFloat(index / 3) * (side + gap),
                                  width: side, height: side)
                icons.image(for: child).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        (item.name as NSString).draw(in: NSRect(x: 2, y: iconRect.maxY + 3, width: bounds.width - 4, height: 24),
                                     withAttributes: [.font: labelFont, .foregroundColor: NSColor.white,
                                                      .paragraphStyle: paragraph, .shadow: shadow])
    }

    @objc private func pressed() { activateItem?(item) }

    override func mouseDown(with event: NSEvent) {
        pointerGesture = TilePointerGesture(start: convert(event.locationInWindow, from: nil))
        pointerTrace("down")
    }

    override func mouseDragged(with event: NSEvent) {
        guard var gesture = pointerGesture else { return }
        gesture.update(to: convert(event.locationInWindow, from: nil))
        guard gesture.beginDragIfNeeded(allowsDrag: allowsDrag) else {
            pointerGesture = gesture
            return
        }
        pointerGesture = nil
        pointerTrace("drag")

        let pasteboard = NSPasteboardItem()
        pasteboard.setString(item.id, forType: launchItemPasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter: pasteboard)
        let image = NSImage(size: NSSize(width: iconSide, height: iconSide), flipped: true) { [icons, item] rect in
            icons.image(for: item).draw(in: rect, from: .zero, operation: .sourceOver,
                                       fraction: 0.88, respectFlipped: true, hints: nil)
            return true
        }
        let preview = item.kind == .app ? image : NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!
        dragging.setDraggingFrame(iconRect, contents: preview)
        beginDraggingSession(with: [dragging], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        guard var gesture = pointerGesture else { return }
        gesture.update(to: convert(event.locationInWindow, from: nil))
        pointerGesture = nil
        guard gesture.shouldActivate(at: gesture.current, bounds: bounds, allowsDrag: allowsDrag) else {
            pointerTrace("release-ignored")
            return
        }
        pointerTrace("activate")
        pressed()
    }

    private func pointerTrace(_ action: String) {
        guard ProcessInfo.processInfo.environment["CLASSIC_LAUNCHPAD_UI_TRACE"] == "1" else { return }
        fputs("UI_TRACE tile=\(action) name=\(item.name)\n", stderr)
    }

    override func rightMouseDown(with event: NSEvent) { showItemMenu?(item, event) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        pointerGesture = nil
        dragDidEnd?()
    }
}

final class ClassicSearchField: NSSearchField {
    var centeredPlaceholderRects: (icon: NSRect, text: NSRect) {
        let font = self.font ?? NSFont.systemFont(ofSize: 13)
        let size = ((placeholderString ?? "搜索") as NSString).size(withAttributes: [.font: font])
        let width = 14 + 5 + size.width
        let left = bounds.midX - width / 2
        return (NSRect(x: left, y: bounds.midY - 7, width: 14, height: 14),
                NSRect(x: left + 19, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.035).setFill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        border.lineWidth = 1
        border.stroke()
        // Keep AppKit's original search cell and field editor for IME, selection and cancel behavior.
        guard stringValue.isEmpty, currentEditor() == nil else { super.draw(dirtyRect); return }
        let rects = centeredPlaceholderRects
        let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white.withAlphaComponent(0.65)]))
        symbol?.draw(in: rects.icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ((placeholderString ?? "搜索") as NSString).draw(in: rects.text,
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.45)])
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        needsDisplay = true
    }
}

final class PageDots: NSView {
    var count = 1 { didSet { needsDisplay = true } }
    var current = 0 { didSet { needsDisplay = true } }
    var choosePage: ((Int) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard count > 1 else { return }
        let start = (bounds.width - CGFloat(count) * 20) / 2
        for index in 0..<count {
            (index == current ? NSColor.white : NSColor.white.withAlphaComponent(0.35)).setFill()
            NSBezierPath(ovalIn: NSRect(x: start + CGFloat(index) * 20 + 6, y: 10, width: 7, height: 7)).fill()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let start = (bounds.width - CGFloat(count) * 20) / 2
        guard count > 1, NSRect(x: start, y: 4, width: CGFloat(count) * 20, height: 22).contains(local) else { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let start = (bounds.width - CGFloat(count) * 20) / 2
        let page = Int(floor((point.x - start) / 20))
        if (0..<count).contains(page) { choosePage?(page) }
    }
}

final class CanvasDecoration: LayerContainerView {
    private let panel = CALayer()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(panel)
        panel.cornerRadius = 27
        panel.borderWidth = 1
        panel.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        panel.backgroundColor = NSColor(calibratedWhite: 0.37, alpha: 0.72).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(folderPanel: NSRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Compositing a solid tint needs no screen-sized RGBA backing bitmap.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(folderPanel == nil ? 0.12 : 0.4368).cgColor
        panel.isHidden = folderPanel == nil
        if let frame = folderPanel { panel.frame = frame }
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class BackgroundEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CanvasStatusLabel: NSTextField {
    // Status text may overlap the grid but must never intercept icon or background gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PageContentView: LayerContainerView {
    var tiles: [LaunchTile] = []
    var acceptsInput = true
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsInput, let hit = super.hitTest(point), hit !== self else { return nil }
        return hit
    }
}

final class WallpaperView: LayerContainerView {
    private var image: CGImage?
    private var imageURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(for screen: NSScreen) -> Bool {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return false }
        return update(from: url)
    }

    func update(from url: URL) -> Bool {
        if url == imageURL && image != nil { return true }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 1600,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        let original = CIImage(cgImage: bitmap)
        let blurred = original.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let rendered = context.createCGImage(blurred, from: original.extent) else { return false }
        image = rendered
        imageURL = url
        layer?.contents = rendered
        context.clearCaches()
        return true
    }

    var cachedPixelSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    func releaseContents() {
        layer?.contents = nil
        image = nil
        imageURL = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class LaunchCanvas: LayerContainerView, NSSearchFieldDelegate, NSTextFieldDelegate {
    let store: LayoutStore
    let icons = IconCache()
    let backdrop = BackgroundEffectView()
    let wallpaper = WallpaperView(frame: .zero)
    let decoration = CanvasDecoration(frame: .zero)
    let search = ClassicSearchField()
    let dots = PageDots()
    let folderName = NSTextField()
    let emptyLabel = CanvasStatusLabel(labelWithString: "")
    private var pageContent = PageContentView(frame: .zero)
    private var cachedPages: [Int: PageContentView] = [:]
    private var adjacentPages: [(view: PageContentView, direction: Int)] = []
    private var trackingBackground = false
    private var animatingPage = false
    private var pageMotionGeneration = 0
    private var bottomDismissHeight: CGFloat = 64
    private var backgroundGesture: BackgroundPageGesture?
    private var backgroundStartedInBottom = false
    private var desiredPageOffset: CGFloat = 0
    private var appliedPageOffset: CGFloat = 0
    private var displayDriver: AnyObject?
    private var scrollGestureTurned = false
    private var isSorting = false
    private var pendingRefresh = false
    private(set) var resourcesSuspended = false
    private var pageMotionPreferences = PageMotionPreferences()
    private var preferencesURL: URL { store.fileURL.deletingLastPathComponent().appendingPathComponent("preferences.json") }
    var dismiss: (() -> Void)?
    var launch: ((LaunchItem) -> Void)?
    var rescan: (() -> Void)?
    var showAbout: (() -> Void)?
    private var tiles: [LaunchTile] = []
    private(set) var page = 0
    private var folderID: String?
    private var folderPage = 0
    private var selectedIndex: Int?
    private var keyMonitor: Any?
    private var dragEdgeTimer: Timer?
    private var dragEdgeDirection = 0
    private var dropTarget: String?
    private var dropGroups = false
    private var scrollAmount: CGFloat = 0
    private var lastPageChange = Date.distantPast
    private let folderCapacity = 21
    private var menuItemID: String?
    private var isSearching: Bool { !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var currentPageIndex: Int { folder != nil ? folderPage : page }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(store: LayoutStore) {
        self.store = store
        super.init(frame: .zero)
        pageMotionPreferences = PageMotionPreferences.load(from: preferencesURL)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        addSubview(wallpaper)
        addSubview(decoration)
        search.isBordered = false
        search.isEditable = true
        search.isSelectable = true
        search.drawsBackground = false
        search.placeholderString = "搜索"
        search.font = .systemFont(ofSize: 13)
        search.delegate = self
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索应用程序")
        addSubview(search)
        folderName.isBordered = false
        folderName.drawsBackground = false
        folderName.textColor = .white
        folderName.font = .systemFont(ofSize: 27, weight: .light)
        folderName.alignment = .center
        folderName.delegate = self
        folderName.isHidden = true
        folderName.focusRingType = .none
        folderName.setAccessibilityLabel("文件夹名称")
        addSubview(folderName)
        dots.choosePage = { [weak self] page in self?.go(to: page) }
        addSubview(dots)
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        emptyLabel.font = .systemFont(ofSize: 17)
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
        registerForDraggedTypes([launchItemPasteboardType])
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isVisible == true, NSApp.isActive else { return event }
            return self.handleKey(event) ? nil : event
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        dragEdgeTimer?.invalidate()
        if #available(macOS 14.0, *) { (displayDriver as? PageDisplayDriver)?.stop() }
    }

    private var folder: LaunchItem? {
        guard let id = folderID else { return nil }
        return store.layout.pages.flatMap { $0 }.first { $0.id == id && $0.kind == .folder }
    }

    private var folderPanel: NSRect {
        let width = min(bounds.width - 100, 1120)
        let height = min(bounds.height - 220, 460)
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2 + 6, width: width, height: height)
    }

    private func items(onPage index: Int) -> [LaunchItem] {
        if let folder = folder {
            let start = index * folderCapacity
            return Array(folder.children.dropFirst(start).prefix(folderCapacity))
        }
        if isSearching { return Array(store.layout.search(search.stringValue).dropFirst(index * 35).prefix(35)) }
        return store.layout.pages.indices.contains(index) ? store.layout.pages[index] : []
    }

    private var visibleItems: [LaunchItem] { items(onPage: folder != nil ? folderPage : page) }

    private var pageCount: Int {
        if let folder = folder { return max(1, (folder.children.count + folderCapacity - 1) / folderCapacity) }
        if isSearching { return max(1, (store.layout.search(search.stringValue).count + 34) / 35) }
        return store.layout.pages.count
    }

    func resetForOpening() {
        resourcesSuspended = false
        cancelPageMotion()
        search.stringValue = ""
        folderID = nil
        folderPage = 0
        selectedIndex = nil
        page = min(page, max(0, store.layout.pages.count - 1))
        refresh()
        window?.makeFirstResponder(self)
    }

    func updateWallpaper(for screen: NSScreen) {
        bottomDismissHeight = LauncherPointerRegions.bottomStripHeight(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let available = !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency && wallpaper.update(for: screen)
        wallpaper.isHidden = !available
        backdrop.isHidden = available
    }

    func refresh() {
        guard !resourcesSuspended else { pendingRefresh = true; return }
        if trackingBackground || animatingPage { pendingRefresh = true; return }
        pendingRefresh = false
        cancelPageMotion()
        if folderID != nil && folder == nil { folderID = nil; folderPage = 0 }
        if folderID != nil { folderPage = min(folderPage, pageCount - 1) }
        else { page = min(page, pageCount - 1) }
        cachedPages.values.forEach { $0.removeFromSuperview() }
        cachedPages = [:]
        pageContent = makePage(currentPageIndex)
        tiles = pageContent.tiles
        for (index, tile) in tiles.enumerated() { tile.selected = selectedIndex == index }
        search.isHidden = folder != nil
        folderName.isHidden = folder == nil
        if let folder = folder { folderName.stringValue = folder.name }
        dots.count = pageCount
        dots.current = currentPageIndex
        emptyLabel.stringValue = tiles.isEmpty ? (isSearching ? "没有找到匹配的应用程序" : "正在查找应用程序…") : ""
        emptyLabel.isHidden = !tiles.isEmpty
        needsLayout = true
        needsDisplay = true
        decoration.update(folderPanel: folder != nil ? folderPanel : nil)
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func makePage(_ index: Int) -> PageContentView {
        let view = PageContentView(frame: bounds)
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.tiles = items(onPage: index).map { item in
            let tile = LaunchTile(item: item, icons: icons)
            tile.allowsDrag = !isSearching
            tile.activateItem = { [weak self] item in self?.activate(item) }
            tile.showItemMenu = { [weak self] item, event in self?.contextMenu(item: item, event: event) }
            tile.dragDidEnd = { [weak self] in self?.clearDragState() }
            view.addSubview(tile)
            return tile
        }
        cachedPages[index] = view
        addSubview(view, positioned: .above, relativeTo: decoration)
        positionTiles(view.tiles)
        return view
    }

    private func warmAdjacentPages() {
        guard !resourcesSuspended, !trackingBackground, !animatingPage, bounds.width > 0, bounds.height > 0 else { return }
        let current = currentPageIndex
        let required = Set((max(0, current - 1)...min(pageCount - 1, current + 1)))
        for index in Array(cachedPages.keys) where !required.contains(index) {
            cachedPages.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in required where cachedPages[index] == nil {
            let view = makePage(index)
            view.acceptsInput = index == current
            view.tiles.forEach { $0.displayIfNeeded() }
            view.isHidden = index != current
        }
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        wallpaper.frame = bounds
        decoration.frame = bounds
        decoration.update(folderPanel: folder != nil ? folderPanel : nil)
        for view in cachedPages.values {
            view.frame = bounds
            positionTiles(view.tiles)
        }
        search.frame = NSRect(x: (bounds.width - 250) / 2, y: max(24, bounds.height * 50 / 1692), width: 250, height: 26)
        let panel = folderPanel
        folderName.frame = NSRect(x: panel.minX + 40, y: panel.minY - 55, width: panel.width - 80, height: 38)
        let dotY = folder != nil ? panel.maxY + 10 : min(bounds.height * 0.918, bounds.height - bottomDismissHeight - 28) - 13.5
        dots.frame = NSRect(x: (bounds.width - 420) / 2, y: dotY, width: 420, height: 30)
        emptyLabel.frame = NSRect(x: 60, y: bounds.height / 2 - 20, width: bounds.width - 120, height: 32)
        warmAdjacentPages()
    }

    private func positionTiles(_ items: [LaunchTile]) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let panel = folderPanel
        let columns = 7
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let firstCenter: NSPoint
        if folder != nil {
            let grid = panel.insetBy(dx: 26, dy: 24)
            cellWidth = grid.width / CGFloat(columns)
            cellHeight = grid.height / 3
            firstCenter = NSPoint(x: grid.minX + cellWidth / 2, y: grid.minY + cellHeight / 2 - 12)
        } else {
            // Measured from the user's 6016×3384 reference: centers span about 20.2%...79.8%.
            cellWidth = min(bounds.width * 0.0991, bounds.height * 0.18)
            cellHeight = bounds.height * 0.1665
            firstCenter = NSPoint(x: bounds.midX - 3 * cellWidth, y: bounds.height * 0.157)
        }
        let preferredIcon = max(64, min(128, bounds.width / 17))
        let icon = max(38, min(preferredIcon, cellHeight - 35, cellWidth - 35))
        for (index, tile) in items.enumerated() {
            tile.iconSide = icon
            let center = NSPoint(x: firstCenter.x + CGFloat(index % columns) * cellWidth,
                                 y: firstCenter.y + CGFloat(index / columns) * cellHeight)
            tile.frame = NSRect(x: center.x - cellWidth / 2, y: center.y - 5 - icon / 2,
                                width: cellWidth, height: icon + 34)
        }
    }

    func activate(_ item: LaunchItem) {
        if item.kind == .folder {
            folderID = item.id
            folderPage = 0
            selectedIndex = nil
            refresh()
            window?.makeFirstResponder(self)
        } else { launch?(item) }
    }

    func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "未能保存布局"
        alert.informativeText = "原有布局已保留。\n" + error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func change(_ operation: () throws -> Void) {
        do { try operation(); selectedIndex = nil; refresh() }
        catch { report(error) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === search else { return }
        page = 0
        selectedIndex = nil
        refresh()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === folderName, let id = folderID else { return }
        change { try store.renameFolder(id: id, name: folderName.stringValue) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        if animatingPage { return true }
        let editingName = (window?.firstResponder as? NSTextView)?.delegate as? NSTextField === folderName
        if editingName { return false }
        switch event.keyCode {
        case 53:
            if folderID != nil { folderID = nil; selectedIndex = nil; refresh(); window?.makeFirstResponder(self) }
            else if !search.stringValue.isEmpty { search.stringValue = ""; page = 0; selectedIndex = nil; refresh() }
            else { dismiss?() }
            return true
        case 36, 76:
            if let index = selectedIndex, tiles.indices.contains(index) { activate(tiles[index].item) }
            else if isSearching, let first = visibleItems.first { activate(first) }
            return true
        case 123, 124, 125, 126:
            guard !tiles.isEmpty else { return true }
            let old = selectedIndex
            let delta = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? 7 : -7
            if let old = old {
                let next = old + delta
                if next < 0 && delta == -1 { turnPage(-1); selectedIndex = max(0, tiles.count - 1) }
                else if next >= tiles.count && delta == 1 { turnPage(1); selectedIndex = 0 }
                else { selectedIndex = min(max(0, next), tiles.count - 1) }
            } else { selectedIndex = 0 }
            for (index, tile) in tiles.enumerated() { tile.selected = selectedIndex == index }
            return true
        default:
            if window?.firstResponder === self, let text = event.characters, !text.isEmpty,
               !event.modifierFlags.contains(.control), text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                window?.makeFirstResponder(search)
                search.stringValue += text
                page = 0
                refresh()
                search.currentEditor()?.moveToEndOfDocument(nil)
                return true
            }
            return false
        }
    }

    private func go(to newPage: Int, allowExtra: Bool = false) {
        guard !animatingPage, !trackingBackground else { return }
        let limit = pageCount - 1 + (allowExtra && folder == nil && !isSearching ? 1 : 0)
        let next = min(max(newPage, 0), limit)
        guard next != currentPageIndex else { return }
        selectedIndex = nil
        if !allowExtra {
            preparePageMotion(targetPage: next, kind: "navigation-" + pageMotionPreferences.style.rawValue)
            animatePageMotion(to: next)
            return
        }
        if folder != nil { folderPage = next } else { page = next }
        lastPageChange = Date()
        if next == store.layout.pages.count {
            cancelPageMotion()
            cachedPages.values.forEach { $0.removeFromSuperview() }
            cachedPages = [:]
            tiles = []
            dots.count = next + 1; dots.current = next
            emptyLabel.stringValue = "拖放到这里，创建新的一页"
            emptyLabel.isHidden = false
            needsDisplay = true
        } else { refresh() }
    }

    private func turnPage(_ direction: Int) { go(to: currentPageIndex + direction) }

    override func scrollWheel(with event: NSEvent) {
        guard !trackingBackground else { return }
        if event.phase.contains(.began) { scrollAmount = 0; scrollGestureTurned = false }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollAmount = 0
            scrollGestureTurned = false
            return
        }
        // A trackpad's inertial tail must not turn a second page after the physical gesture.
        guard event.momentumPhase.isEmpty, !scrollGestureTurned, !animatingPage else { return }
        let amount = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollAmount += amount
        if abs(scrollAmount) > (event.hasPreciseScrollingDeltas ? 38 : 2) {
            let direction = scrollAmount < 0 ? 1 : -1
            scrollAmount = 0
            scrollGestureTurned = !event.phase.isEmpty
            turnPage(direction)
        }
    }

    override func swipe(with event: NSEvent) {
        if event.deltaX != 0 { turnPage(event.deltaX < 0 ? 1 : -1) }
    }

    override func mouseDown(with event: NSEvent) {
        guard !animatingPage, !isSorting else { return }
        let location = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        backgroundGesture = BackgroundPageGesture(start: location)
        backgroundStartedInBottom = LauncherPointerRegions.isInBottomStrip(location, size: bounds.size, height: bottomDismissHeight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var gesture = backgroundGesture else { return }
        gesture.update(to: convert(event.locationInWindow, from: nil))
        backgroundGesture = gesture
        if !backgroundStartedInBottom && gesture.axis == .horizontal {
            if !trackingBackground { preparePageMotion(kind: "drag-" + pageMotionPreferences.style.rawValue) }
            MotionTrace.shared.event()
            updatePageMotion(offset: gesture.horizontalOffset)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard var gesture = backgroundGesture else { return }
        gesture.update(to: convert(event.locationInWindow, from: nil))
        backgroundGesture = nil
        if trackingBackground {
            updatePageMotion(offset: gesture.horizontalOffset)
            animatePageMotion(to: gesture.destinationPage(from: currentPageIndex, count: pageCount, width: bounds.width))
        } else if LauncherPointerRegions.shouldDismiss(gesture, size: bounds.size, height: bottomDismissHeight) {
            dismiss?()
        } else if gesture.isClick, folder != nil, !folderPanel.contains(gesture.start) {
            folderID = nil; selectedIndex = nil; refresh()
        } else if folder == nil, LauncherPointerRegions.shouldDismissBackground(gesture, size: bounds.size,
                    itemCount: tiles.count, lastRowBottom: tiles.map { $0.frame.maxY }.max() ?? 0) {
            dismiss?()
        }
    }

    private func preparePageMotion(targetPage: Int? = nil, kind: String) {
        warmAdjacentPages()
        MotionTrace.shared.begin(kind: kind, screen: window?.screen)
        trackingBackground = true
        desiredPageOffset = 0
        appliedPageOffset = 0
        pageContent.acceptsInput = false
        let current = currentPageIndex
        let indices = targetPage.map { [$0] } ?? [current - 1, current + 1].filter { (0..<pageCount).contains($0) }
        for index in indices {
            let view = cachedPages[index] ?? makePage(index)
            let direction = index > current ? 1 : -1
            view.isHidden = false
            view.acceptsInput = false
            setOffset(CGFloat(direction) * bounds.width, on: view)
            adjacentPages.append((view, direction))
        }
        if #available(macOS 14.0, *) {
            displayDriver = PageDisplayDriver(view: self) { [weak self] in
                guard let self = self, self.trackingBackground, self.desiredPageOffset != self.appliedPageOffset else { return }
                self.applyPageOffset(self.desiredPageOffset)
            }
        }
    }

    private func setOffset(_ offset: CGFloat, on view: PageContentView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.setAffineTransform(CGAffineTransform(translationX: offset, y: 0))
        CATransaction.commit()
    }

    private func updatePageMotion(offset: CGFloat) {
        let current = currentPageIndex
        let pastEdge = (current == 0 && offset > 0) || (current == pageCount - 1 && offset < 0)
        desiredPageOffset = min(bounds.width, max(-bounds.width, offset)) * (pastEdge ? 0.22 : 1)
        if #available(macOS 14.0, *) { } else { applyPageOffset(desiredPageOffset) }
    }

    private func applyPageOffset(_ offset: CGFloat) {
        appliedPageOffset = offset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageContent.layer?.setAffineTransform(CGAffineTransform(translationX: offset, y: 0))
        for adjacent in adjacentPages {
            adjacent.view.layer?.setAffineTransform(CGAffineTransform(translationX: CGFloat(adjacent.direction) * bounds.width + offset, y: 0))
        }
        CATransaction.commit()
    }

    private func animatePageMotion(to next: Int) {
        let current = currentPageIndex
        let direction = next == current ? 0 : next > current ? -1 : 1
        let offset = CGFloat(direction) * bounds.width
        if folder != nil { folderPage = next } else { page = next }
        dots.current = next
        trackingBackground = false
        animatingPage = true
        lastPageChange = Date()
        let generation = pageMotionGeneration
        let style = pageMotionPreferences.style
        let duration = pageMotionPreferences.animationDuration(systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard duration > 0 else { completePageMotion(to: next); return }
        let curve = style.controlPoints
        let timing = CAMediaTimingFunction(controlPoints: curve.0, curve.1, curve.2, curve.3)
        let layers = [(pageContent, CGFloat(0))] + adjacentPages.map { ($0.view, CGFloat($0.direction) * bounds.width) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, self.pageMotionGeneration == generation else { return }
            self.completePageMotion(to: next)
        }
        for (view, base) in layers {
            guard let layer = view.layer else { continue }
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = layer.presentation()?.affineTransform().tx ?? layer.affineTransform().tx
            animation.toValue = base + offset
            animation.duration = duration
            animation.timingFunction = timing
            layer.setAffineTransform(CGAffineTransform(translationX: base + offset, y: 0))
            layer.add(animation, forKey: "pageSlide")
        }
        CATransaction.commit()
    }

    private func completePageMotion(to next: Int) {
        if let view = cachedPages[next] { pageContent = view; tiles = view.tiles }
        for view in cachedPages.values {
            view.isHidden = view !== pageContent
            view.acceptsInput = view === pageContent
            setOffset(0, on: view)
        }
        for (index, tile) in tiles.enumerated() where tile.selected != (selectedIndex == index) {
            tile.selected = selectedIndex == index
        }
        adjacentPages = []
        trackingBackground = false
        animatingPage = false
        stopDisplayDriver()
        MotionTrace.shared.finish()
        NSAccessibility.post(element: self, notification: .layoutChanged)
        if pendingRefresh { refresh(); return }
        let generation = pageMotionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.pageMotionGeneration == generation else { return }
            self.warmAdjacentPages()
        }
    }

    private func stopDisplayDriver() {
        if #available(macOS 14.0, *) { (displayDriver as? PageDisplayDriver)?.stop() }
        displayDriver = nil
    }

    func suspendResources() {
        guard !resourcesSuspended else { return }
        resourcesSuspended = true
        cancelPageMotion()
        clearDragState()
        cachedPages.values.forEach { $0.removeFromSuperview() }
        cachedPages.removeAll()
        tiles.removeAll()
        pageContent = PageContentView(frame: .zero)
        icons.removeAll()
        wallpaper.releaseContents()
    }

    private func cancelPageMotion() {
        pageMotionGeneration += 1
        backgroundGesture = nil
        trackingBackground = false
        animatingPage = false
        stopDisplayDriver()
        MotionTrace.shared.finish()
        adjacentPages = []
        if let current = cachedPages[currentPageIndex] { pageContent = current; tiles = current.tiles }
        for view in cachedPages.values {
            view.layer?.removeAllAnimations()
            setOffset(0, on: view)
            view.isHidden = view !== pageContent
            view.acceptsInput = view === pageContent
        }
    }

    private func optionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "重新扫描应用程序", action: #selector(scanAction), keyEquivalent: "")
        let effects = NSMenu(title: "翻页手感")
        for style in PageAnimationStyle.allCases {
            let item = effects.addItem(withTitle: style.title, action: #selector(changePageAnimation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == pageMotionPreferences.style ? .on : .off
        }
        effects.addItem(.separator())
        let reduceMotion = effects.addItem(withTitle: "跟随系统“减弱动态效果”", action: #selector(toggleSystemReduceMotion), keyEquivalent: "")
        reduceMotion.target = self
        reduceMotion.state = pageMotionPreferences.followSystemReduceMotion ? .on : .off
        let effectsItem = menu.addItem(withTitle: "翻页手感", action: nil, keyEquivalent: "")
        effectsItem.submenu = effects
        let sorting = NSMenu(title: folder == nil ? "排序全部页面" : "排序当前文件夹")
        sorting.autoenablesItems = false
        for mode in AppSortMode.allCases {
            let item = sorting.addItem(withTitle: mode.title, action: #selector(sortAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.isEnabled = !isSearching && !isSorting && !animatingPage && !trackingBackground
        }
        sorting.addItem(.separator())
        let undo = sorting.addItem(withTitle: "撤销上次排序", action: #selector(undoSortAction), keyEquivalent: "")
        undo.target = self
        undo.isEnabled = store.canUndoSort && !isSorting && !animatingPage && !trackingBackground
        let sortingItem = menu.addItem(withTitle: sorting.title, action: nil, keyEquivalent: "")
        sortingItem.submenu = sorting
        menu.addItem(withTitle: "使用说明", action: #selector(helpAction), keyEquivalent: "")
        menu.addItem(withTitle: "关于经典启动台", action: #selector(aboutAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出经典启动台", action: #selector(quitAction), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc func showOptions() {
        optionsMenu().popUp(positioning: nil, at: NSPoint(x: search.frame.maxX, y: search.frame.maxY + 8), in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(optionsMenu(), with: event, for: self)
    }

    @objc private func scanAction() { rescan?() }
    @objc private func aboutAction() { showAbout?() }
    @objc private func quitAction() { NSApp.terminate(nil) }
    @objc private func sortAction(_ sender: NSMenuItem) {
        guard !isSorting, !isSearching, !animatingPage,
              let value = sender.representedObject as? String, let mode = AppSortMode(rawValue: value) else { return }
        isSorting = true
        let apps = store.layout.apps
        let scope = folderID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let metadata = AppSortMetadata.read(apps: apps)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSorting = false
                guard self.folderID == scope, !self.isSearching else { return }
                self.change {
                    try self.store.sort(by: mode, folderID: scope, metadata: metadata)
                    self.page = 0; self.folderPage = 0
                }
            }
        }
    }
    @objc private func undoSortAction() {
        guard !isSorting, !animatingPage else { return }
        change { try store.undoLastSort(); page = 0; folderPage = 0 }
    }
    @objc private func changePageAnimation(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let style = PageAnimationStyle(rawValue: value) else { return }
        var preferences = pageMotionPreferences
        preferences.style = style
        saveMotionPreferences(preferences)
    }
    @objc private func toggleSystemReduceMotion() {
        var preferences = pageMotionPreferences
        preferences.followSystemReduceMotion.toggle()
        saveMotionPreferences(preferences)
    }
    private func saveMotionPreferences(_ preferences: PageMotionPreferences) {
        do {
            try preferences.save(to: preferencesURL)
            pageMotionPreferences = preferences
        } catch { report(error) }
    }
    @objc private func helpAction() {
        let alert = NSAlert()
        alert.messageText = "经典启动台"
        alert.informativeText = "单击图标打开应用；滚轮、圆点、空白处左键拖动均使用所选翻页手感。\n空白处右键 → “翻页手感”可选经典、柔和或快速。\n“排序全部页面”提供名称、添加/创建/修改时间的正序和倒序；文件夹内只排序当前文件夹。\n排序保留文件夹分组，可撤销上次排序；继续手动整理后不再撤销旧排序。\n添加时间来自应用文件元数据，缺失时采用创建时间；文件夹按成员中最新时间排序。\n满页时单击最后一排图标下方空白收起；未满页时单击任意空白收起。\n拖到图标中央建立文件夹；拖到图标两侧调整顺序。\n拖到屏幕左右边缘可跨页移动。\n文件夹内拖到面板外即可移出；点击文件夹名称可重命名。\n直接键入即可搜索；按 Esc 返回或收起。\n满页主区域空白点击保持显示，文件夹外点击只关闭文件夹。\n将本程序保留在程序坞，以后点击图标即可打开。"
        alert.runModal()
    }

    private func contextMenu(item: LaunchItem, event: NSEvent) {
        menuItemID = item.id
        let menu = NSMenu()
        menu.addItem(withTitle: "打开", action: #selector(openMenuItem), keyEquivalent: "")
        if item.kind == .folder {
            menu.addItem(withTitle: "重命名文件夹", action: #selector(renameMenuFolder), keyEquivalent: "")
            menu.addItem(withTitle: "解散文件夹", action: #selector(ungroupMenuFolder), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "在访达中显示", action: #selector(revealMenuItem), keyEquivalent: "")
            if folderID != nil { menu.addItem(withTitle: "移出文件夹", action: #selector(moveMenuItemOut), keyEquivalent: "") }
        }
        menu.items.forEach { $0.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openMenuItem() { if let id = menuItemID, let item = store.layout.item(id: id) { activate(item) } }
    @objc private func revealMenuItem() {
        guard let id = menuItemID, let path = store.layout.item(id: id)?.path else { return }
        dismiss?()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    @objc private func renameMenuFolder() {
        guard let id = menuItemID, let item = store.layout.item(id: id) else { return }
        activate(item)
        window?.makeFirstResponder(folderName)
        folderName.selectText(nil)
    }
    @objc private func ungroupMenuFolder() {
        guard let id = menuItemID else { return }
        folderID = nil
        change { try store.ungroup(id: id) }
    }
    @objc private func moveMenuItemOut() {
        guard let id = menuItemID else { return }
        change { try store.move(id: id, toPage: page, before: nil) }
    }

    private func dragID(_ info: NSDraggingInfo) -> String? {
        guard !isSearching, info.draggingSource is LaunchTile,
              let id = info.draggingPasteboard.string(forType: launchItemPasteboardType),
              store.layout.item(id: id) != nil else { return nil }
        return id
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let sourceID = dragID(sender) else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let target = tiles.first { $0.frame.contains(point) && $0.item.id != sourceID }
        dropTarget = target?.item.id
        dropGroups = false
        if let target = target, folder == nil {
            let local = target.convert(point, from: self)
            dropGroups = target.iconRect.insetBy(dx: 6, dy: 0).contains(local) && store.layout.item(id: sourceID)?.kind == .app
        }
        tiles.forEach { $0.highlightedForDrop = dropGroups && $0.item.id == dropTarget }
        let direction = point.x < 34 ? -1 : point.x > bounds.width - 34 ? 1 : 0
        if direction != dragEdgeDirection {
            dragEdgeTimer?.invalidate()
            dragEdgeDirection = direction
            if direction != 0 {
                let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.go(to: (self.folder != nil ? self.folderPage : self.page) + direction, allowExtra: true)
                }
                // Drag sessions track events in a separate run-loop mode; keep edge paging active there.
                RunLoop.main.add(timer, forMode: .common)
                dragEdgeTimer = timer
            }
        }
        return .move
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dragID(sender) != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = dragID(sender) else { return false }
        _ = draggingUpdated(sender)
        let point = convert(sender.draggingLocation, from: nil)
        let target = dropTarget
        let grouping = dropGroups
        dragEdgeTimer?.invalidate()
        do {
            if let folder = folder {
                if folderPanel.contains(point) {
                    try store.moveIntoFolder(id: id, folderID: folder.id, before: target)
                } else {
                    try store.move(id: id, toPage: page, before: nil)
                    folderID = nil
                }
            } else if grouping, let target = target {
                try store.group(id: id, with: target)
            } else {
                try store.move(id: id, toPage: page, before: target)
            }
            clearDragState()
            refresh()
            return true
        } catch {
            clearDragState()
            report(error)
            return false
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDragState() }

    private func clearDragState() {
        dragEdgeTimer?.invalidate(); dragEdgeTimer = nil; dragEdgeDirection = 0
        dropTarget = nil; dropGroups = false
        tiles.forEach { $0.highlightedForDrop = false }
        if folder == nil && page >= pageCount { page = pageCount - 1; refresh() }
    }
}
