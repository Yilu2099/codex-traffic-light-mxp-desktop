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
    var isPopoverShown: Bool { popover.isShown }
    private let popoverModel = StatusPopoverModel()
    var onPopoverOpen: (() -> Void)?
    weak var delegate: StatusBarControllerDelegate?
    private var snapshot: StateSnapshot?
    private var teamRanking: TeamRankingSnapshot?
    private var teamWebsiteURL: URL?
    private var teamSyncDetail: String?
    private var syncedQuota: TeamQuotaReport?
    private var quotaRemainingPercent: Int?

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
            openBureau: { [weak self] in self?.openBureau() },
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

    func setInspirationUnreadCount(_ count: Int) {
        popoverModel.inspirationUnreadCount = max(0, count)
    }

    func applyTeamRanking(
        _ ranking: TeamRankingSnapshot?,
        websiteURL: URL?,
        syncDetail: String? = nil,
        currentUserID: String? = nil,
        highlights: [String: MemberHighlight] = [:]
    ) {
        teamRanking = ranking
        teamWebsiteURL = websiteURL
        teamSyncDetail = syncDetail
        popoverModel.ranking = ranking
        popoverModel.highlights = highlights
        popoverModel.websiteURL = websiteURL
        if let currentUserID {
            syncedQuota = ranking?.quota(for: currentUserID)
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

    static func writeCreditPreview(to url: URL) -> Bool {
        let controller = StatusBarController()
        defer { NSStatusBar.system.removeStatusItem(controller.item) }
        let now = Date()
        controller.apply(snapshot: StateSnapshot(updatedAt: now, quota: QuotaSnapshot(
            weeklyRemainingPercent: 0, weeklyResetsAt: now.addingTimeInterval(86400),
            creditBalance: 60_564, source: "preview", limitID: "codex", updatedAt: now)))
        guard let button = controller.item.button else { return false }
        let preview = NSButton(title: button.title, target: nil, action: nil)
        preview.image = button.image
        preview.imagePosition = .imageLeft
        preview.imageScaling = .scaleProportionallyDown
        preview.isBordered = false
        preview.font = button.font
        preview.appearance = NSAppearance(named: .aqua)
        preview.frame = NSRect(x: 0, y: 0, width: preview.fittingSize.width + 12, height: 24)
        guard let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { return false }
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        let image = NSImage(size: preview.bounds.size)
        image.lockFocus()
        NSColor(white: 0.94, alpha: 1).setFill()
        preview.bounds.fill()
        let foreground = NSImage(size: preview.bounds.size)
        foreground.addRepresentation(bitmap)
        foreground.draw(in: preview.bounds, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let output = NSBitmapImageRep(data: tiff),
              let png = output.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true } catch { return false }
    }

    private func statusBarText() -> String {
        if let credits = remainingCreditText { return "剩余额度 \(credits)" }
        guard let quota = effectiveQuota() else {
            return "额度 --"
        }
        return "\(quota.kind.label)余额 \(quota.remainingPercent)%"
    }

    private var remainingCreditText: String? {
        QuotaCreditPresentation.text(local: snapshot?.quota, synced: syncedQuota)
    }

    private func detailLines() -> [String] {
        if let credits = remainingCreditText {
            return ["剩余额度：\(credits)", "周额度已用完，当前使用剩余额度"]
        }
        let quota = effectiveQuota()
        let label = quota.map { "\($0.kind.label)余额" } ?? "额度"
        let percentText = quota.map { "\($0.remainingPercent)%" } ?? "--"
        let secondaryLine = effectiveQuotaWindows().dropFirst().first.map {
            "同时有\($0.kind.label)余额：\($0.remainingPercent)%"
        }
        guard let resetsAt = quota?.resetsAt else {
            return [
                "\(label)：\(percentText)",
                secondaryLine,
                "距离刷新：暂无数据",
                "刷新时间：暂无数据"
            ].compactMap { $0 }
        }

        return [
            "\(label)：\(percentText)",
            secondaryLine,
            "距离刷新：\(QuotaDisplayFormatter.refreshCountdownText(until: resetsAt))",
            "刷新时间：\(QuotaDisplayFormatter.absoluteDateTimeText(resetsAt))"
        ].compactMap { $0 }
    }

    private func quotaWindows(from snapshot: StateSnapshot?) -> [CodexQuotaWindow] {
        guard let quota = snapshot?.quota,
              quota.limitID == CodexSessionQuotaCollector.primaryLimitID else { return [] }
        return quota.availableWindows
    }

    private func effectiveQuota() -> CodexQuotaWindow? {
        effectiveQuotaWindows().first
    }

    private func effectiveQuotaWindows() -> [CodexQuotaWindow] {
        if let syncedQuota { return syncedQuota.availableWindows }
        return quotaWindows(from: snapshot)
    }

    private func refreshQuotaPresentation() {
        quotaRemainingPercent = remainingCreditText != nil ? nil : effectiveQuota()?.remainingPercent
        updateQuotaIndicator()
        item.button?.title = statusBarText()
        item.button?.toolTip = detailLines().joined(separator: "\n")
    }

    private func updateQuotaIndicator() {
        if remainingCreditText != nil {
            item.button?.image = makeCreditIndicator()
            return
        }
        guard let percent = quotaRemainingPercent else {
            item.button?.image = makeQuotaIndicator(color: .systemGray, glow: 0.15)
            return
        }

        if percent <= 10 {
            item.button?.image = makeQuotaIndicator(color: .systemRed, glow: 0.72)
            return
        }

        item.button?.image = makeQuotaIndicator(
            color: healthyGreen,
            glow: 0.82,
            coreTop: healthyGreenTop,
            coreBottom: healthyGreenBottom,
            rim: healthyGreenRim,
            haloProgress: 0.35
        )
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            onPopoverOpen?()
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

    private func openBureau() {
        guard var bureauURL = teamWebsiteURL else { return }
        bureauURL.append(path: "bureau")
        NSWorkspace.shared.open(bureauURL)
        popover.performClose(nil)
    }

    private func selectRankingRange(_ range: StatusRankingRange) {
        setRankingRange(range, isLoading: true)
        delegate?.statusBarDidSelectRankingRange(range)
    }

    private func makeCreditIndicator() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }
        let points = (0..<10).map { index -> NSPoint in
            let angle = CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 5
            let radius: CGFloat = index.isMultiple(of: 2) ? 1 : 0.60
            return NSPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let star = NSBezierPath()
        for (index, point) in points.enumerated() {
            let point = NSPoint(x: 0.6 + (point.x - minX) / (maxX - minX) * 16.8,
                                y: 0.6 + (point.y - minY) / (maxY - minY) * 16.8)
            if index == 0 { star.move(to: point) } else { star.line(to: point) }
        }
        star.close()
        NSGradient(starting: NSColor(srgbRed: 0.96, green: 0.67, blue: 0.06, alpha: 1),
                   ending: NSColor(srgbRed: 1, green: 0.88, blue: 0.34, alpha: 1))?.draw(in: star, angle: 90)
        NSColor(srgbRed: 0.88, green: 0.58, blue: 0.04, alpha: 1).setStroke()
        star.lineWidth = 0.8
        star.lineJoinStyle = .round
        star.stroke()
        image.isTemplate = false
        return image
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
            haloDiameter = 13.6 + (4.4 * eased)
            haloAlpha = 0.66 * (1 - pow(haloProgress, 2.15))
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
        color.withAlphaComponent(haloAlpha * 0.48).setFill()
        NSBezierPath(ovalIn: haloRect).fill()

        color.withAlphaComponent(haloAlpha).setStroke()
        let haloRing = NSBezierPath(ovalIn: haloRect.insetBy(dx: 0.6, dy: 0.6))
        haloRing.lineWidth = 1.55
        haloRing.stroke()

        let softGlowRect = NSRect(x: 2.45, y: 2.45, width: 13.1, height: 13.1)
        color.withAlphaComponent(0.46 * glow).setFill()
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
