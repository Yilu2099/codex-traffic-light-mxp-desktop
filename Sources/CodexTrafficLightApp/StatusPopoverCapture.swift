import AppKit
import SwiftUI
import CodexTrafficLightCore

@MainActor
enum StatusPopoverCapture {
    static func writePreview(to url: URL) -> Bool {
        let now = Date()
        let model = StatusPopoverModel()
        model.snapshot = StateSnapshot(
            updatedAt: now,
            quota: QuotaSnapshot(
                fiveHourRemainingPercent: 82,
                fiveHourResetsAt: now.addingTimeInterval(3 * 3_600),
                primaryWindow: .fiveHour,
                source: "preview",
                updatedAt: now
            )
        )
        model.syncedQuota = TeamQuotaReport(
            weeklyRemainingPercent: 48,
            weeklyResetsAt: now.addingTimeInterval(4 * 86_400 + 12 * 3_600),
            fiveHourRemainingPercent: 82,
            fiveHourResetsAt: now.addingTimeInterval(3 * 3_600),
            primaryWindow: .fiveHour,
            updatedAt: now
        )
        let previewState = ProcessInfo.processInfo.environment["CODEX_LIGHT_CAPTURE_STATUS_STATE"]
        let previewRange = StatusRankingRange(
            rawValue: ProcessInfo.processInfo.environment["CODEX_LIGHT_CAPTURE_RANGE"] ?? "today"
        ) ?? .today
        let previewTokens: (zlu: Int, liguoqing: Int, qiaoyue: Int, huangning: Int, mameng: Int)
        switch previewRange {
        case .today:
            previewTokens = (583_000_000, 151_000_000, 125_000_000, 67_111_000, 38_217_000)
        case .week:
            previewTokens = (1_940_000_000, 528_000_000, 410_000_000, 255_000_000, 220_000_000)
        case .month:
            previewTokens = (6_840_000_000, 2_040_000_000, 1_350_000_000, 671_110_000, 666_760_000)
        }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        timeFormatter.dateFormat = "HH:mm"
        let recentActive = timeFormatter.string(from: now.addingTimeInterval(-5 * 60))
        let rankingJSON: String
        if previewState == "unjoined" {
            rankingJSON = """
            {"updatedAt":"2026-08-21 13:36","members":[
              {"id":"zlu","name":"张璐","avatar":"/avatars/58.png","tokens":1210000000,"sessions":12,"lastActive":"\(recentActive)","online":true,"grindDay":"2026-08-22","dayGrindTime":"09:42","nightGrindTime":"02:04","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T03:49:00Z","weeklyQuota":{"weeklyRemainingPercent":61,"weeklyUsedPercent":39,"weeklyResetsAt":"2026-08-26T03:33:00.000Z","updatedAt":"2026-08-22T03:49:00.000Z"}},
              {"id":"qiubo","name":"仇博","avatar":"/avatars/193.png","tokens":0,"sessions":0,"joined":false}
            ]}
            """
        } else {
            rankingJSON = """
            {"updatedAt":"2026-08-21 13:36","members":[
              {"id":"zlu","name":"张璐","avatar":"/avatars/58.png","tokens":\(previewTokens.zlu),"sessions":12,"lastActive":"\(recentActive)","online":true,"grindDay":"2026-08-22","dayGrindTime":"09:33","nightGrindTime":"02:04","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T03:49:00Z","membershipPlan":"pro","weeklyQuota":{"weeklyRemainingPercent":48,"weeklyUsedPercent":52,"weeklyResetsAt":"2026-08-27T03:33:00.000Z","primaryWindow":"weekly","updatedAt":"2026-08-22T03:49:00.000Z"}},
              {"id":"liguoqing","name":"李国庆","avatar":"/avatars/168.png","tokens":\(previewTokens.liguoqing),"sessions":9,"lastActive":"21:35","grindDay":"2026-08-22","dayGrindTime":"10:16","nightGrindTime":"02:03","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T03:10:00Z","weeklyQuota":{"weeklyRemainingPercent":17,"weeklyUsedPercent":83,"weeklyResetsAt":"2026-08-24T08:56:21.000Z","updatedAt":"2026-08-22T03:10:00.000Z"}},
              {"id":"qiaoyue","name":"乔月","avatar":"/avatars/201.png","tokens":\(previewTokens.qiaoyue),"sessions":7,"lastActive":"16:50","grindDay":"2026-08-22","dayGrindTime":"09:59","nightGrindTime":"03:08","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T02:35:00Z","membershipPlan":"plus","weeklyQuota":{"fiveHourRemainingPercent":82,"fiveHourUsedPercent":18,"fiveHourResetsAt":"2026-08-26T16:33:00.000Z","primaryWindow":"five_hour","updatedAt":"2026-08-22T02:35:00.000Z"}},
              {"id":"huangning","name":"黄宁","avatar":"/avatars/199.png","tokens":\(previewTokens.huangning),"sessions":5,"lastActive":"19:53","grindDay":"2026-08-22","dayGrindTime":"10:05","nightGrindTime":"02:11","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T02:10:00Z","weeklyQuota":{"weeklyRemainingPercent":58,"weeklyUsedPercent":42,"weeklyResetsAt":"2026-08-27T03:33:00.000Z","updatedAt":"2026-08-22T02:10:00.000Z"}},
              {"id":"mameng","name":"马猛","avatar":"/avatars/codex-06.png","tokens":\(previewTokens.mameng),"sessions":4,"lastActive":"20:42","grindDay":"2026-08-22","dayGrindTime":"11:02","nightGrindTime":"01:49","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T01:45:00Z","weeklyQuota":{"weeklyRemainingPercent":35,"weeklyUsedPercent":65,"weeklyResetsAt":"2026-08-26T03:33:00.000Z","updatedAt":"2026-08-22T01:45:00.000Z"}}
            ]}
            """
        }
        if previewState == "loading" {
            model.ranking = nil
            model.syncDetail = "正在读取团队数据…"
        } else {
            model.ranking = try? JSONDecoder().decode(TeamRankingSnapshot.self, from: Data(rankingJSON.utf8))
            model.syncDetail = "正在同步本机数据…"
        }
        model.websiteURL = URL(string: "https://c.wanhe.cn")
        model.selectedRange = previewRange

        let view = NSHostingView(rootView: StatusPopoverView(
            model: model,
            openWebsite: { _ in },
            selectRange: { _ in },
            openGuide: {},
            quit: {}
        ))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 456, height: 640)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
