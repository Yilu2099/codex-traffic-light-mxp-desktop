import Cocoa
import CodexTrafficLightCore
import SwiftUI

@MainActor
protocol StatusBarControllerDelegate: AnyObject {
    func statusBarDidRequestQuit()
}

@MainActor
final class StatusBarController {
    private let healthyGreen = NSColor(
        srgbRed: 0x2F / 255,
        green: 0x9E / 255,
        blue: 0x55 / 255,
        alpha: 1
    )
    private let healthyGreenTop = NSColor(
        srgbRed: 0x3F / 255,
        green: 0xB6 / 255,
        blue: 0x64 / 255,
        alpha: 1
    )
    private let healthyGreenBottom = NSColor(
        srgbRed: 0x20 / 255,
        green: 0x7A / 255,
        blue: 0x3D / 255,
        alpha: 1
    )
    private let healthyGreenRim = NSColor(
        srgbRed: 0x19 / 255,
        green: 0x5F / 255,
        blue: 0x31 / 255,
        alpha: 1
    )
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let popoverModel = StatusPopoverModel()
    weak var delegate: StatusBarControllerDelegate?
    private var snapshot: StateSnapshot?
    private var teamRanking: TeamRankingSnapshot?
    private var teamWebsiteURL: URL?
    private var teamSyncDetail: String?
    private var weeklyRemainingPercent: Int?
    private var breathingTimer: Timer?
    private var breathingFrames: [NSImage] = []
    private var breathingFrameIndex = 0

    init() {
        item.button?.imagePosition = .imageLeft
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 456, height: 640)
        let rootView = StatusPopoverView(
            model: popoverModel,
            openWebsite: { [weak self] memberID in self?.openTeamWebsite(memberID: memberID) },
            quit: { [weak self] in self?.delegate?.statusBarDidRequestQuit() }
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = hostingController
        updateQuotaIndicator()
    }

    func apply(snapshot: StateSnapshot?) {
        self.snapshot = snapshot
        weeklyRemainingPercent = weeklyQuota(from: snapshot)?.remainingPercent
        updateQuotaIndicator()
        item.button?.title = statusBarText(for: snapshot)
        item.button?.toolTip = detailLines(for: snapshot).joined(separator: "\n")
        popoverModel.snapshot = snapshot
    }

    func applyTeamRanking(_ ranking: TeamRankingSnapshot?, websiteURL: URL?, syncDetail: String? = nil) {
        teamRanking = ranking
        teamWebsiteURL = websiteURL
        teamSyncDetail = syncDetail
        popoverModel.ranking = ranking
        popoverModel.websiteURL = websiteURL
        if let syncDetail { popoverModel.syncDetail = syncDetail }
    }

    func setTeamSyncDetail(_ detail: String, websiteURL: URL? = nil) {
        teamSyncDetail = detail
        if let websiteURL { teamWebsiteURL = websiteURL }
        popoverModel.syncDetail = detail
        if let websiteURL { popoverModel.websiteURL = websiteURL }
    }

    func stopAnimation() {
        breathingTimer?.invalidate()
        breathingTimer = nil
    }

    private func statusBarText(for snapshot: StateSnapshot?) -> String {
        guard let percent = weeklyQuota(from: snapshot)?.remainingPercent else {
            return "周额度 --"
        }
        return "周额度 \(percent)%"
    }

    private func detailLines(for snapshot: StateSnapshot?) -> [String] {
        let weekly = weeklyQuota(from: snapshot)
        let percentText = weekly?.remainingPercent.map { "\($0)%" } ?? "--"
        guard let resetsAt = weekly?.resetsAt else {
            return [
                "周额度剩余：\(percentText)",
                "距离刷新：暂无数据",
                "刷新时间：暂无数据"
            ]
        }

        return [
            "周额度剩余：\(percentText)",
            "距离刷新：\(QuotaDisplayFormatter.relativeResetText(until: resetsAt, unitStyle: .daysAndHours))",
            "刷新时间：\(QuotaDisplayFormatter.absoluteDateTimeText(resetsAt))"
        ]
    }

    private func weeklyQuota(from snapshot: StateSnapshot?) -> (remainingPercent: Int?, resetsAt: Date?)? {
        guard let snapshot else { return nil }
        if let codex = snapshot.providerQuota(for: ProviderQuotaSnapshot.codexProviderID) {
            return (codex.weeklyRemainingPercent, codex.weeklyResetsAt)
        }
        guard let legacy = snapshot.quota else { return nil }
        return (legacy.weeklyRemainingPercent, legacy.weeklyResetsAt)
    }

    private func updateQuotaIndicator() {
        guard let percent = weeklyRemainingPercent else {
            stopAnimation()
            item.button?.image = makeQuotaIndicator(color: .systemGray, glow: 0.15)
            return
        }

        if percent <= 10 {
            stopAnimation()
            item.button?.image = makeQuotaIndicator(color: .systemRed, glow: 0.72)
            return
        }

        if breathingTimer == nil {
            if breathingFrames.isEmpty {
                breathingFrames = (0..<30).map { index in
                    let wave = (sin(Double(index) * 2 * .pi / 30) + 1) / 2
                    let eased = wave * wave * (3 - 2 * wave)
                    return makeQuotaIndicator(
                        color: healthyGreen,
                        glow: CGFloat(eased),
                        coreTop: healthyGreenTop,
                        coreBottom: healthyGreenBottom,
                        rim: healthyGreenRim
                    )
                }
            }
            breathingFrameIndex = 0
            let timer = Timer(
                timeInterval: 0.12,
                target: self,
                selector: #selector(breathingTimerFired),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            breathingTimer = timer
        }
        updateBreathingFrame()
    }

    @objc private func breathingTimerFired() {
        guard let percent = weeklyRemainingPercent, percent > 10 else {
            updateQuotaIndicator()
            return
        }
        updateBreathingFrame()
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func openTeamWebsite(memberID: String?) {
        guard let teamWebsiteURL else { return }
        var components = URLComponents(url: teamWebsiteURL, resolvingAgainstBaseURL: false)
        if let memberID { components?.queryItems = [URLQueryItem(name: "member", value: memberID)] }
        NSWorkspace.shared.open(components?.url ?? teamWebsiteURL)
        popover.performClose(nil)
    }

    private func updateBreathingFrame() {
        guard !breathingFrames.isEmpty else { return }
        item.button?.image = breathingFrames[breathingFrameIndex]
        breathingFrameIndex = (breathingFrameIndex + 1) % breathingFrames.count
    }

    private func makeQuotaIndicator(
        color: NSColor,
        glow: CGFloat,
        coreTop: NSColor? = nil,
        coreBottom: NSColor? = nil,
        rim: NSColor? = nil
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let haloDiameter = 14 + (3 * glow)
        let haloRect = NSRect(
            x: (size.width - haloDiameter) / 2,
            y: (size.height - haloDiameter) / 2,
            width: haloDiameter,
            height: haloDiameter
        )
        color.withAlphaComponent(0.16 + (0.16 * glow)).setFill()
        NSBezierPath(ovalIn: haloRect).fill()

        let softGlowRect = NSRect(x: 3, y: 3, width: 12, height: 12)
        color.withAlphaComponent(0.32 + (0.22 * glow)).setFill()
        NSBezierPath(ovalIn: softGlowRect).fill()

        let rimRect = NSRect(x: 4, y: 4, width: 10, height: 10)
        (rim ?? color).setFill()
        NSBezierPath(ovalIn: rimRect).fill()

        let coreRect = NSRect(x: 4.8, y: 4.8, width: 8.4, height: 8.4)
        if let coreTop, let coreBottom,
           let gradient = NSGradient(starting: coreTop, ending: coreBottom) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: coreRect).addClip()
            gradient.draw(in: coreRect, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            color.setFill()
            NSBezierPath(ovalIn: coreRect).fill()
        }

        NSColor.white.withAlphaComponent(0.14 + (0.05 * glow)).setFill()
        NSBezierPath(ovalIn: NSRect(x: 6.6, y: 9.5, width: 2.2, height: 1.5)).fill()

        image.isTemplate = false
        return image
    }

}
