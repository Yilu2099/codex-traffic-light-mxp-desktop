import AppKit
import SwiftUI
import CodexTrafficLightCore

@MainActor
final class StatusPopoverModel: ObservableObject {
    @Published var snapshot: StateSnapshot?
    @Published var ranking: TeamRankingSnapshot?
    @Published var syncedQuota: TeamQuotaReport?
    @Published var syncDetail: String = "正在读取团队数据…"
    @Published var websiteURL: URL?
}

struct StatusPopoverView: View {
    @ObservedObject var model: StatusPopoverModel
    let openWebsite: (String?) -> Void
    let openGuide: () -> Void
    let quit: () -> Void

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
    private let roster: [(id: String, name: String, avatar: String)] = [
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
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    quotaCard
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
        HStack(spacing: 10) {
            Group {
                if let logo = brandLogo {
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
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(green.opacity(0.12), lineWidth: 1))
            .shadow(color: green.opacity(0.16), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("万合创新局")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Text("Codex 团队活跃 · 用起来，更要做出结果")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(muted)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(green).frame(width: 7, height: 7)
                Text(syncStatus)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(green)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(green.opacity(0.09), in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(card)
        .overlay(alignment: .bottom) { line.frame(height: 1) }
    }

    private var quotaCard: some View {
        let quota = weeklyQuota
        let remaining = quota?.remainingPercent
        let used = Double(100 - (remaining ?? 0)) / 100
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("个人周余额", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(muted)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(remaining.map(String.init) ?? "--")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                        Text("% 剩余")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("下次刷新")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(muted)
                    Text(resetRelativeText)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ink)
                    Text(resetAbsoluteText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(muted)
                }
            }
            ProgressView(value: max(0, min(1, used)))
                .tint(green)
                .scaleEffect(x: 1, y: 1.25, anchor: .center)
            Text("已用 \(remaining.map { 100 - $0 } ?? 0)%")
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(muted)
        }
        .padding(14)
        .background(green.opacity(0.025), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(line, lineWidth: 1))
    }

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日团队活跃")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Spacer()
                Text("实时")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(green.opacity(0.08), in: Capsule())
            }

            VStack(spacing: 0) {
                let members = rankedMembers
                if model.ranking == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.syncDetail)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(muted)
                        Spacer()
                    }
                    .padding(18)
                } else if !members.isEmpty {
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                        memberRow(member)
                        if index < members.count - 1 { line.frame(height: 1) }
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.syncDetail)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(muted)
                        Spacer()
                    }
                    .padding(18)
                }
            }
            .background(card, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(line, lineWidth: 1))
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
            .padding(.vertical, member.hasEverJoined ? 9 : 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func joinedMemberDetails(_ member: TeamRankingMember) -> some View {
        let online = validLastActive(member).map { isOnline($0) } ?? false
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(displayName(member))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                onlineStatusDot(
                    isOnline: online,
                    hasActivity: member.tokens > 0 || member.sessions > 0
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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isOnline)) { context in
            let duration = 1.8
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
            ZStack {
                if isOnline {
                    Circle()
                        .stroke(green.opacity(0.46 * (1 - phase)), lineWidth: 1.25)
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.7 + 2.5 * phase)
                }
                Circle()
                    .fill(hasActivity ? green : muted.opacity(0.45))
                    .frame(width: 5, height: 5)
            }
            .frame(width: 5, height: 5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func avatar(_ member: TeamRankingMember) -> some View {
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
    }

    private var versionNote: some View {
        HStack(spacing: 9) {
            Text("v\(ClientVersion.current)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(muted.opacity(0.78))
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
        HStack(spacing: 10) {
            Button { openWebsite(nil) } label: {
                Label("打开团队排行榜网站", systemImage: "safari")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .tint(green)
            .disabled(model.websiteURL == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(card)
        .overlay(alignment: .top) { line.frame(height: 1) }
    }

    private var rankedMembers: [TeamRankingMember] {
        let incoming = Dictionary(uniqueKeysWithValues: (model.ranking?.members ?? []).map { ($0.id.lowercased(), $0) })
        return roster.enumerated().map { index, entry in
            var member = incoming[entry.id] ?? TeamRankingMember(id: entry.id, name: entry.name)
            if member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                member.name = entry.name
            }
            if member.avatar?.isEmpty != false {
                member.avatar = "/avatars/\(entry.avatar)"
            }
            return (index, member)
        }
        .sorted { left, right in
            if left.1.hasEverJoined != right.1.hasEverJoined { return left.1.hasEverJoined }
            if left.1.tokens != right.1.tokens { return left.1.tokens > right.1.tokens }
            if left.1.sessions != right.1.sessions { return left.1.sessions > right.1.sessions }
            return left.0 < right.0
        }
        .map(\.1)
    }

    private func displayName(_ member: TeamRankingMember) -> String {
        let serverName = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverName.isEmpty { return serverName }
        return roster.first(where: { $0.id == member.id.lowercased() })?.name ?? member.id
    }

    private func memberActiveText(_ member: TeamRankingMember) -> String {
        if member.tokens <= 0 && member.sessions <= 0 {
            return member.hasEverJoined ? "今日暂无使用" : "还未加入"
        }
        if let lastActive = validLastActive(member) {
            return isOnline(lastActive) ? "在线" : "最后 \(lastActive)"
        }
        return officialDate(member)
    }

    private func isOnline(_ lastActive: String, now: Date = Date()) -> Bool {
        let parts = lastActive.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), (0 ... 23).contains(hour),
              let minute = Int(parts[1]), (0 ... 59).contains(minute)
        else { return false }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong") ?? .current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var activeAt = calendar.date(from: components) else { return false }
        if activeAt > now, let previousDay = calendar.date(byAdding: .day, value: -1, to: activeAt) {
            activeAt = previousDay
        }
        let elapsed = now.timeIntervalSince(activeAt)
        return elapsed >= 0 && elapsed <= 20 * 60
    }

    private func validLastActive(_ member: TeamRankingMember) -> String? {
        guard let lastActive = member.lastActive, !lastActive.isEmpty, lastActive != "-" else { return nil }
        return lastActive
    }

    private func memberQuotaProgress(_ member: TeamRankingMember) -> some View {
        HStack(spacing: 7) {
            if let quota = member.weeklyQuota {
                Text("周余额 \(quota.weeklyRemainingPercent)%")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(green)
                    .fixedSize(horizontal: true, vertical: false)
                ProgressView(value: Double(quota.weeklyRemainingPercent) / 100)
                    .progressViewStyle(.linear)
                    .tint(green)
                    .frame(width: 54)
                Text(memberQuotaResetText(quota.weeklyResetsAt))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("周余额待同步 · 刷新待更新")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(muted)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    text: "今日开工 \(member.dayGrindTime ?? "--")",
                    foreground: dayInk
                )
                grindBandSegment(
                    icon: "moon.fill",
                    text: "昨日收工 \(member.nightGrindTime ?? "--")",
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

    private func memberQuotaResetText(_ value: String?) -> String {
        guard let value else { return "刷新时间待更新" }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let relaxed = ISO8601DateFormatter()
        relaxed.formatOptions = [.withInternetDateTime]
        guard let date = precise.date(from: value) ?? relaxed.date(from: value) else {
            return "刷新时间待更新"
        }
        return QuotaDisplayFormatter.refreshCountdownText(until: date)
    }

    private func localAvatar(_ member: TeamRankingMember) -> NSImage? {
        let serverFilename = member.avatar?.split(separator: "/").last.map(String.init)
        guard let filename = serverFilename ?? roster.first(where: { $0.id == member.id.lowercased() })?.avatar else { return nil }
        return BundledAvatarStore.image(for: filename)
    }

    private var brandLogo: NSImage? {
        let url = Bundle.module.url(forResource: "wanhe-app-icon-192", withExtension: "png", subdirectory: "Brand")
            ?? Bundle.module.url(forResource: "wanhe-app-icon-192", withExtension: "png")
        return url.flatMap(NSImage.init(contentsOf:))
    }

    private var weeklyQuota: (remainingPercent: Int?, resetsAt: Date?)? {
        if let quota = model.syncedQuota {
            return (quota.weeklyRemainingPercent, quota.weeklyResetsAtDate)
        }
        guard let quota = model.snapshot?.quota else { return nil }
        return (quota.weeklyRemainingPercent, quota.weeklyResetsAt)
    }

    private var resetRelativeText: String {
        guard let date = weeklyQuota?.resetsAt else { return "暂无数据" }
        return QuotaDisplayFormatter.refreshCountdownText(until: date)
    }

    private var resetAbsoluteText: String {
        guard let date = weeklyQuota?.resetsAt else { return "—" }
        return QuotaDisplayFormatter.absoluteDateTimeText(date)
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
            return String(format: value >= 1_000_000_000 ? "%.1f亿" : "%.2f亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
