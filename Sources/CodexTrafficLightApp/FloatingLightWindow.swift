import Cocoa
import CodexTrafficLightCore

@MainActor
final class FloatingLightWindow {
    let window: NSWindow
    let view: TrafficLightView

    init() {
        let layout = TrafficLightLayout.default
        let size = NSSize(width: layout.windowSize.x, height: layout.windowSize.y)
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

        view.onDrag = { [weak window] delta in
            guard let window else { return }
            var frame = window.frame
            frame.origin.x += delta.x
            frame.origin.y += delta.y
            window.setFrameOrigin(frame.origin)
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
