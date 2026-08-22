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
                weeklyRemainingPercent: 61,
                weeklyResetsAt: now.addingTimeInterval(5 * 86_400 + 22 * 3_600),
                source: "preview",
                updatedAt: now
            )
        )
        model.syncedQuota = TeamQuotaReport(
            weeklyRemainingPercent: 48,
            weeklyResetsAt: now.addingTimeInterval(4 * 86_400 + 12 * 3_600),
            updatedAt: now
        )
        let previewState = ProcessInfo.processInfo.environment["CODEX_LIGHT_CAPTURE_STATUS_STATE"]
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        timeFormatter.dateFormat = "HH:mm"
        let recentActive = timeFormatter.string(from: now.addingTimeInterval(-5 * 60))
        let rankingJSON: String
        if previewState == "unjoined" {
            rankingJSON = """
            {"updatedAt":"2026-08-21 13:36","members":[
              {"id":"zlu","name":"张璐","avatar":"/avatars/58.png","tokens":1210000000,"sessions":12,"lastActive":"\(recentActive)","grindDay":"2026-08-22","dayGrindTime":"09:42","nightGrindTime":"02:04","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T03:49:00Z","weeklyQuota":{"weeklyRemainingPercent":61,"weeklyUsedPercent":39,"weeklyResetsAt":"2026-08-26T03:33:00.000Z","updatedAt":"2026-08-22T03:49:00.000Z"}},
              {"id":"qiubo","name":"仇博","avatar":"/avatars/193.png","tokens":0,"sessions":0,"joined":false}
            ]}
            """
        } else {
            rankingJSON = """
            {"updatedAt":"2026-08-21 13:36","members":[
              {"id":"zlu","name":"张璐","avatar":"/avatars/58.png","tokens":583000000,"sessions":12,"lastActive":"\(recentActive)","grindDay":"2026-08-22","dayGrindTime":"09:33","nightGrindTime":"02:04","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T03:49:00Z","weeklyQuota":{"weeklyRemainingPercent":48,"weeklyUsedPercent":52,"weeklyResetsAt":"2026-08-27T03:33:00.000Z","updatedAt":"2026-08-22T03:49:00.000Z"}},
              {"id":"liguoqing","name":"李国庆","avatar":"/avatars/168.png","tokens":151000000,"sessions":9,"lastActive":"21:35","grindDay":"2026-08-22","dayGrindTime":"10:16","nightGrindTime":"02:03","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T03:10:00Z","weeklyQuota":{"weeklyRemainingPercent":100,"weeklyUsedPercent":0,"weeklyResetsAt":"2026-08-29T03:33:00.000Z","updatedAt":"2026-08-22T03:10:00.000Z"}},
              {"id":"qiaoyue","name":"乔月","avatar":"/avatars/201.png","tokens":125000000,"sessions":7,"lastActive":"16:50","grindDay":"2026-08-22","dayGrindTime":"09:59","nightGrindTime":"03:08","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T02:35:00Z","weeklyQuota":{"weeklyRemainingPercent":62,"weeklyUsedPercent":38,"weeklyResetsAt":"2026-08-28T03:33:00.000Z","updatedAt":"2026-08-22T02:35:00.000Z"}},
              {"id":"huangning","name":"黄宁","avatar":"/avatars/199.png","tokens":67111000,"sessions":5,"lastActive":"19:53","grindDay":"2026-08-22","dayGrindTime":"10:05","nightGrindTime":"02:11","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T02:10:00Z","weeklyQuota":{"weeklyRemainingPercent":58,"weeklyUsedPercent":42,"weeklyResetsAt":"2026-08-27T03:33:00.000Z","updatedAt":"2026-08-22T02:10:00.000Z"}},
              {"id":"mameng","name":"马猛","avatar":"/avatars/codex-06.png","tokens":38217000,"sessions":4,"lastActive":"20:42","grindDay":"2026-08-22","dayGrindTime":"11:02","nightGrindTime":"01:49","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T01:45:00Z","weeklyQuota":{"weeklyRemainingPercent":35,"weeklyUsedPercent":65,"weeklyResetsAt":"2026-08-26T03:33:00.000Z","updatedAt":"2026-08-22T01:45:00.000Z"}}
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

        let view = NSHostingView(rootView: StatusPopoverView(model: model, openWebsite: { _ in }, openGuide: {}, quit: {}))
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
