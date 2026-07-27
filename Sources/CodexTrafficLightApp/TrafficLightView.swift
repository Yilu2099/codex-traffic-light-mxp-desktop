import Cocoa
import CodexTrafficLightCore

final class TrafficLightView: NSView {
    private let layout = TrafficLightLayout.default

    var state: LightState = .idle {
        didSet { needsDisplay = true }
    }
    var quota: QuotaSnapshot? {
        didSet { needsDisplay = true }
    }
    var blinkOn = true {
        didSet { needsDisplay = true }
    }
    var waitingAlertActive = false {
        didSet { needsDisplay = true }
    }
    var breathingPhase: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var onDrag: ((NSPoint) -> Void)?
    var onResize: ((CGFloat) -> Void)?
    var onToggleVisibility: (() -> Void)?

    private enum DragMode {
        case move
        case resize
    }

    private var dragStart: NSPoint?
    private var dragMode: DragMode = .move

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(
            NSRect(x: bounds.maxX - 28, y: 0, width: 28, height: 28),
            cursor: .resizeLeftRight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        let scale = min(
            bounds.width / CGFloat(layout.windowSize.x),
            bounds.height / CGFloat(layout.windowSize.y)
        )
        let scaledWidth = CGFloat(layout.windowSize.x) * scale
        let scaledHeight = CGFloat(layout.windowSize.y) * scale
        let offset = NSPoint(
            x: (bounds.width - scaledWidth) / 2,
            y: (bounds.height - scaledHeight) / 2
        )
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: offset.x, yBy: offset.y)
        transform.scale(by: scale)
        transform.concat()

        let body = layout.bodyRect.nsRect
        drawRoundedGradient(
            body,
            radius: 40,
            top: NSColor(hex: "#353a42"),
            bottom: NSColor(hex: "#16191e"),
            stroke: NSColor.white.withAlphaComponent(0.18),
            width: 1
        )

        drawSignalHousing()
        drawPanelDividers()

        let centers: [(TrafficLightSlot, NSPoint)] = [
            (.red, layout.center(for: .red).nsPoint),
            (.yellow, layout.center(for: .yellow).nsPoint),
            (.green, layout.center(for: .green).nsPoint)
        ]
        for (light, center) in centers {
            drawLens(center: center, light: light, active: isVisible(light))
        }
        drawStatusAndQuota()
        NSGraphicsContext.restoreGraphicsState()
        drawResizeHandle()
    }

    private func activeLight() -> TrafficLightSlot? {
        switch state {
        case .waiting: return .red
        case .working: return .yellow
        case .done: return .green
        case .idle, .quit: return nil
        }
    }

    private func isVisible(_ light: TrafficLightSlot) -> Bool {
        guard activeLight() == light else { return false }
        return state == .waiting && waitingAlertActive ? blinkOn : true
    }

    private func color(for light: TrafficLightSlot) -> NSColor {
        switch light {
        case .red: return NSColor(hex: "#f3423b")
        case .yellow: return NSColor(hex: "#ffd441")
        case .green: return NSColor(hex: "#55d34d")
        }
    }

    private func drawStatusAndQuota() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let stateColor = activeLight().map { color(for: $0) } ?? NSColor.white
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.roundedSystemFont(ofSize: 34, weight: .bold),
            .foregroundColor: stateColor.withAlphaComponent(activeLight() == nil ? 0.56 : 0.96),
            .kern: 0.6,
            .shadow: NSShadow.softTextShadow(alpha: 0.42),
            .paragraphStyle: paragraph
        ]

        state.label.draw(in: layout.statusRect.nsRect, withAttributes: attributes)

        drawQuotaRow(
            row: layout.quotaRows[0],
            percent: quota?.weeklyRemainingPercent,
            accent: NSColor(hex: "#8bd96b")
        )
    }

    private func drawQuotaRow(row: TrafficLightQuotaRowLayout, percent: Int?, accent: NSColor) {
        let clampedPercent = percent.map { min(max($0, 0), 100) }
        let value = clampedPercent.map { "\($0)%" } ?? "--"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.roundedSystemFont(ofSize: 23, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(percent == nil ? 0.48 : 0.92),
            .kern: 0,
            .shadow: NSShadow.softTextShadow(alpha: 0.34),
            .paragraphStyle: paragraph
        ]

        "\(row.label)\(value)".draw(in: row.textRect.nsRect, withAttributes: attributes)

        let barRect = row.progressRect.nsRect
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: 5, yRadius: 5)
        NSColor.white.withAlphaComponent(0.18).setFill()
        barPath.fill()

        guard let clampedPercent, clampedPercent > 0 else { return }
        let fillRect = NSRect(
            x: barRect.minX,
            y: barRect.minY,
            width: barRect.width * CGFloat(clampedPercent) / 100,
            height: barRect.height
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 5, yRadius: 5)
        accent.withAlphaComponent(0.88).setFill()
        fillPath.fill()
    }

    private func drawSignalHousing() {
        let rect = NSRect(x: 26, y: 194, width: 108, height: 278)
        let path = NSBezierPath(roundedRect: rect, xRadius: 54, yRadius: 54)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(
            starting: NSColor(hex: "#171a20"),
            ending: NSColor(hex: "#292e35")
        )?.draw(in: rect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 2
        path.stroke()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 51, yRadius: 51)
        inner.lineWidth = 1
        inner.stroke()
    }

    private func drawPanelDividers() {
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let horizontal = NSBezierPath()
        horizontal.move(to: NSPoint(x: layout.bodyRect.minX + 10, y: 178))
        horizontal.line(to: NSPoint(x: layout.bodyRect.maxX - 10, y: 178))
        horizontal.lineWidth = 1
        horizontal.stroke()
    }

    private func drawLens(center: NSPoint, light: TrafficLightSlot, active: Bool) {
        let base = color(for: light)
        let pulse = active ? (sin(breathingPhase) + 1) / 2 : 0
        let glowAlpha: CGFloat = active ? 0.16 + pulse * 0.10 : 0.015
        let fillAlpha: CGFloat = active ? 0.93 + pulse * 0.05 : 0.24
        let rimAlpha: CGFloat = active ? 0.48 + pulse * 0.14 : 0.16
        let glowRadius = CGFloat(layout.lensGlowRadius) + pulse * 3
        let bulbRadius = CGFloat(layout.lensBulbRadius)

        base.withAlphaComponent(glowAlpha).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - glowRadius,
            y: center.y - glowRadius,
            width: glowRadius * 2,
            height: glowRadius * 2
        )).fill()

        let socketRadius = bulbRadius + 6
        NSColor.black.withAlphaComponent(0.58).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - socketRadius,
            y: center.y - socketRadius,
            width: socketRadius * 2,
            height: socketRadius * 2
        )).fill()

        let bulb = NSBezierPath(ovalIn: NSRect(
            x: center.x - bulbRadius,
            y: center.y - bulbRadius,
            width: bulbRadius * 2,
            height: bulbRadius * 2
        ))
        base.withAlphaComponent(fillAlpha).setFill()
        bulb.fill()

        base.withAlphaComponent(rimAlpha).setStroke()
        bulb.lineWidth = 3
        bulb.stroke()

        NSColor.black.withAlphaComponent(0.23).setStroke()
        bulb.lineWidth = 1
        bulb.stroke()

        NSColor.white.withAlphaComponent(active ? 0.26 : 0.07).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 12, y: center.y + 11, width: 20, height: 7)).fill()
    }

    private func drawResizeHandle() {
        guard bounds.width >= 80, bounds.height >= 160 else { return }
        NSColor.white.withAlphaComponent(0.20).setStroke()
        for inset in [CGFloat(6), CGFloat(11)] {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.maxX - inset - 5, y: 5))
            path.line(to: NSPoint(x: bounds.maxX - 5, y: inset + 5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawRoundedGradient(_ rect: NSRect, radius: CGFloat, top: NSColor, bottom: NSColor, stroke: NSColor, width: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: bottom, ending: top)?.draw(in: rect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        stroke.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onToggleVisibility?()
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        dragMode = location.x >= bounds.maxX - 28 && location.y <= 28 ? .resize : .move
        dragStart = window?.convertPoint(toScreen: event.locationInWindow) ?? location
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = window?.convertPoint(toScreen: event.locationInWindow)
            ?? convert(event.locationInWindow, from: nil)
        let delta = NSPoint(x: current.x - dragStart.x, y: current.y - dragStart.y)
        switch dragMode {
        case .move:
            onDrag?(delta)
        case .resize:
            onResize?(delta.x)
        }
        self.dragStart = current
    }
}

private extension TrafficLightPoint {
    var nsPoint: NSPoint {
        NSPoint(x: x, y: y)
    }
}

private extension TrafficLightRect {
    var nsRect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

private extension NSFont {
    static func roundedSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else {
            return font
        }
        return rounded
    }
}

private extension NSShadow {
    static func softTextShadow(alpha: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowOffset = NSSize(width: 0, height: -0.8)
        shadow.shadowBlurRadius = 1.8
        return shadow
    }
}
