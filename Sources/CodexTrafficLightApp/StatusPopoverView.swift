import AppKit
import SwiftUI
import CodexTrafficLightCore

enum StatusRankingRange: String, CaseIterable, Equatable, Hashable, Sendable {
    case today
    case week
    case month

    var shortLabel: String {
        switch self {
        case .today: return "实时"
        case .week: return "周"
        case .month: return "月"
        }
    }

    var heading: String {
        switch self {
        case .today: return "今日团队活跃"
        case .week: return "本周团队活跃"
        case .month: return "本月团队活跃"
        }
    }

    var emptyUsageText: String {
        switch self {
        case .today: return "今日暂无使用"
        case .week: return "本周暂无使用"
        case .month: return "本月暂无使用"
        }
    }
}

@MainActor
final class StatusPopoverModel: ObservableObject {
    @Published var snapshot: StateSnapshot?
    @Published var inspirationUnreadCount = 0
    @Published var ranking: TeamRankingSnapshot?
    @Published var highlights: [String: MemberHighlight] = [:]
    @Published var syncedQuota: TeamQuotaReport?
    @Published var isBalanceVisible = false
    @Published var balanceGlowStartedAt: Date?
    @Published var claudeQuota: Sub2APIQuotaState?
    @Published var isRefreshingClaude = false
    @Published var claudeRefreshFailed = false
    @Published var syncDetail: String = "正在读取团队数据…"
    @Published var websiteURL: URL?
    @Published var selectedRange: StatusRankingRange = .today
    @Published var isRangeLoading = false
}

struct StatusPopoverView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: StatusPopoverModel
    let openWebsite: (String?) -> Void
    let selectRange: (StatusRankingRange) -> Void
    let openGuide: () -> Void
    let openBureau: () -> Void
    let refreshClaude: () -> Void
    let quit: () -> Void

    private let balanceGlowDuration: TimeInterval = 2
    private let canvas = Color(red: 0.985, green: 0.982, blue: 0.974)
    private let card = Color.white
    private let ink = Color(red: 0.10, green: 0.105, blue: 0.10)
    private let muted = Color(red: 0.43, green: 0.44, blue: 0.42)
    private let line = Color(red: 0.90, green: 0.90, blue: 0.87)
    private let green = Color(red: 0.25, green: 0.52, blue: 0.35)
    private let dayTint = Color(red: 0.985, green: 0.945, blue: 0.84)
    private let dayInk = Color(red: 0.64, green: 0.39, blue: 0.08)
    private let nightTint = Color(red: 0.90, green: 0.92, blue: 0.965)
    private let nightInk = Color(red: 0.16, green: 0.28, blue: 0.48)
    private let roster: [TeamRoster.Entry] = [
        ("zlu", "张璐", "58.png"),
        ("qiubo", "仇博", "193.png"),
        ("yangang", "杨昂", "101.png"),
        ("yangke", "杨珂", "codex-01.png"),
        ("liguoqing", "李国庆", "168.png"),
        ("mameng", "马猛", "codex-06.png"),
        ("zhanghaiqiang", "张海强", "codex-07.png"),
        ("huangning", "黄宁", "199.png"),
        ("qiaoyue", "乔月", "201.png"),
        ("lyf", "李阳峰", "169.png")
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isBalanceVisible {
                quotaCard
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    rankingSection
                    versionNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            footer
        }
        .frame(width: 456, height: 640)
        .background(canvas)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let logo = Self.brandLogo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(green)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(green.opacity(0.13))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(green.opacity(0.12), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text("万合创新局")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Text(BrandCopy.tagline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(muted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.isBalanceVisible.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard")
                    Text(model.isBalanceVisible ? "收起余额" : "查看余额")
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(green)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(green.opacity(0.09), in: Capsule())
                .overlay {
                    if !reduceMotion, let start = model.balanceGlowStartedAt {
                        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                            balanceGlow(elapsed: context.date.timeIntervalSince(start))
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 96)
        .background(card)
        .overlay(alignment: .bottom) { line.frame(height: 1) }
    }

    private func balanceGlow(elapsed: TimeInterval) -> some View {
        let phase = elapsed.truncatingRemainder(dividingBy: balanceGlowDuration) / balanceGlowDuration
        let angle = Angle.degrees(phase * 360 - 90)
        return Capsule().strokeBorder(
            AngularGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.72),
                    .init(color: green.opacity(0.34), location: 0.84),
                    .init(color: green.opacity(0.54), location: 0.92),
                    .init(color: .clear, location: 1)
                ],
                center: .center,
                startAngle: angle,
                endAngle: angle + .degrees(360)
            ),
            lineWidth: 1.25
        )
    }

    private var quotaCard: some View {
        VStack(spacing: 10) {
            codexWeeklyQuota
            if let state = model.claudeQuota {
                line.frame(height: 1)
                claudeQuotaRow(state)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 17)
        .background(green.opacity(0.025), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(line, lineWidth: 1))
    }

    private var codexWeeklyQuota: some View {
        let weekly = quotaWindows.first { $0.kind == .weekly }
        let credits = QuotaCreditPresentation.text(local: model.snapshot?.quota, synced: model.syncedQuota)
        let reset = credits == nil ? weekly?.resetsAt
            : (model.syncedQuota?.weeklyResetsAtDate ?? model.snapshot?.quota?.weeklyResetsAt)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(credits == nil ? "Codex 周额度" : "Codex 余额")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(muted)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(credits ?? weekly.map { "\($0.remainingPercent)%" } ?? "—")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ink)
                    if credits == nil, weekly != nil {
                        Text("剩余")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(muted)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if let reset {
                    Text(QuotaDisplayFormatter.refreshCountdownText(until: reset))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                    Text(QuotaDisplayFormatter.weeklyResetText(reset))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(green)
                        .help(QuotaDisplayFormatter.absoluteDateTimeText(reset, timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!))
                } else if weekly == nil, credits == nil {
                    Text("等待同步")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(muted)
                }
            }
        }
        .lineLimit(1)
    }

    private func claudeQuotaRow(_ state: Sub2APIQuotaState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Claude")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ink)
                    .accessibilityLabel("Claude 订阅额度")
                Spacer(minLength: 0)
                switch state {
                case .loading: Text("读取中…")
                case .unavailable: Text("暂时读不到额度")
                case .sample: EmptyView()
                }
                claudeRefreshButton
            }
            if case let .sample(quota) = state {
                HStack(alignment: .center, spacing: 4) {
                    claudeWindow("5 小时", quota.fiveHour, sampledAt: quota.updatedAt)
                    claudeWindowSeparator
                    claudeWindow("Fable 周额度", quota.sevenDayFable, sampledAt: quota.updatedAt, weekly: true)
                    claudeWindowSeparator
                    claudeWindow("周额度", quota.sevenDay, sampledAt: quota.updatedAt, weekly: true)
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(muted)
        .lineLimit(1)
    }

    private var claudeRefreshButton: some View {
        Button(action: refreshClaude) {
            Group {
                if model.isRefreshingClaude {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.claudeRefreshFailed ? dayInk : green)
                }
            }
            .frame(width: 32, height: 24)
            .background(green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isRefreshingClaude)
        .accessibilityLabel("刷新 Claude 额度")
        .help(model.claudeRefreshFailed ? "刷新失败，点击重试" : "刷新 Claude 额度")
    }

    private func claudeWindow(_ label: String, _ window: Sub2APIQuota.Window?, sampledAt: String?, weekly: Bool = false) -> some View {
        let remaining = window?.remaining
        let value = remaining.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—"
        let reset = remaining == nil ? nil : window?.reset
        let detail = reset.map { "剩余 \(value) · \(QuotaDisplayFormatter.absoluteDateTimeText($0)) 刷新" }
            ?? "等待 Claude 额度同步"
        let sample = Sub2APIQuota.date(sampledAt).map { "\n采样于 \(QuotaDisplayFormatter.absoluteDateTimeText($0))" } ?? ""
        let refresh = reset.map { date in
            let countdown = QuotaDisplayFormatter.refreshCountdownText(until: date)
            let time = QuotaDisplayFormatter.weeklyResetText(date)
            return countdown + " · " + (weekly ? time : String(time.suffix(5)))
        }
        return VStack(spacing: 3) {
            Text(label)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(ink)
            Text(refresh ?? "待同步")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(refresh == nil ? muted : green)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .help(detail + sample)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label, value, refresh ?? "待同步"].joined(separator: "，"))
    }

    private var claudeWindowSeparator: some View {
        Rectangle().fill(line).frame(width: 1, height: 42).accessibilityHidden(true)
    }

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.selectedRange.heading)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Spacer()
                rangeSwitch
            }

            VStack(spacing: 0) {
                rankingRows
            }
            .background(card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(line, lineWidth: 1))
        }
    }

    private var rangeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(StatusRankingRange.allCases, id: \.rawValue) { range in
                Button {
                    guard range != model.selectedRange else { return }
                    selectRange(range)
                } label: {
                    Text(range.shortLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(range == model.selectedRange ? green : muted)
                        .padding(.horizontal, range == .today ? 9 : 8)
                        .padding(.vertical, 4)
                        .background(
                            range == model.selectedRange ? green.opacity(0.09) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换到\(range.heading)")
                .accessibilityAddTraits(range == model.selectedRange ? .isSelected : [])
            }
        }
        .padding(2)
        .background(line.opacity(0.42), in: Capsule())
        .opacity(model.isRangeLoading ? 0.72 : 1)
        .animation(.easeOut(duration: 0.16), value: model.selectedRange)
    }

    @ViewBuilder
    private var rankingRows: some View {
        let members = rankedMembers
        if model.ranking == nil || members.isEmpty {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.syncDetail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(muted)
                Spacer()
            }
            .padding(18)
        } else {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                memberRow(member)
                if index < members.count - 1 {
                    line.frame(height: 1)
                }
            }
        }
    }

    private func memberRow(_ member: TeamRankingMember) -> some View {
        Button { openWebsite(member.id) } label: {
            HStack(alignment: .center, spacing: 10) {
                avatar(member)
                if member.hasEverJoined {
                    joinedMemberDetails(member)
                } else {
                    HStack(spacing: 10) {
                        Text(displayName(member))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                        Text("众神未归位")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(muted)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func joinedMemberDetails(_ member: TeamRankingMember) -> some View {
        let online = member.online == true
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(displayName(member))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                onlineStatusDot(
                    isOnline: online,
                    hasActivity: online || member.tokens > 0 || member.sessions > 0
                )
                Text(memberActiveText(member))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatTokens(member.tokens))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("Token")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(muted)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            memberQuotaProgress(member)
            grindActivityBand(member)
        }
        .frame(maxWidth: .infinity)
    }

    private func onlineStatusDot(isOnline: Bool, hasActivity: Bool) -> some View {
        ZStack {
            Circle()
                .fill(hasActivity ? green : muted.opacity(0.45))
                .frame(width: 7, height: 7)
                .shadow(color: isOnline ? green.opacity(0.72) : .clear, radius: 3.2)
        }
        .frame(width: 8, height: 8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func avatar(_ member: TeamRankingMember) -> some View {
        VStack(spacing: -6) {
            ZStack {
                Circle().fill(green.opacity(0.11))
                if let image = localAvatar(member) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let url = avatarURL(member) {
                    PersistentAvatarImage(url: url, fallbackText: String(displayName(member).prefix(1)))
                        .id(url.absoluteString)
                        .foregroundStyle(ink)
                } else {
                    Text(String(displayName(member).prefix(1)))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ink)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())

            if let highlight = model.highlights[member.id] {
                let colors = highlightColors(highlight.kind)
                Text(highlight.label)
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(colors.ink)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: 62, minHeight: 17)
                    .background(colors.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(colors.border, lineWidth: 1))
                    .help(highlight.reason)
            }
        }
        .frame(width: 62)
    }

    private func highlightColors(_ kind: String) -> (ink: Color, fill: Color, border: Color) {
        switch kind {
        case "lead": return (Color(red: 0.61, green: 0.29, blue: 0.11), Color(red: 1, green: 0.87, blue: 0.73), Color(red: 0.90, green: 0.68, blue: 0.49))
        case "quota": return (Color(red: 0.25, green: 0.44, blue: 0.30), Color(red: 0.88, green: 0.94, blue: 0.85), Color(red: 0.66, green: 0.77, blue: 0.60))
        case "late": return (Color(red: 0.38, green: 0.40, blue: 0.55), Color(red: 0.91, green: 0.90, blue: 0.96), Color(red: 0.73, green: 0.72, blue: 0.84))
        default: return (Color(red: 0.47, green: 0.32, blue: 0.10), Color(red: 1, green: 0.91, blue: 0.63), Color(red: 0.86, green: 0.73, blue: 0.38))
        }
    }

    private var versionNote: some View {
        HStack(spacing: 9) {
            Text("已更新 \(ClientVersion.current.split(separator: ".").last ?? "0") 次")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(muted.opacity(0.78))
                .fixedSize()
            Circle()
                .fill(line)
                .frame(width: 3, height: 3)
            Button(action: openGuide) {
                Label("使用说明", systemImage: "book.closed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(green)
            }
            .buttonStyle(.plain)
            .disabled(model.websiteURL == nil)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { openWebsite(nil) } label: {
                footerLabel("排行榜网站", icon: "safari")
            }
            .disabled(model.websiteURL == nil)

            Link(destination: shareURL("inspiration")) {
                footerLabel("手搓分享", icon: "lightbulb")
            }
            .disabled(model.websiteURL == nil)
            .overlay(alignment: .topTrailing) {
                if model.inspirationUnreadCount > 0 {
                    Text(model.inspirationUnreadCount > 99 ? "99+" : "\(model.inspirationUnreadCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color(red: 1, green: 0.23, blue: 0.19), in: Circle())
                        .offset(x: 5, y: -7)
                        .accessibilityLabel("\(model.inspirationUnreadCount) 篇未查看手搓分享")
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(card)
        .overlay(alignment: .top) { line.frame(height: 1) }
    }

    private func shareURL(_ path: String) -> URL {
        (model.websiteURL ?? URL(string: "https://c.wanhe.cn")!).appendingPathComponent(path)
    }

    private func footerLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(green)
            .background(green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(green.opacity(0.14), lineWidth: 1)
            }
    }

    private var rankedMembers: [TeamRankingMember] {
        TeamRoster.merge(model.ranking?.members ?? [], roster: roster)
    }

    private func displayName(_ member: TeamRankingMember) -> String {
        let serverName = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverName.isEmpty { return serverName }
        return TeamRoster.entry(for: member.id, in: roster)?.name ?? member.id
    }

    private func memberActiveText(_ member: TeamRankingMember) -> String {
        if member.tokens <= 0 && member.sessions <= 0 {
            return member.hasEverJoined ? model.selectedRange.emptyUsageText : "还未加入"
        }
        if let lastActive = validLastActive(member) {
            return member.online == true ? "开搓中" : "最后 \(lastActive)"
        }
        return officialDate(member)
    }

    private func validLastActive(_ member: TeamRankingMember) -> String? {
        guard let lastActive = member.lastActive, !lastActive.isEmpty, lastActive != "-" else { return nil }
        return lastActive
    }

    private func memberQuotaProgress(_ member: TeamRankingMember) -> some View {
        HStack(spacing: 7) {
            if let quota = member.weeklyQuota?.preferredWindow {
                let credits = QuotaCreditPresentation.text(local: nil, synced: member.weeklyQuota)
                Text(credits.map { "剩余额度 \($0)" } ?? "\(quota.kind.label)余额 \(quota.remainingPercent)%")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(green)
                    .fixedSize(horizontal: true, vertical: false)
                if credits == nil {
                    ProgressView(value: Double(quota.remainingPercent) / 100)
                        .progressViewStyle(.linear)
                        .tint(green)
                        .frame(width: 54)
                }
                Text(memberQuotaResetText(credits != nil ? member.weeklyQuota?.weeklyResetsAtDate : quota.resetsAt))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("额度待同步 · 刷新待更新")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(muted)
            }
            let extraTools: [String] = {
                var set = Set((member.tools ?? []).filter { $0 != "codex" })
                for key in (member.toolQuotas ?? [:]).keys where key != "codex" { set.insert(key) }
                return set.sorted { lhs, rhs in
                    let lTok = member.toolTokens?[lhs] ?? 0
                    let rTok = member.toolTokens?[rhs] ?? 0
                    if lTok != rTok { return lTok > rTok }
                    return lhs < rhs
                }
            }()
            ForEach(extraTools.prefix(4), id: \.self) { tool in
                let name = ["claude": "Claude", "antigravity": "Antigravity", "muse": "Muse Code", "kimi": "Kimi", "gemini": "Gemini", "grok": "Grok", "grokbot": "Grok Bot"][tool] ?? tool
                let quota = member.toolQuotas?[tool]
                let usage = member.toolTokens?[tool].map { formatTokens($0).replacingOccurrences(of: "万", with: " 万").replacingOccurrences(of: "亿", with: " 亿") + " Token" }
                let helpText: String = {
                    var parts = [name]
                    if let q = quota { parts.append("剩余 \(Int(q.remainingPercent.rounded()))%") }
                    if let u = usage { parts.append(u) }
                    return parts.joined(separator: " · ")
                }()
                let ringFraction = quota.map { max(0, min(1, $0.remainingPercent / 100)) }
                let ringColor: Color = {
                    guard let pct = quota?.remainingPercent else { return Color.gray.opacity(0.28) }
                    if pct <= 5 { return Color(red: 0.86, green: 0.15, blue: 0.15) }
                    if pct <= 20 { return Color(red: 0.85, green: 0.47, blue: 0.02) }
                    return Color(red: 0.23, green: 0.43, blue: 0.96)
                }()
                ZStack {
                    Circle().stroke(Color.gray.opacity(0.24), lineWidth: 1.8)
                    if let fraction = ringFraction {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(ringColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    toolBrandGlyph(tool)
                }
                .frame(width: 18, height: 18)
                .help(helpText)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func toolBrandGlyph(_ tool: String) -> some View {
        switch tool {
        case "antigravity":
            Text("A")
                .font(.system(size: 9.5, weight: .black, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.13, green: 0.77, blue: 0.37), Color(red: 0.94, green: 0.27, blue: 0.27)], startPoint: .bottomLeading, endPoint: .topTrailing))
        case "claude":
            Image(systemName: "sun.max.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
        case "gemini":
            Image(systemName: "sparkle")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color(red: 0.31, green: 0.27, blue: 0.90))
        case "grok", "grokbot":
            Image(systemName: "circle.slash")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.8))
        case "kimi":
            Text("K")
                .font(.system(size: 9.5, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.11, green: 0.31, blue: 0.85))
        case "muse":
            Text("M")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.49, green: 0.23, blue: 0.93))
        default:
            Text(String(tool.prefix(1)).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.75))
        }
    }

    private func grindActivityBand(_ member: TeamRankingMember) -> some View {
        ZStack {
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                let middle = width / 2
                let slant: CGFloat = 7
                let seam: CGFloat = 1.25

                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: middle + slant - seam, y: 0))
                    path.addLine(to: CGPoint(x: middle - slant - seam, y: height))
                    path.addLine(to: CGPoint(x: 0, y: height))
                    path.closeSubpath()
                }
                .fill(dayTint)

                Path { path in
                    path.move(to: CGPoint(x: middle + slant + seam, y: 0))
                    path.addLine(to: CGPoint(x: width, y: 0))
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.addLine(to: CGPoint(x: middle - slant + seam, y: height))
                    path.closeSubpath()
                }
                .fill(nightTint)
            }

            HStack(spacing: 0) {
                grindBandSegment(
                    icon: "sun.max.fill",
                    text: GrindDisplayFormatter.start(member.dayGrindTime),
                    foreground: dayInk
                )
                grindBandSegment(
                    icon: "moon.fill",
                    text: GrindDisplayFormatter.status(lastMessageAt: member.lastMessageAt, previousFinish: member.nightGrindTime),
                    foreground: nightInk
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 25)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(line.opacity(0.55), lineWidth: 0.5))
    }

    private func grindBandSegment(icon: String, text: String, foreground: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3.5)
    }

    private func memberQuotaResetText(_ date: Date?) -> String {
        guard let date else { return "刷新时间待更新" }
        return QuotaDisplayFormatter.refreshCountdownText(until: date)
    }

    private func localAvatar(_ member: TeamRankingMember) -> NSImage? {
        let serverFilename = member.avatar?.split(separator: "/").last.map(String.init)
        guard let filename = serverFilename ?? TeamRoster.entry(for: member.id, in: roster)?.avatar else { return nil }
        return BundledAvatarStore.image(for: filename)
    }

    // Ranking refreshes redraw the view, so decode this local asset once per process.
    private static let brandLogo: NSImage? = {
        let url = Bundle.module.url(forResource: "wanhe-app-icon-96", withExtension: "png", subdirectory: "Brand")
            ?? Bundle.module.url(forResource: "wanhe-app-icon-96", withExtension: "png")
        return url.flatMap(NSImage.init(contentsOf:))
    }()

    private var quotaWindows: [CodexQuotaWindow] {
        if let quota = model.syncedQuota {
            return quota.availableWindows
        }
        guard let quota = model.snapshot?.quota,
              quota.limitID == CodexSessionQuotaCollector.primaryLimitID else { return [] }
        return quota.availableWindows
    }

    private var syncStatus: String {
        if model.ranking != nil { return model.syncDetail.isEmpty ? "已连接" : model.syncDetail }
        return "同步中"
    }

    private func officialDate(_ member: TeamRankingMember) -> String {
        if let day = member.officialUsage?.dataThrough {
            return "官方至 " + day.dropFirst(5).replacingOccurrences(of: "-", with: "/")
        }
        if let lastActive = member.lastActive, !lastActive.isEmpty, lastActive != "-" {
            return "更新至 \(lastActive)"
        }
        return member.tokens > 0 ? "今日已统计" : "今日暂无使用"
    }

    private func avatarURL(_ member: TeamRankingMember) -> URL? {
        guard var base = model.websiteURL else { return nil }
        if let path = member.avatar, path.hasPrefix("/") {
            base.append(path: String(path.dropFirst()))
            return base
        }
        let value = member.id.unicodeScalars.reduce(0) { (($0 << 5) - $0 + Int($1.value)) & 0x7fffffff }
        base.append(path: "avatars/codex-\(String(format: "%02d", value % 16 + 1)).png")
        return base
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 100_000_000 {
            return String(format: "%.2f亿", (Double(value) / 1_000_000).rounded() / 100)
        }
        if value >= 10_000 { return String(format: "%.2f万", (Double(value) / 100).rounded() / 100) }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
