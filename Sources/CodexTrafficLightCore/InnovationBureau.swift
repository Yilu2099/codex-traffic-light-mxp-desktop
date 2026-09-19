import Foundation

/// 创新局子系统：张璐、李国庆、乔月负责的企业 AI 数字化项目。
/// 数据由三人在网站上自己填写，状态栏只读展示。
public enum InnovationBureau {
    public static let name = "创新局"
    public static let tagline = "给企业做 AI 数字化改造"
    public static let memberIDs = ["zlu", "liguoqing", "qiaoyue"]

    public static func isMember(_ userID: String) -> Bool {
        memberIDs.contains(userID)
    }
}

public struct BureauStage: Codable, Equatable, Sendable {
    public var key: String
    public var label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

public struct BureauProject: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var client: String
    public var summary: String
    public var progressNote: String
    public var nextStep: String
    public var stage: String
    public var stageLabel: String
    public var percent: Int
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        client: String = "",
        summary: String = "",
        progressNote: String = "",
        nextStep: String = "",
        stage: String = "planning",
        stageLabel: String = "刚立项",
        percent: Int = 0,
        updatedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.client = client
        self.summary = summary
        self.progressNote = progressNote
        self.nextStep = nextStep
        self.stage = stage
        self.stageLabel = stageLabel
        self.percent = percent
        self.updatedAt = updatedAt
    }
}

public struct BureauMember: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var avatar: String
    public var projects: [BureauProject]
    public var activeCount: Int
    public var onlineCount: Int
    public var updatedAt: String

    public init(
        id: String,
        name: String,
        avatar: String = "",
        projects: [BureauProject] = [],
        activeCount: Int = 0,
        onlineCount: Int = 0,
        updatedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.projects = projects
        self.activeCount = activeCount
        self.onlineCount = onlineCount
        self.updatedAt = updatedAt
    }
}

public struct BureauSnapshot: Codable, Equatable, Sendable {
    public var name: String
    public var tagline: String
    public var updatedAt: String
    public var stages: [BureauStage]
    public var members: [BureauMember]

    public init(
        name: String = InnovationBureau.name,
        tagline: String = InnovationBureau.tagline,
        updatedAt: String = "",
        stages: [BureauStage] = [],
        members: [BureauMember] = []
    ) {
        self.name = name
        self.tagline = tagline
        self.updatedAt = updatedAt
        self.stages = stages
        self.members = members
    }

    public var projectCount: Int {
        members.reduce(0) { $0 + $1.projects.count }
    }

    public var activeCount: Int {
        members.reduce(0) { $0 + $1.activeCount }
    }
}

public extension TeamUsageSyncService {
    var bureauURL: URL {
        var components = URLComponents(url: websiteURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/bureau"
        components?.query = nil
        return components?.url ?? websiteURL
    }

    var bureauPageURL: URL {
        var components = URLComponents(url: websiteURL, resolvingAgainstBaseURL: false)
        components?.path = "/bureau"
        components?.query = nil
        return components?.url ?? websiteURL
    }

    func fetchBureau() async throws -> BureauSnapshot {
        var request = URLRequest(url: bureauURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TeamUsageSyncError.invalidResponse
        }
        guard let snapshot = try? JSONDecoder().decode(BureauSnapshot.self, from: data) else {
            throw TeamUsageSyncError.invalidResponse
        }
        return snapshot
    }
}

public extension Defaults {
    static let bureauRefreshSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["CODEX_LIGHT_BUREAU_SECONDS"],
           let seconds = TimeInterval(raw), seconds > 0 { return seconds }
        return 10 * 60
    }()
}
