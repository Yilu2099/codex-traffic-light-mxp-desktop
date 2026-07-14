import Cocoa
import CodexTrafficLightCore

@MainActor
final class FloatingLightWindow {
    private static let designAspectRatio = CGFloat(TrafficLightLayout.default.windowSize.x / TrafficLightLayout.default.windowSize.y)
    private static let defaultWidth: CGFloat = 80
    private static let minimumWidth: CGFloat = 68
    private static let maximumWidth: CGFloat = 200
    private static let savedWidthKey = "CodexTrafficLightFloatingWindowUltraCompactWidth"

    let window: NSWindow
    let view: TrafficLightView

    init() {
        let savedWidth = CGFloat(UserDefaults.standard.double(forKey: Self.savedWidthKey))
        let width = savedWidth >= Self.minimumWidth && savedWidth <= Self.maximumWidth
            ? savedWidth
            : Self.defaultWidth
        let size = NSSize(width: width, height: width / Self.designAspectRatio)
        view = TrafficLightView(frame: NSRect(origin: .zero, size: size))
        window = NSWindow(
            contentRect: FloatingLightWindow.preferredFrame(size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        view.autoresizingMask = [.width, .height]

        view.onDrag = { [weak window] delta in
            guard let window else { return }
            var frame = window.frame
            frame.origin.x += delta.x
            frame.origin.y += delta.y
            window.setFrameOrigin(frame.origin)
        }
        view.onResize = { [weak window] widthDelta in
            guard let window else { return }
            let oldFrame = window.frame
            let nextWidth = min(Self.maximumWidth, max(Self.minimumWidth, oldFrame.width + widthDelta))
            guard nextWidth != oldFrame.width else { return }
            let nextHeight = nextWidth / Self.designAspectRatio
            let nextFrame = NSRect(
                x: oldFrame.minX,
                y: oldFrame.maxY - nextHeight,
                width: nextWidth,
                height: nextHeight
            )
            window.setFrame(nextFrame, display: true)
            UserDefaults.standard.set(Double(nextWidth), forKey: Self.savedWidthKey)
        }
        view.onToggleVisibility = { [weak window] in
            window?.orderOut(nil)
        }
    }

    func apply(state: LightState, quota: QuotaSnapshot?, show: Bool) {
        view.state = state
        view.quota = quota
        if show {
            showWindow()
        }
    }

    func hide() {
        window.orderOut(nil)
    }

    func toggle() {
        if window.isVisible {
            hide()
        } else {
            showWindow()
        }
    }

    private func showWindow() {
        ensureOnScreen()
        window.orderFrontRegardless()
    }

    private func ensureOnScreen() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        if visible.intersects(window.frame) {
            return
        }
        window.setFrame(FloatingLightWindow.preferredFrame(size: window.frame.size, screen: screen), display: true)
    }

    private static func preferredFrame(size: NSSize, screen: NSScreen? = NSScreen.main) -> NSRect {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 64,
            width: size.width,
            height: size.height
        )
    }
}
