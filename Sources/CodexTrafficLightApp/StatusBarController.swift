import Cocoa
import CodexTrafficLightCore
import SwiftUI

@MainActor
protocol StatusBarControllerDelegate: AnyObject {
    func statusBarDidRequestQuit()
    func statusBarDidSelectRankingRange(_ range: StatusRankingRange)
}

@MainActor
final class StatusBarController {
    private static let breathingFrameCount = 12
    private static let breathingFrameInterval: TimeInterval = 0.25
    private let healthyGreen = NSColor(
        srgbRed: 0x35 / 255,
        green: 0xD2 / 255,
        blue: 0x70 / 255,
        alpha: 1
    )
    private let healthyGreenTop = NSColor(
        srgbRed: 0x71 / 255,
        green: 0xF3 / 255,
        blue: 0xA2 / 255,
        alpha: 1
    )
    private let healthyGreenBottom = NSColor(
        srgbRed: 0x20 / 255,
        green: 0xAD / 255,
        blue: 0x55 / 255,
        alpha: 1
    )
    private let healthyGreenRim = NSColor(
        srgbRed: 0x08 / 255,
        green: 0x78 / 255,
        blue: 0x3B / 255,
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
    private var syncedQuota: TeamQuotaReport?
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
            selectRange: { [weak self] range in self?.selectRankingRange(range) },
            openGuide: { [weak self] in self?.openTeamGuide() },
            quit: { [weak self] in self?.delegate?.statusBarDidRequestQuit() }
        )
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = hostingController
        updateQuotaIndicator()
    }

    func apply(snapshot: StateSnapshot?) {
        self.snapshot = snapshot
        popoverModel.snapshot = snapshot
        refreshQuotaPresentation()
    }

    func applyTeamRanking(
        _ ranking: TeamRankingSnapshot?,
        websiteURL: URL?,
        syncDetail: String? = nil,
        currentUserID: String? = nil
    ) {
        teamRanking = ranking
        teamWebsiteURL = websiteURL
        teamSyncDetail = syncDetail
        popoverModel.ranking = ranking
        popoverModel.websiteURL = websiteURL
        if let currentUserID {
            syncedQuota = ranking?.weeklyQuota(for: currentUserID)
            popoverModel.syncedQuota = syncedQuota
            refreshQuotaPresentation()
        }
        if let syncDetail { popoverModel.syncDetail = syncDetail }
        popoverModel.isRangeLoading = false
    }

    func setRankingRange(_ range: StatusRankingRange, isLoading: Bool) {
        popoverModel.selectedRange = range
        popoverModel.isRangeLoading = isLoading
    }

    func setRankingRangeLoading(_ isLoading: Bool) {
        popoverModel.isRangeLoading = isLoading
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

    private func statusBarText() -> String {
        guard let percent = effectiveWeeklyQuota()?.remainingPercent else {
            return "周余额 --"
        }
        return "周余额 \(percent)%"
    }

    private func detailLines() -> [String] {
        let weekly = effectiveWeeklyQuota()
        let percentText = weekly?.remainingPercent.map { "\($0)%" } ?? "--"
        guard let resetsAt = weekly?.resetsAt else {
            return [
                "周余额：\(percentText)",
                "距离刷新：暂无数据",
                "刷新时间：暂无数据"
            ]
        }

        return [
            "周余额：\(percentText)",
            "距离刷新：\(QuotaDisplayFormatter.refreshCountdownText(until: resetsAt))",
            "刷新时间：\(QuotaDisplayFormatter.absoluteDateTimeText(resetsAt))"
        ]
    }

    private func weeklyQuota(from snapshot: StateSnapshot?) -> (remainingPercent: Int?, resetsAt: Date?)? {
        guard let quota = snapshot?.quota,
              quota.limitID == CodexSessionQuotaCollector.primaryLimitID else { return nil }
        return (quota.weeklyRemainingPercent, quota.weeklyResetsAt)
    }

    private func effectiveWeeklyQuota() -> (remainingPercent: Int?, resetsAt: Date?)? {
        if let syncedQuota {
            return (syncedQuota.weeklyRemainingPercent, syncedQuota.weeklyResetsAtDate)
        }
        return weeklyQuota(from: snapshot)
    }

    private func refreshQuotaPresentation() {
        weeklyRemainingPercent = effectiveWeeklyQuota()?.remainingPercent
        updateQuotaIndicator()
        item.button?.title = statusBarText()
        item.button?.toolTip = detailLines().joined(separator: "\n")
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

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopAnimation()
            item.button?.image = makeQuotaIndicator(
                color: healthyGreen,
                glow: 0.82,
                coreTop: healthyGreenTop,
                coreBottom: healthyGreenBottom,
                rim: healthyGreenRim,
                haloProgress: 0.35
            )
            return
        }

        if breathingTimer == nil {
            if breathingFrames.isEmpty {
                breathingFrames = (0..<Self.breathingFrameCount).map { index in
                    let progress = CGFloat(index) / CGFloat(Self.breathingFrameCount - 1)
                    return makeQuotaIndicator(
                        color: healthyGreen,
                        glow: 0.82,
                        coreTop: healthyGreenTop,
                        coreBottom: healthyGreenBottom,
                        rim: healthyGreenRim,
                        haloProgress: progress
                    )
                }
            }
            breathingFrameIndex = 0
            let timer = Timer(
                timeInterval: Self.breathingFrameInterval,
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

    private func openTeamGuide() {
        guard var guideURL = teamWebsiteURL else { return }
        guideURL.append(path: "guide")
        NSWorkspace.shared.open(guideURL)
        popover.performClose(nil)
    }

    private func selectRankingRange(_ range: StatusRankingRange) {
        setRankingRange(range, isLoading: true)
        delegate?.statusBarDidSelectRankingRange(range)
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
        rim: NSColor? = nil,
        haloProgress: CGFloat? = nil
    ) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let haloDiameter: CGFloat
        let haloAlpha: CGFloat
        if let haloProgress {
            let eased = 1 - pow(1 - haloProgress, 2)
            haloDiameter = 13.2 + (4.0 * eased)
            haloAlpha = 0.48 * (1 - pow(haloProgress, 2.25))
        } else {
            haloDiameter = 13.4 + (2.4 * glow)
            haloAlpha = 0.13 + (0.11 * glow)
        }
        let haloRect = NSRect(
            x: (size.width - haloDiameter) / 2,
            y: (size.height - haloDiameter) / 2,
            width: haloDiameter,
            height: haloDiameter
        )
        color.withAlphaComponent(haloAlpha * 0.36).setFill()
        NSBezierPath(ovalIn: haloRect).fill()

        color.withAlphaComponent(haloAlpha).setStroke()
        let haloRing = NSBezierPath(ovalIn: haloRect.insetBy(dx: 0.6, dy: 0.6))
        haloRing.lineWidth = 1.25
        haloRing.stroke()

        let softGlowRect = NSRect(x: 2.45, y: 2.45, width: 13.1, height: 13.1)
        color.withAlphaComponent(0.38 * glow).setFill()
        NSBezierPath(ovalIn: softGlowRect).fill()

        let rimRect = NSRect(x: 2.75, y: 2.75, width: 12.5, height: 12.5)
        (rim ?? color).setFill()
        NSBezierPath(ovalIn: rimRect).fill()

        let coreRect = NSRect(x: 3.65, y: 3.65, width: 10.7, height: 10.7)
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

        NSColor.white.withAlphaComponent(0.80).setFill()
        NSBezierPath(ovalIn: NSRect(x: 5.45, y: 9.65, width: 3.0, height: 2.0)).fill()

        image.isTemplate = false
        return image
    }

}
