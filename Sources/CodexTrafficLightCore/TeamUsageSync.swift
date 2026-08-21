import CryptoKit
import Darwin
import Foundation

public enum TeamUsageSyncError: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidEndpoint
    case serverRejected(status: Int, message: String)
    case invalidResponse

    public var description: String {
        switch self {
        case .invalidConfiguration(let field):
            return "Team sync configuration is missing \(field)"
        case .invalidEndpoint:
            return "Team sync endpoint is invalid"
        case .serverRejected(let status, let message):
            return "Team sync server rejected the upload (\(status)): \(message)"
        case .invalidResponse:
            return "Team sync server returned an invalid response"
        }
    }
}

public struct TeamSyncConfiguration: Equatable, Sendable {
    public var endpoint: URL
    public var token: String
    public var userID: String
    public var userName: String
    public var team: String
    public var role: String
    public var codexHome: URL
    public var collectDays: Int

    public init(
        endpoint: URL,
        token: String,
        userID: String,
        userName: String,
        team: String,
        role: String,
        codexHome: URL,
        collectDays: Int = 45
    ) {
        self.endpoint = endpoint
        self.token = token
        self.userID = userID
        self.userName = userName
        self.team = team
        self.role = role
        self.codexHome = codexHome
        self.collectDays = max(1, min(365, collectDays))
    }

    public static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/config.env")
    }

    public static func load(from url: URL = defaultConfigURL()) -> TeamSyncConfiguration? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let values = parseEnvironmentFile(source)
        guard let endpointText = values["WANHE_ENDPOINT"],
              let endpoint = URL(string: endpointText),
              !endpointText.isEmpty,
              let token = values["WANHE_INGEST_TOKEN"], !token.isEmpty,
              let userID = values["WANHE_USER_ID"], !userID.isEmpty,
              let userName = values["WANHE_USER_NAME"], !userName.isEmpty else {
            return nil
        }
        let home = values["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return TeamSyncConfiguration(
            endpoint: endpoint,
            token: token,
            userID: userID,
            userName: userName,
            team: values["WANHE_TEAM"] ?? "万合创新局",
            role: values["WANHE_ROLE"] ?? "Codex 使用者",
            codexHome: home,
            collectDays: Int(values["WANHE_COLLECT_DAYS"] ?? "45") ?? 45
        )
    }

    public static func parseEnvironmentFile(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in source.split(whereSeparator: \String.Element.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

public struct TeamDeviceIdentity: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var name: String
    public var modelIdentifier: String
    public var legacyIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, kind, name
        case modelIdentifier = "modelIdentifier"
        case legacyIDs = "legacyIds"
    }

    public init(id: String, kind: String, name: String, modelIdentifier: String, legacyIDs: [String] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.modelIdentifier = modelIdentifier
        self.legacyIDs = legacyIDs
    }

    public static func current() -> TeamDeviceIdentity {
        let hardware = systemProfilerHardware()
        let modelIdentifier = hardware.modelIdentifier.isEmpty ? sysctlString("hw.model") : hardware.modelIdentifier
        let productName = hardware.productName.isEmpty ? friendlyProductName(for: modelIdentifier) : hardware.productName
        let platformUUID = ioPlatformUUID()
        let fallbackSeed = "\(modelIdentifier)|\(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)"
        let deviceID = shortHash(platformUUID.isEmpty ? fallbackSeed : platformUUID)
        let legacyID = shortHash(ProcessInfo.processInfo.hostName)
        return TeamDeviceIdentity(
            id: deviceID,
            kind: "mac",
            name: productName,
            modelIdentifier: modelIdentifier,
            legacyIDs: legacyID == deviceID ? [] : [legacyID]
        )
    }

    public static func friendlyProductName(for modelIdentifier: String) -> String {
        let value = modelIdentifier.lowercased()
        if value.contains("macbookair") { return "MacBook Air" }
        if value.contains("macbookpro") { return "MacBook Pro" }
        if value.contains("macbook") { return "MacBook" }
        if value.contains("macstudio") { return "Mac Studio" }
        if value.contains("macmini") { return "Mac mini" }
        if value.contains("imac") { return "iMac" }
        if value.contains("macpro") { return "Mac Pro" }
        return "Mac"
    }

    public var displayLabel: String {
        guard !modelIdentifier.isEmpty, modelIdentifier.caseInsensitiveCompare(name) != .orderedSame else { return name }
        return "\(name) · \(modelIdentifier)"
    }

    private static func shortHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return pipe.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return nil
        }
    }

    private static func systemProfilerHardware() -> (productName: String, modelIdentifier: String) {
        guard let data = run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["SPHardwareDataType"] as? [[String: Any]],
              let row = rows.first else { return ("", "") }
        return (
            String(describing: row["machine_name"] ?? ""),
            String(describing: row["machine_model"] ?? "")
        )
    }

    private static func ioPlatformUUID() -> String {
        guard let data = run("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]),
              let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #"\"IOPlatformUUID\"\s*=\s*\"([^\"]+)\""#, options: .regularExpression) else {
            return ""
        }
        let match = String(text[range])
        return match.split(separator: "\"").dropFirst(3).first.map(String.init) ?? ""
    }
}

public struct TeamQuotaReport: Codable, Equatable, Sendable {
    public var weeklyRemainingPercent: Int
    public var weeklyUsedPercent: Int
    public var weeklyResetsAt: String?
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case weeklyRemainingPercent = "weeklyRemainingPercent"
        case weeklyUsedPercent = "weeklyUsedPercent"
        case weeklyResetsAt = "weeklyResetsAt"
        case updatedAt
    }

    public init(weeklyRemainingPercent: Int, weeklyResetsAt: Date?, updatedAt: Date) {
        let remaining = min(100, max(0, weeklyRemainingPercent))
        self.weeklyRemainingPercent = remaining
        self.weeklyUsedPercent = 100 - remaining
        self.weeklyResetsAt = weeklyResetsAt.map(Self.isoString)
        self.updatedAt = Self.isoString(updatedAt)
    }

    public static func from(snapshot: StateSnapshot) -> TeamQuotaReport? {
        if let quota = snapshot.providerQuota(for: ProviderQuotaSnapshot.codexProviderID),
           let weekly = quota.weeklyRemainingPercent {
            return TeamQuotaReport(
                weeklyRemainingPercent: weekly,
                weeklyResetsAt: quota.weeklyResetsAt,
                updatedAt: quota.updatedAt
            )
        }
        guard let legacy = snapshot.quota else { return nil }
        return TeamQuotaReport(
            weeklyRemainingPercent: legacy.weeklyRemainingPercent,
            weeklyResetsAt: legacy.weeklyResetsAt,
            updatedAt: legacy.updatedAt
        )
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct TeamUsageProfile: Codable, Equatable, Sendable {
    public var userId: String
    public var userName: String
    public var team: String
    public var role: String
    public var avatar: String
}

public struct TeamUsageSession: Codable, Equatable, Sendable {
    public var userId: String
    public var userName: String
    public var team: String
    public var role: String
    public var avatar: String
    public var deviceId: String
    public var sessionId: String
    public var day: String
    public var model: String
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var totalTokens: Int
    public var updatedAt: String
}

public struct TeamUsagePayload: Codable, Equatable, Sendable {
    public var collector: String
    public var collectedAt: String
    public var profile: TeamUsageProfile
    public var device: TeamDeviceIdentity
    public var quota: TeamQuotaReport?
    public var officialUsage: OfficialCodexUsageReport
    public var todayLiveUsage: TodayLiveUsageReport
    public var sessionActivity: [TeamSessionActivity]
    public var sessions: [TeamUsageSession]
}

public struct TeamUsageSyncResult: Codable, Equatable, Sendable {
    public var status: String
    public var accepted: Int
    public var total: Int
}

public struct TeamRankingMember: Codable, Equatable, Sendable {
    public struct OfficialUsageSummary: Codable, Equatable, Sendable {
        public var dataThrough: String?
    }

    public struct DeviceSummary: Codable, Equatable, Sendable {
        public var id: String
    }

    public var id: String
    public var name: String
    public var tokens: Int
    public var sessions: Int
    public var lastActive: String?
    public var officialUsage: OfficialUsageSummary?
    public var tokenSource: String?
    public var todayLiveUpdatedAt: String?
    public var avatar: String?
    public var weeklyQuota: TeamQuotaReport?
    public var devices: [DeviceSummary]?
    public var joined: Bool?

    public init(
        id: String,
        name: String,
        tokens: Int = 0,
        sessions: Int = 0,
        lastActive: String? = nil,
        officialUsage: OfficialUsageSummary? = nil,
        tokenSource: String? = nil,
        todayLiveUpdatedAt: String? = nil,
        avatar: String? = nil,
        weeklyQuota: TeamQuotaReport? = nil,
        devices: [DeviceSummary]? = nil,
        joined: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.tokens = tokens
        self.sessions = sessions
        self.lastActive = lastActive
        self.officialUsage = officialUsage
        self.tokenSource = tokenSource
        self.todayLiveUpdatedAt = todayLiveUpdatedAt
        self.avatar = avatar
        self.weeklyQuota = weeklyQuota
        self.devices = devices
        self.joined = joined
    }

    public var hasEverJoined: Bool {
        if let joined { return joined }
        if tokens > 0 || sessions > 0 { return true }
        if devices?.isEmpty == false { return true }
        if officialUsage != nil || weeklyQuota != nil { return true }
        if todayLiveUpdatedAt?.isEmpty == false { return true }
        if let tokenSource, !tokenSource.isEmpty, tokenSource != "collector" { return true }
        return false
    }
}

public struct TeamRankingSnapshot: Codable, Equatable, Sendable {
    public var updatedAt: String
    public var members: [TeamRankingMember]
}

public struct CodexTeamUsageCollector: Sendable {
    private struct FileCacheEntry: Codable {
        var signature: String
        var profileKey: String
        var records: [TeamUsageSession]
    }

    private struct Usage: Equatable {
        var inputTokens: Int
        var cachedInputTokens: Int
        var cacheWriteInputTokens: Int
        var outputTokens: Int
        var reasoningOutputTokens: Int
        var totalTokens: Int

        func delta(from previous: Usage?) -> Usage {
            guard let previous else { return self }
            return Usage(
                inputTokens: max(0, inputTokens - previous.inputTokens),
                cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
                cacheWriteInputTokens: max(0, cacheWriteInputTokens - previous.cacheWriteInputTokens),
                outputTokens: max(0, outputTokens - previous.outputTokens),
                reasoningOutputTokens: max(0, reasoningOutputTokens - previous.reasoningOutputTokens),
                totalTokens: max(0, totalTokens - previous.totalTokens)
            )
        }
    }

    public init() {}

    @available(*, unavailable, message: "Team sync uses OfficialCodexUsageCollector; conversation log scanning is intentionally disabled")
    public func collect(configuration: TeamSyncConfiguration, device: TeamDeviceIdentity) -> [TeamUsageSession] {
        let roots = ["sessions", "archived_sessions"].map { configuration.codexHome.appendingPathComponent($0) }
        let cutoff = Date().addingTimeInterval(-Double(configuration.collectDays) * 86_400)
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/usage-cache.json")
        let oldCache = loadCache(from: cacheURL)
        let profileKey = "\(configuration.userID)|\(device.id)|\(configuration.collectDays)"
        var nextCache: [String: FileCacheEntry] = [:]
        var newest: [String: TeamUsageSession] = [:]
        for root in roots {
            for file in jsonlFiles(under: root, cutoff: cutoff) {
                let signature = fileSignature(file)
                let cached = oldCache[file.path]
                let records: [TeamUsageSession]
                if let cached, cached.signature == signature, cached.profileKey == profileKey {
                    records = cached.records
                } else {
                    records = parseSessionFile(file, configuration: configuration, device: device, cutoff: cutoff)
                }
                nextCache[file.path] = FileCacheEntry(signature: signature, profileKey: profileKey, records: records)
                for record in records {
                    let key = "\(record.sessionId)|\(record.day)"
                    if newest[key] == nil || record.updatedAt >= newest[key]!.updatedAt { newest[key] = record }
                }
            }
        }
        saveCache(nextCache, to: cacheURL)
        return newest.values.sorted { ($0.day, $0.sessionId) < ($1.day, $1.sessionId) }
    }

    public func parseSessionData(
        _ data: Data,
        sessionID: String,
        configuration: TeamSyncConfiguration,
        device: TeamDeviceIdentity,
        cutoff: Date = .distantPast
    ) -> [TeamUsageSession] {
        let lines = Array(data).split(separator: 0x0A).map { Data($0) }
        return parseLines(lines, sessionID: sessionID, configuration: configuration, device: device, cutoff: cutoff)
    }

    private func parseSessionFile(
        _ url: URL,
        configuration: TeamSyncConfiguration,
        device: TeamDeviceIdentity,
        cutoff: Date
    ) -> [TeamUsageSession] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var model = "Codex"
        var previous: Usage?
        var daily: [String: TeamUsageSession] = [:]
        let sessionID = sessionID(from: url)
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                autoreleasepool {
                    processLine(
                        line,
                        sessionID: sessionID,
                        configuration: configuration,
                        device: device,
                        cutoff: cutoff,
                        model: &model,
                        previous: &previous,
                        daily: &daily
                    )
                }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty {
            processLine(
                buffer,
                sessionID: sessionID,
                configuration: configuration,
                device: device,
                cutoff: cutoff,
                model: &model,
                previous: &previous,
                daily: &daily
            )
        }
        return daily.values.sorted { $0.day < $1.day }
    }

    private func parseLines(
        _ lines: [Data],
        sessionID: String,
        configuration: TeamSyncConfiguration,
        device: TeamDeviceIdentity,
        cutoff: Date
    ) -> [TeamUsageSession] {
        var model = "Codex"
        var previous: Usage?
        var daily: [String: TeamUsageSession] = [:]
        for line in lines {
            processLine(
                line,
                sessionID: sessionID,
                configuration: configuration,
                device: device,
                cutoff: cutoff,
                model: &model,
                previous: &previous,
                daily: &daily
            )
        }
        return daily.values.sorted { $0.day < $1.day }
    }

    private func processLine(
        _ line: Data,
        sessionID: String,
        configuration: TeamSyncConfiguration,
        device: TeamDeviceIdentity,
        cutoff: Date,
        model: inout String,
        previous: inout Usage?,
        daily: inout [String: TeamUsageSession]
    ) {
        guard let text = String(data: line, encoding: .utf8),
              text.contains("\"token_count\"") || text.contains("\"session_meta\""),
              let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let type = event["type"] as? String
        let payload = event["payload"] as? [String: Any] ?? [:]
        if type == "session_meta" {
            model = string(payload["model"]) ?? string(payload["model_slug"]) ?? model
            return
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let rawUsage = info["total_token_usage"] as? [String: Any] else { return }
        let current = Usage(
            inputTokens: integer(rawUsage["input_tokens"]),
            cachedInputTokens: integer(rawUsage["cached_input_tokens"]),
            cacheWriteInputTokens: integer(rawUsage["cache_write_input_tokens"]),
            outputTokens: integer(rawUsage["output_tokens"]),
            reasoningOutputTokens: integer(rawUsage["reasoning_output_tokens"]),
            totalTokens: integer(rawUsage["total_tokens"])
        )
        if let previousUsage = previous, current.totalTokens < previousUsage.totalTokens {
            previous = current
            return
        }
        let delta = current.delta(from: previous)
        previous = current
        let timestamp = date(from: event["timestamp"]) ?? Date()
        guard timestamp >= cutoff, delta.totalTokens > 0 else { return }
        let day = dayString(timestamp)
        var record = daily[day] ?? TeamUsageSession(
            userId: configuration.userID,
            userName: configuration.userName,
            team: configuration.team,
            role: configuration.role,
            avatar: String(configuration.userName.prefix(2)),
            deviceId: device.id,
            sessionId: sessionID,
            day: day,
            model: model,
            inputTokens: 0,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 0,
            updatedAt: isoString(timestamp)
        )
        record.model = model
        record.inputTokens += delta.inputTokens
        record.cachedInputTokens += delta.cachedInputTokens
        record.cacheWriteInputTokens += delta.cacheWriteInputTokens
        record.outputTokens += delta.outputTokens
        record.reasoningOutputTokens += delta.reasoningOutputTokens
        record.totalTokens += delta.totalTokens
        record.updatedAt = isoString(timestamp)
        daily[day] = record
    }

    private func jsonlFiles(under root: URL, cutoff: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= cutoff else { return nil }
            return url
        }
    }

    private func fileSignature(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return "" }
        return "\(values.fileSize ?? 0):\((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)"
    }

    private func loadCache(from url: URL) -> [String: FileCacheEntry] {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode([String: FileCacheEntry].self, from: data) else { return [:] }
        return cache
    }

    private func saveCache(_ cache: [String: FileCacheEntry], to url: URL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    private func sessionID(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return name }
        return String(name[range])
    }

    private func integer(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }

    private func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        let result = String(describing: value)
        return result.isEmpty ? nil : result
    }

    private func date(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public struct TeamUsageSyncService: Sendable {
    public let configuration: TeamSyncConfiguration

    public init(configuration: TeamSyncConfiguration) {
        self.configuration = configuration
    }

    public var websiteURL: URL {
        var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? configuration.endpoint
    }

    public func rankingsURL(range: String = "today") -> URL {
        var components = URLComponents(url: websiteURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/rankings"
        components?.queryItems = [URLQueryItem(name: "range", value: range)]
        return components?.url ?? websiteURL
    }

    public func makePayload(quota: TeamQuotaReport?) throws -> TeamUsagePayload {
        let device = TeamDeviceIdentity.current()
        let officialUsage = try cachedOfficialUsage()
        let todayLiveUsage = TodayCodexUsageCollector().collect(codexHome: configuration.codexHome)
        let sessionActivity = CodexSessionFileCounter().collect(
            codexHome: configuration.codexHome,
            days: configuration.collectDays
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return TeamUsagePayload(
            collector: "wanhe-codex-mac-menu",
            collectedAt: formatter.string(from: Date()),
            profile: TeamUsageProfile(
                userId: configuration.userID,
                userName: configuration.userName,
                team: configuration.team,
                role: configuration.role,
                avatar: String(configuration.userName.prefix(2))
            ),
            device: device,
            quota: quota,
            officialUsage: officialUsage,
            todayLiveUsage: todayLiveUsage,
            sessionActivity: sessionActivity,
            sessions: []
        )
    }

    private func cachedOfficialUsage(maxAge: TimeInterval = 2 * 60 * 60) throws -> OfficialCodexUsageReport {
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/official-usage.json")
        let cached: OfficialCodexUsageReport? = {
            guard let data = try? Data(contentsOf: cacheURL) else { return nil }
            return try? JSONDecoder().decode(OfficialCodexUsageReport.self, from: data)
        }()
        if let cached,
           let updatedAt = Self.isoDate(cached.updatedAt),
           Date().timeIntervalSince(updatedAt) < maxAge {
            return cached
        }
        do {
            let fresh = try OfficialCodexUsageCollector().fetch()
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: cacheURL, options: [.atomic]) }
            return fresh
        } catch {
            if let cached { return cached }
            throw error
        }
    }

    private static func isoDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    public func sync(quota: TeamQuotaReport?) async throws -> TeamUsageSyncResult {
        let payload = try makePayload(quota: quota)
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TeamUsageSyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown"
            throw TeamUsageSyncError.serverRejected(status: http.statusCode, message: message)
        }
        guard let result = try? JSONDecoder().decode(TeamUsageSyncResult.self, from: data) else {
            throw TeamUsageSyncError.invalidResponse
        }
        return result
    }

    public func fetchRanking(range: String = "today") async throws -> TeamRankingSnapshot {
        var request = URLRequest(url: rankingsURL(range: range))
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TeamUsageSyncError.invalidResponse
        }
        guard let snapshot = try? JSONDecoder().decode(TeamRankingSnapshot.self, from: data) else {
            throw TeamUsageSyncError.invalidResponse
        }
        return snapshot
    }
}

public extension Defaults {
    static let teamSyncRefreshSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["CODEX_LIGHT_TEAM_SYNC_SECONDS"],
           let seconds = TimeInterval(raw), seconds > 0 { return seconds }
        return 2 * 60
    }()
}
