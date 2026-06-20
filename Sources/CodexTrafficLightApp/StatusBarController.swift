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
        menu.addItem(quotaDetailMenuItem(for: quota))
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
        return ([base, "额度：\(quotaText(for: quota))"] + quotaDetailLines(for: quota)).joined(separator: "\n")
    }

    private func quotaText(for quota: QuotaSnapshot?) -> String {
        guard let quota else { return "暂无数据" }
        return priorityQuotaText(for: quota, compact: false)
    }

    private func statusBarQuotaText(for quota: QuotaSnapshot?) -> String {
        guard let quota else { return " 5h -- · 1周 --" }
        return " \(priorityQuotaText(for: quota, compact: true))"
    }

    private func priorityQuotaText(for quota: QuotaSnapshot, compact: Bool) -> String {
        if quota.weeklyRemainingPercent <= 0 {
            return resetQuotaText(
                label: "1周",
                resetsAt: quota.weeklyResetsAt,
                fallback: "等待周额度恢复",
                unitStyle: .daysAndHours
            )
        }
        if quota.fiveHourRemainingPercent <= 0 {
            return resetQuotaText(
                label: compact ? "5h" : "5小时",
                resetsAt: quota.fiveHourResetsAt,
                fallback: compact ? "等待5h恢复" : "等待5小时额度恢复",
                unitStyle: .hoursAndMinutes
            )
        }
        return compact
            ? "5h \(quota.fiveHourRemainingPercent)% · 1周 \(quota.weeklyRemainingPercent)%"
            : "5小时 \(quota.fiveHourRemainingPercent)% · 1周 \(quota.weeklyRemainingPercent)%"
    }

    private enum ResetUnitStyle {
        case hoursAndMinutes
        case daysAndHours
    }

    private func resetQuotaText(label: String, resetsAt: Date?, fallback: String, unitStyle: ResetUnitStyle) -> String {
        guard let resetsAt else { return fallback }
        return "\(label) \(relativeResetText(until: resetsAt, unitStyle: unitStyle))"
    }

    private func relativeResetText(until resetsAt: Date, now: Date = Date(), unitStyle: ResetUnitStyle) -> String {
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now).rounded(.up)))
        if seconds <= 0 {
            return "即将恢复"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        switch unitStyle {
        case .daysAndHours:
            return "还有\(days)天\(hours)小时"
        case .hoursAndMinutes:
            let totalHours = seconds / 3_600
            if totalHours > 0 {
                return "还有\(totalHours)小时\(minutes)分"
            }
            return "还有\(hours)小时\(minutes)分"
        }
    }

    private func quotaDetailLines(for quota: QuotaSnapshot?) -> [String] {
        guard let quota else { return ["5小时：暂无恢复时间", "1周：暂无恢复时间"] }
        return [
            quotaDetailLine(
                label: "5小时",
                displayLabel: "5小时",
                percent: quota.fiveHourRemainingPercent,
                resetsAt: quota.fiveHourResetsAt,
                unitStyle: .hoursAndMinutes
            ),
            quotaDetailLine(
                label: "1周",
                displayLabel: "1周　",
                percent: quota.weeklyRemainingPercent,
                resetsAt: quota.weeklyResetsAt,
                unitStyle: .daysAndHours
            )
        ]
    }

    private func quotaDetailLine(label: String, displayLabel: String, percent: Int, resetsAt: Date?, unitStyle: ResetUnitStyle) -> String {
        guard let resetsAt else {
            return "\(label)：\(percent)% · 未返回恢复时间"
        }
        let percentText = String(format: "%3d%%", percent)
        return "\(displayLabel)  \(percentText)  \(absoluteDateTimeText(resetsAt))  \(relativeResetText(until: resetsAt, unitStyle: unitStyle))"
    }

    private func absoluteDateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM月dd日 HH:mm"
        return formatter.string(from: date)
    }

    private func quotaDetailMenuItem(for quota: QuotaSnapshot?) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = QuotaDetailMenuView(rows: quotaRows(for: quota))
        return item
    }

    private func quotaRows(for quota: QuotaSnapshot?) -> [QuotaDetailRow] {
        guard let quota else {
            return [
                QuotaDetailRow(label: "5小时", percent: "--", resetTime: "--", remaining: "暂无数据"),
                QuotaDetailRow(label: "1周", percent: "--", resetTime: "--", remaining: "暂无数据")
            ]
        }
        return [
            quotaRow(
                label: "5小时",
                percent: quota.fiveHourRemainingPercent,
                resetsAt: quota.fiveHourResetsAt,
                unitStyle: .hoursAndMinutes
            ),
            quotaRow(
                label: "1周",
                percent: quota.weeklyRemainingPercent,
                resetsAt: quota.weeklyResetsAt,
                unitStyle: .daysAndHours
            )
        ]
    }

    private func quotaRow(label: String, percent: Int, resetsAt: Date?, unitStyle: ResetUnitStyle) -> QuotaDetailRow {
        guard let resetsAt else {
            return QuotaDetailRow(label: label, percent: "\(percent)%", resetTime: "--", remaining: "未返回时间")
        }
        return QuotaDetailRow(
            label: label,
            percent: "\(percent)%",
            resetTime: absoluteDateTimeText(resetsAt),
            remaining: relativeResetText(until: resetsAt, unitStyle: unitStyle)
        )
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

private struct QuotaDetailRow {
    let label: String
    let percent: String
    let resetTime: String
    let remaining: String
}

private final class QuotaDetailMenuView: NSView {
    private let rows: [QuotaDetailRow]

    init(rows: [QuotaDetailRow]) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: 372, height: 96))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let card = bounds.insetBy(dx: 10, dy: 8)
        let path = NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        drawHeader(in: card)
        drawSeparator(in: card, y: card.maxY - 30)

        for (index, row) in rows.prefix(2).enumerated() {
            draw(row: row, index: index, in: card)
        }
    }

    private func drawHeader(in card: NSRect) {
        let y = card.maxY - 24
        drawText("窗口", in: NSRect(x: card.minX + 4, y: y, width: 50, height: 16), attributes: headerAttributes(alignment: .center))
        drawText("剩余", in: percentColumn(in: card, y: y, height: 16), attributes: headerAttributes(alignment: .center))
        drawText("恢复时间", in: resetColumn(in: card, y: y, height: 16), attributes: headerAttributes(alignment: .center))
        drawText("倒计时", in: remainingColumn(in: card, y: y, height: 16), attributes: headerAttributes(alignment: .center))
    }

    private func draw(row: QuotaDetailRow, index: Int, in card: NSRect) {
        let y = card.maxY - 53 - CGFloat(index * 25)
        if index == 1 {
            drawSeparator(in: card, y: y + 21)
        }
        drawText(row.label, in: labelColumn(in: card, y: y, height: 18), attributes: bodyAttributes(weight: .semibold, alignment: .left))
        drawText(row.percent, in: percentColumn(in: card, y: y, height: 18), attributes: monoAttributes(alignment: .center))
        drawText(row.resetTime, in: resetColumn(in: card, y: y, height: 18), attributes: monoAttributes(alignment: .left))
        drawText(row.remaining, in: remainingColumn(in: card, y: y, height: 18), attributes: bodyAttributes(weight: .regular, alignment: .left))
    }

    private func labelColumn(in card: NSRect, y: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: card.minX + 14, y: y, width: 50, height: height)
    }

    private func percentColumn(in card: NSRect, y: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: card.minX + 70, y: y, width: 42, height: height)
    }

    private func resetColumn(in card: NSRect, y: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: card.minX + 124, y: y, width: 112, height: height)
    }

    private func remainingColumn(in card: NSRect, y: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: card.minX + 246, y: y, width: 96, height: height)
    }

    private func drawSeparator(in card: NSRect, y: CGFloat) {
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: card.minX + 10, y: y))
        path.line(to: NSPoint(x: card.maxX - 10, y: y))
        path.lineWidth = 1
        path.stroke()
    }

    private func drawText(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        text.draw(in: rect, withAttributes: attributes)
    }

    private func headerAttributes(alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        textAttributes(
            font: NSFont.systemFont(ofSize: 11, weight: .medium),
            color: NSColor.secondaryLabelColor,
            alignment: alignment
        )
    }

    private func bodyAttributes(weight: NSFont.Weight, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        textAttributes(
            font: NSFont.systemFont(ofSize: 12.5, weight: weight),
            color: NSColor.labelColor,
            alignment: alignment
        )
    }

    private func monoAttributes(alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        textAttributes(
            font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
            color: NSColor.labelColor,
            alignment: alignment
        )
    }

    private func textAttributes(font: NSFont, color: NSColor, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: font,
            .foregroundColor: color,
            .kern: 0,
            .paragraphStyle: paragraph
        ]
    }
}
