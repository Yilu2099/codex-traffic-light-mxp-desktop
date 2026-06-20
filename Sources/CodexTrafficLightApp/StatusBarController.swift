import Cocoa
import CodexTrafficLightCore

@MainActor
protocol StatusBarControllerDelegate: AnyObject {
    func statusBarDidRequestState(_ state: LightState)
    func statusBarDidRequestClear()
    func statusBarDidRequestToggleMute()
    func statusBarDidRequestQuit()
}

@MainActor
final class StatusBarController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    weak var delegate: StatusBarControllerDelegate?
    private var state: LightState = .idle
    private var muted = false
    private var quota: QuotaSnapshot?

    init() {
        item.button?.imagePosition = .imageLeft
        rebuildMenu()
    }

    func apply(state: LightState, muted: Bool, quota: QuotaSnapshot?) {
        self.state = state
        self.muted = muted
        self.quota = quota
        item.button?.image = makeStatusImage(state: state)
        item.button?.title = statusBarQuotaText(for: quota)
        item.button?.toolTip = tooltipText(state: state, quota: quota)
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "当前：\(state.label)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "额度：\(quotaText(for: quota))", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: muted ? "恢复提示音" : "静音提示音", action: #selector(toggleMute), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "黄灯：工作中", action: #selector(setWorking), keyEquivalent: "")
        menu.addItem(withTitle: "绿灯：已完成", action: #selector(setDone), keyEquivalent: "")
        menu.addItem(withTitle: "红灯：待确认", action: #selector(setWaiting), keyEquivalent: "")
        menu.addItem(withTitle: "黑灯：空闲", action: #selector(setIdle), keyEquivalent: "")
        menu.addItem(withTitle: "清空失联任务", action: #selector(clear), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        item.menu = menu
    }

    private func tooltipText(state: LightState, quota: QuotaSnapshot?) -> String {
        let base = "Codex 红绿灯：\(state.label)"
        guard let quota else { return base }
        return "\(base) · \(quotaText(for: quota))"
    }

    private func quotaText(for quota: QuotaSnapshot?) -> String {
        guard let quota else { return "暂无数据" }
        return "5小时 \(quota.fiveHourRemainingPercent)% · 1周 \(quota.weeklyRemainingPercent)%"
    }

    private func statusBarQuotaText(for quota: QuotaSnapshot?) -> String {
        guard let quota else { return " 5h -- · 1周 --" }
        return " 5h \(quota.fiveHourRemainingPercent)% · 1周 \(quota.weeklyRemainingPercent)%"
    }

    @objc private func setWorking() { delegate?.statusBarDidRequestState(.working) }
    @objc private func setDone() { delegate?.statusBarDidRequestState(.done) }
    @objc private func setWaiting() { delegate?.statusBarDidRequestState(.waiting) }
    @objc private func setIdle() { delegate?.statusBarDidRequestState(.idle) }
    @objc private func clear() { delegate?.statusBarDidRequestClear() }
    @objc private func toggleMute() { delegate?.statusBarDidRequestToggleMute() }
    @objc private func quit() { delegate?.statusBarDidRequestQuit() }

    private func makeStatusImage(state: LightState) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let color: NSColor
        let alpha: CGFloat
        switch state {
        case .waiting:
            color = NSColor(hex: "#f3423b")
            alpha = 1.0
        case .working:
            color = NSColor(hex: "#ffd441")
            alpha = 1.0
        case .done:
            color = NSColor(hex: "#55d34d")
            alpha = 1.0
        case .idle, .quit:
            color = NSColor(hex: "#111418")
            alpha = 1.0
        }

        color.withAlphaComponent(state == .idle || state == .quit ? 0.70 : 0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 14, height: 14)).fill()
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 8, height: 8)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
