import Cocoa
import CodexTrafficLightCore

@MainActor
protocol StatusBarControllerDelegate: AnyObject {
    func statusBarDidRequestState(_ state: LightState)
    func statusBarDidRequestClear()
    func statusBarDidRequestToggleFloatingWindow()
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
        item.button?.imagePosition = .imageOnly
        rebuildMenu()
    }

    func apply(state: LightState, muted: Bool, quota: QuotaSnapshot?) {
        self.state = state
        self.muted = muted
        self.quota = quota
        item.button?.image = makeStatusImage(state: state)
        item.button?.toolTip = tooltipText(state: state, quota: quota)
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "当前：\(state.label)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "额度：\(quotaText(for: quota))", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示/隐藏红绿灯", action: #selector(toggleFloatingWindow), keyEquivalent: "")
        menu.addItem(withTitle: muted ? "恢复提示音" : "静音提示音", action: #selector(toggleMute), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "黄灯：工作中", action: #selector(setWorking), keyEquivalent: "")
        menu.addItem(withTitle: "绿灯：已完成", action: #selector(setDone), keyEquivalent: "")
        menu.addItem(withTitle: "红灯：待确认", action: #selector(setWaiting), keyEquivalent: "")
        menu.addItem(withTitle: "全暗：空闲", action: #selector(setIdle), keyEquivalent: "")
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

    @objc private func setWorking() { delegate?.statusBarDidRequestState(.working) }
    @objc private func setDone() { delegate?.statusBarDidRequestState(.done) }
    @objc private func setWaiting() { delegate?.statusBarDidRequestState(.waiting) }
    @objc private func setIdle() { delegate?.statusBarDidRequestState(.idle) }
    @objc private func clear() { delegate?.statusBarDidRequestClear() }
    @objc private func toggleFloatingWindow() { delegate?.statusBarDidRequestToggleFloatingWindow() }
    @objc private func toggleMute() { delegate?.statusBarDidRequestToggleMute() }
    @objc private func quit() { delegate?.statusBarDidRequestQuit() }

    private func makeStatusImage(state: LightState) -> NSImage {
        let size = NSSize(width: 28, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let lights: [(LightState, NSColor, CGFloat)] = [
            (.waiting, NSColor(hex: "#f3423b"), 6),
            (.working, NSColor(hex: "#ffd441"), 14),
            (.done, NSColor(hex: "#55d34d"), 22)
        ]
        for (lightState, color, x) in lights {
            let active = state == lightState
            color.withAlphaComponent(active ? 1.0 : 0.20).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 4, y: 4, width: 8, height: 8)).fill()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
