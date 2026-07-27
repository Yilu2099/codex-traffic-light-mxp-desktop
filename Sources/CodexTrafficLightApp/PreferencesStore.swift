import Foundation
import CodexTrafficLightCore

struct AppPreferences: Codable, Equatable {
    var muted: Bool
    var showFloatingWindow: Bool
    var autoShowOnDone: Bool
    var autoShowOnWaiting: Bool
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case muted
        case showFloatingWindow = "show_floating_window"
        case autoShowOnDone = "auto_show_on_done"
        case autoShowOnWaiting = "auto_show_on_waiting"
        case updatedAt = "updated_at"
    }

    static func defaults(now: Date = Date()) -> AppPreferences {
        AppPreferences(
            muted: false,
            showFloatingWindow: true,
            autoShowOnDone: true,
            autoShowOnWaiting: true,
            updatedAt: now
        )
    }
}

final class PreferencesStore {
    let url: URL

    init(url: URL = StateStore.defaultSupportDirectory().appendingPathComponent("preferences.json")) {
        self.url = url
    }

    func read() -> AppPreferences {
        guard let data = try? Data(contentsOf: url) else {
            return .defaults()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(AppPreferences.self, from: data)) ?? .defaults()
    }

    func write(_ preferences: AppPreferences) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(preferences) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
