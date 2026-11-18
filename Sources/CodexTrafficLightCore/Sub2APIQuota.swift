import Foundation

public struct Sub2APIQuota: Decodable {
    public struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        public var reset: Date? { Sub2APIQuota.date(resetsAt) }
        public var remaining: Double? {
            guard let utilization, utilization.isFinite, utilization >= 0,
                  let reset, reset > Date() else { return nil }
            return max(0, 100 - utilization)
        }
    }

    private let error: String?
    private let errorCode: String?
    public let updatedAt: String?
    public let fiveHour: Window?
    public let sevenDay: Window?
    public let sevenDayFable: Window?

    private struct Envelope: Decodable {
        let code: Int
        let data: Sub2APIQuota?
    }

    public static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }

    static func decode(_ data: Data) throws -> Self? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Envelope.self, from: data)
        guard response.code == 0, let quota = response.data,
              quota.error?.isEmpty != false, quota.errorCode?.isEmpty != false else { return nil }
        return quota
    }

    func membership(now: Date) -> ToolMembership? {
        guard let observedAt = Self.date(updatedAt),
              (-60...1800).contains(now.timeIntervalSince(observedAt)) else { return nil }
        let formatter = ISO8601DateFormatter()
        let windows = [("five_hour", fiveHour), ("seven_day", sevenDay)].compactMap { key, window -> ToolMembership.Window? in
            guard let used = window?.utilization, used.isFinite, used >= 0,
                  let reset = window?.reset, reset > now else { return nil }
            return .init(key: key, usedPercent: min(100, used), resetsAt: formatter.string(from: reset))
        }
        return windows.isEmpty ? nil : ToolMembership(windows: windows, quotaObservedAt: formatter.string(from: observedAt))
    }

    public struct Configuration: Decodable, Sendable {
        let origin: URL
        let accountID: Int
        let apiKey: String
        let usageKeyIDs: [Int]?

        public static let localFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/claude-sub2api.json")

        public static func load(from file: URL = localFile) throws -> Self {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let mode = attributes[.posixPermissions] as? Int, mode & 0o077 == 0 else {
                throw URLError(.noPermissionsToReadFile)
            }
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        }

        func dailyUsage(now: Date) async -> [ToolDailyUsage] {
            struct Stats: Decodable {
                let total_input_tokens, total_output_tokens, total_cache_read_tokens, total_cache_creation_tokens, total_tokens: Int
            }
            struct UsageEnvelope: Decodable { let code: Int; let data: Stats }
            guard let keys = usageKeyIDs, (1...8).contains(keys.count),
                  keys.allSatisfy({ $0 > 0 }), Set(keys).count == keys.count else { return [] }
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let days = (0..<2).map { formatter.string(from: now.addingTimeInterval(-86_400 * Double($0))) }
            return await withTaskGroup(of: ToolDailyUsage?.self) { group in
                for day in days {
                    group.addTask {
                        var input = 0, output = 0, cached = 0, written = 0
                        for id in keys {
                            let query = ["api_key_id": String(id), "start_date": day, "end_date": day, "timezone": "Asia/Shanghai"]
                            guard let bytes = try? await request(path: "/api/v1/admin/usage/stats", query: query),
                                  let envelope = try? JSONDecoder().decode(UsageEnvelope.self, from: bytes), envelope.code == 0 else { return nil }
                            let row = envelope.data
                            let counts = [row.total_input_tokens, row.total_output_tokens, row.total_cache_read_tokens, row.total_cache_creation_tokens]
                            guard counts.allSatisfy({ (0...1_000_000_000_000).contains($0) }),
                                  counts.reduce(0, +) == row.total_tokens else { return nil }
                            input += row.total_input_tokens + row.total_cache_read_tokens
                            output += row.total_output_tokens
                            cached += row.total_cache_read_tokens
                            written += row.total_cache_creation_tokens
                        }
                        return ToolDailyUsage(tool: "claude", day: day, inputTokens: input, cachedInputTokens: cached,
                                              cacheWriteInputTokens: written, outputTokens: output)
                    }
                }
                var rows: [ToolDailyUsage] = []
                for await row in group { if let row { rows.append(row) } }
                return rows.sorted { $0.day < $1.day }
            }
        }

        public func fetch(refresh: Bool = false) async throws -> Sub2APIQuota? {
            var query = ["source": refresh ? "active" : "passive"]
            if refresh { query["force"] = "true" }
            let data = try await request(path: "/api/v1/admin/accounts/\(accountID)/usage", query: query)
            return try Sub2APIQuota.decode(data)
        }

        private func request(path: String, query: [String: String]) async throws -> Data {
            guard var url = URLComponents(url: origin, resolvingAgainstBaseURL: false),
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  accountID > 0, !apiKey.isEmpty else { throw URLError(.badURL) }
            url.path = path
            url.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
            url.fragment = nil
            guard let endpoint = url.url else { throw URLError(.badURL) }
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
