import AppKit
import SwiftUI
import CodexTrafficLightCore

@MainActor
enum StatusPopoverCapture {
    static func writePreview(to url: URL) -> Bool {
        let now = Date()
        let model = StatusPopoverModel()
        model.snapshot = StateSnapshot(
            aggregateState: .idle,
            updatedAt: now,
            providerQuotas: [
                ProviderQuotaSnapshot.codexProviderID: ProviderQuotaSnapshot(
                    source: "preview",
                    updatedAt: now,
                    weeklyRemainingPercent: 78,
                    weeklyResetsAt: now.addingTimeInterval(5 * 86_400 + 22 * 3_600)
                )
            ],
            tasks: [:]
        )
        let rankingJSON = """
        {"updatedAt":"2026-08-21 13:36","members":[
          {"id":"zlu","name":"张璐","avatar":"/avatars/58.png","tokens":1210000000,"sessions":12,"lastActive":"10:36","grindDay":"2026-08-22","dayGrindTime":"09:42","nightGrindTime":"02:04","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T02:36:00Z","weeklyQuota":{"weeklyRemainingPercent":78,"weeklyUsedPercent":22,"weeklyResetsAt":"2026-08-27T03:33:00.000Z","updatedAt":"2026-08-22T02:36:00.000Z"}},
          {"id":"qiaoyue","name":"乔月","avatar":"/avatars/201.png","tokens":66066000,"sessions":2,"lastActive":"10:35","grindDay":"2026-08-22","dayGrindTime":"07:42","nightGrindTime":"03:12","officialUsage":{"dataThrough":"2026-08-20"},"tokenSource":"today_live","todayLiveUpdatedAt":"2026-08-22T02:35:00Z"},
          {"id":"qiubo","name":"仇博","avatar":"/avatars/193.png","tokens":0,"sessions":0}
        ]}
        """
        model.ranking = try? JSONDecoder().decode(TeamRankingSnapshot.self, from: Data(rankingJSON.utf8))
        model.syncDetail = "刚刚同步"
        model.websiteURL = URL(string: "https://c.wanhe.cn")

        let view = NSHostingView(rootView: StatusPopoverView(model: model, openWebsite: { _ in }, quit: {}))
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
