import AppKit
import ScreenCaptureKit

final class OwnedPreviewCapture {
    private(set) var state = PreviewCaptureState()
    private(set) var image: CGImage?
    private(set) var status = "idle"
    private(set) var requestCount = 0
    private(set) var completedCount = 0
    var onChange: (() -> Void)?
    private let worker = DispatchQueue(label: "com.loomex.flow.p0.preview", qos: .userInitiated)

    var supported: Bool {
        #if LOOMEX_SCREENSHOT_API
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    func show() {
        state.show()
        image = nil
        status = "icons"
        onChange?()
    }

    func hide() {
        state.hide()
        image = nil
        status = "stopped"
        onChange?()
    }

    private func usable(_ window: NSWindow) -> Bool {
        !NSApp.isHidden && window.isVisible && !window.isMiniaturized && window.windowNumber > 0
    }

    func request(_ window: NSWindow) {
        guard state.visible else { return }
        image = nil
        state.clearFrame()
        guard CGPreflightScreenCaptureAccess() else {
            status = "permission_required"
            onChange?()
            return
        }
        guard supported else { status = "unsupported_system"; onChange?(); return }
        guard usable(window) else { status = "target_unavailable"; onChange?(); return }
        guard let token = state.begin(authorized: true, supported: supported, targetAvailable: true) else {
            status = "waiting_for_previous_request"
            onChange?()
            return
        }
        requestCount += 1
        status = "capturing"
        onChange?()
        let windowID = CGWindowID(window.windowNumber)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.state.expire(token) else { return }
            self.image = nil
            self.status = "timed_out_waiting_for_os"
            self.onChange?()
        }
        worker.async { [weak self, weak window] in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                // No window list, title, screenshot or OS error description is logged or persisted.
                let target = content?.windows.first {
                    $0.windowID == windowID && $0.owningApplication?.processID == ownPID
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.state.accepts(token), let window, self.usable(window),
                          CGWindowID(window.windowNumber) == windowID, CGPreflightScreenCaptureAccess() else {
                        self.complete(token, image: nil, status: "cancelled")
                        return
                    }
                    guard error == nil, let target,
                          let size = PreviewPixelSize.fitting(width: target.frame.width, height: target.frame.height) else {
                        self.complete(token, image: nil, status: "target_unavailable")
                        return
                    }
                    #if LOOMEX_SCREENSHOT_API
                    if #available(macOS 26.0, *) {
                        self.capture(target, size: size, token: token, window: window)
                    }
                    #endif
                }
            }
        }
    }

    #if LOOMEX_SCREENSHOT_API
    @available(macOS 26.0, *)
    private func capture(_ target: SCWindow, size: PreviewPixelSize, token: Int, window: NSWindow) {
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCScreenshotConfiguration()
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        config.includeChildWindows = false
        config.ignoreShadows = true
        config.dynamicRange = .sdr
        // Leave fileURL nil: the frame is only ever displayed in local memory.
        worker.async { [weak self, weak window] in
            SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config) { output, error in
                let frame = output?.sdrImage
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let window, self.usable(window),
                          CGWindowID(window.windowNumber) == target.windowID,
                          CGPreflightScreenCaptureAccess() else {
                        self.complete(token, image: nil, status: "target_unavailable")
                        return
                    }
                    self.complete(token, image: error == nil ? frame : nil, status: "capture_failed")
                }
            }
        }
    }
    #endif

    private func complete(_ token: Int, image: CGImage?, status failure: String) {
        guard state.inFlight == token else { return }
        let wasCurrent = state.accepts(token)
        let bounded = image.flatMap { frame -> CGImage? in
            guard frame.width <= 640, frame.height <= 400,
                  frame.bytesPerRow <= PreviewCaptureState.byteLimit / max(1, frame.height) else { return nil }
            return frame
        }
        let bytes = bounded.map { $0.bytesPerRow * $0.height } ?? 0
        let accepted = state.finish(token, bytes: bytes)
        completedCount += 1
        if wasCurrent {
            self.image = accepted ? bounded : nil
            status = accepted ? "preview_ready" : failure
        } else if state.visible {
            status = "icons"
        }
        onChange?()
    }
}
