import AppKit
import CodexTrafficLightCore

@MainActor
enum ExternalAlertDialog {
    static func make(_ alert: ExternalAlert, target: AnyObject?, confirmAction: Selector?) -> NSPanel {
        let detail = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        detail.titleVisibility = .hidden
        detail.titlebarAppearsTransparent = true
        detail.isMovableByWindowBackground = true
        detail.level = .floating
        detail.hidesOnDeactivate = false
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "重置预告")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = NSColor(srgbRed: 0.21, green: 0.47, blue: 0.31, alpha: 1)
        title.alignment = .center
        title.widthAnchor.constraint(equalToConstant: 306).isActive = true
        content.addArrangedSubview(title)
        let lines = [alert.body.components(separatedBy: .newlines).first ?? ""]
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let label = NSTextField(wrappingLabelWithString: line)
            label.font = .systemFont(ofSize: index == 0 ? 20 : 12, weight: index == 0 ? .semibold : .regular)
            label.textColor = index == 0 ? .labelColor : .secondaryLabelColor
            label.alignment = .center
            content.addArrangedSubview(label)
            label.widthAnchor.constraint(equalToConstant: 306).isActive = true
        }
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        let metadata = NSStackView()
        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 3
        if let url = alert.sourceURL, url.scheme == "https" {
            let link = AlertSourceButton(url: url)
            metadata.addArrangedSubview(link)
        }
        footer.addArrangedSubview(metadata)
        footer.addArrangedSubview(NSView())
        let confirm = NSButton(title: "知道了", target: target, action: confirmAction)
        confirm.bezelStyle = .rounded
        confirm.isBordered = false
        confirm.wantsLayer = true
        confirm.layer?.backgroundColor = NSColor(srgbRed: 0.255, green: 0.553, blue: 0.38, alpha: 1).cgColor
        confirm.layer?.cornerRadius = 6
        confirm.contentTintColor = .white
        confirm.controlSize = .regular
        confirm.widthAnchor.constraint(equalToConstant: 80).isActive = true
        confirm.heightAnchor.constraint(equalToConstant: 28).isActive = true
        footer.addArrangedSubview(confirm)
        content.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalToConstant: 306).isActive = true
        let container = AlertGlowView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])
        content.layoutSubtreeIfNeeded()
        detail.contentView = container
        detail.setContentSize(NSSize(width: 350, height: content.fittingSize.height + 40))
        container.layoutSubtreeIfNeeded()
        return detail
    }

    static func writePreview(_ alert: ExternalAlert, to url: URL) -> Bool {
        let detail = make(alert, target: nil, confirmAction: nil)
        detail.center()
        detail.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let view = detail.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true } catch { return false }
    }
}

@MainActor
private final class AlertGlowView: NSView {
    private let rim = CALayer(), gradient = CAGradientLayer(), outline = CAShapeLayer(), topLine = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.75
        layer?.borderColor = NSColor(srgbRed: 0.86, green: 0.89, blue: 0.86, alpha: 1).cgColor
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.cgColor
        outline.lineWidth = 1.5
        rim.mask = outline
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor(srgbRed: 0.57, green: 0.74, blue: 0.40, alpha: 0.7).cgColor, NSColor.clear.cgColor]
        gradient.locations = [0, 0.70, 0.84, 0.98]
        rim.addSublayer(gradient)
        layer?.addSublayer(rim)
        topLine.fillColor = nil
        topLine.strokeColor = NSColor(srgbRed: 0.255, green: 0.553, blue: 0.38, alpha: 1).cgColor
        topLine.lineWidth = 3
        layer?.addSublayer(topLine)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = 6
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "borderGlow")
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = bounds
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 8, cornerHeight: 8, transform: nil)
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 8, y: bounds.maxY - 1.5))
        path.addLine(to: CGPoint(x: bounds.maxX - 8, y: bounds.maxY - 1.5))
        topLine.path = path
        CATransaction.commit()
    }
}

@MainActor
private final class AlertSourceButton: NSButton {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        title = "查看原帖 ↗"
        font = .systemFont(ofSize: 11)
        isBordered = false
        contentTintColor = .linkColor
        toolTip = url.absoluteString
        target = self
        action = #selector(openSource)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func openSource() { NSWorkspace.shared.open(url) }
}
