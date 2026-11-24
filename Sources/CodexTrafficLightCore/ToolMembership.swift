import Foundation
import CoreFoundation

public struct ToolMembership: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var key: String
        public var usedPercent: Double
        public var resetsAt: String?
    }

    public var plan: String?
    public var planObservedAt: String?
    public var windows: [Window]?
    public var quotaObservedAt: String?
}

/// The two input sources carry account or session data. Construct the report
/// from an allowlist instead of persisting or forwarding their raw responses.
public enum ToolMembershipSource {
    private static let claudePlans = ["free", "pro", "max", "max_5x", "max_20x", "ultra", "team", "enterprise"]
    private static let kimiPlans = ["free", "go", "plus", "pro", "ultra", "andante", "moderato", "allegretto", "allegro", "presto", "adagio", "enterprise", "免费", "行板", "中板", "小快板", "快板", "急板", "柔板", "企业版"]

    private static func plan(_ raw: String?, allowed: [String]) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              allowed.contains(value) else { return nil }
        return value
    }

    private static func object(_ data: Data?) -> [String: Any]? {
        guard let data, data.count <= 65_536 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func report(plan: String?, windows: [ToolMembership.Window], now: Date) -> ToolMembership? {
        guard plan != nil || !windows.isEmpty else { return nil }
        let observed = ISO8601DateFormatter().string(from: now)
        return ToolMembership(plan: plan, planObservedAt: plan.map { _ in observed },
                              windows: windows.isEmpty ? nil : windows, quotaObservedAt: windows.isEmpty ? nil : observed)
    }

    public static func claudeAccount(_ data: Data, now: Date = Date()) -> ToolMembership? {
        guard let root = object(data), root["loggedIn"] as? Bool == true,
              root["authMethod"] as? String == "claude.ai", root["apiProvider"] as? String == "firstParty" else { return nil }
        return report(plan: plan(root["subscriptionType"] as? String, allowed: claudePlans), windows: [], now: now)
    }

    public static func kimi(usage: Data?, profile: Data?, now: Date = Date()) -> ToolMembership? {
        func result(_ data: Data?) -> [String: Any]? {
            guard let root = object(data), number(root["code"]) == 0,
                  let row = root["data"] as? [String: Any], row["kind"] as? String == "ok" else { return nil }
            return row
        }
        let info = result(profile)?["userInfo"] as? [String: Any]
        let quota = result(usage)?["quota"] as? [String: Any]
        let usages = quota?["usages"] as? [String: Any]
        let keys = [("limit5h", "five_hour"), ("limit7d", "seven_day"), ("monthTotal", "month_total"), ("monthCode", "month_code")]
        let windows: [ToolMembership.Window] = keys.compactMap { source, key in
            guard let row = usages?[source] as? [String: Any],
                  let ratio = number(row["usedRatio"]), (0...1).contains(ratio) else { return nil }
            let reset = (row["resetAt"] as? String).flatMap(date)
            if let reset, reset <= now || reset.timeIntervalSince(now) > 45 * 86_400 { return nil }
            return .init(key: key, usedPercent: ratio * 100, resetsAt: reset.map(ISO8601DateFormatter().string(from:)))
        }
        return report(plan: plan(info?["userLevelName"] as? String, allowed: kimiPlans), windows: windows, now: now)
    }

    public static func antigravity(_ output: String, now: Date = Date()) -> ToolMembership? {
        var windows: [ToolMembership.Window] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let cols = rawLine.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3 else { continue }
            let group = cols[0].lowercased()
            let label = cols[1].lowercased()
            let key: String
            if group.contains("gemini") {
                if label.contains("five hour") { key = "five_hour" }
                else if label.contains("weekly") { key = "seven_day" }
                else { continue }
            } else if group.contains("claude") || group.contains("gpt") {
                if label.contains("five hour") { key = "bonus_five_hour" }
                else if label.contains("weekly") { key = "bonus_seven_day" }
                else { continue }
            } else {
                continue
            }
            let pctText = cols[2].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            guard let remaining = Double(pctText), remaining.isFinite, (0...100).contains(remaining) else { continue }
            let reset = cols.count >= 4 ? date(cols[3]) : nil
            if let reset, reset <= now || reset.timeIntervalSince(now) > 45 * 86_400 { continue }
            let usedPercent = max(0, min(100, 100 - remaining))
            windows.append(.init(key: key, usedPercent: usedPercent, resetsAt: reset.map(ISO8601DateFormatter().string(from:))))
        }
        return report(plan: nil, windows: windows, now: now)
    }
}

/// Disable external proxies, cookies, and redirects before using a Kimi Web
/// bearer. This bearer is only used in memory on the already-running loopback
/// server; it isn't the managed account's cloud OAuth credential.
private final class ToolMembershipLoopback: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ToolMembershipCollector {
    static let shared = ToolMembershipCollector()
    private var lastAttempt = Date.distantPast
    private var lastAntigravityAttempt = Date.distantPast
    private var lastAntigravityReport: ToolMembership?
    private(set) var gatewayDailyUsage: [ToolDailyUsage] = []
    private var lastReports: [String: ToolMembership] = [:]

    func collect(now: Date = Date()) async -> [String: ToolMembership]? {
        if now.timeIntervalSince(lastAttempt) >= 300 {
            lastAttempt = now
            let home = FileManager.default.homeDirectoryForCurrentUser
            async let claude = Self.claude(home: home, now: now)
            async let kimi = Self.kimi(home: home, now: now)
            let settings = try? Sub2APIQuota.Configuration.load()
            async let gateway = try? settings?.fetch()
            async let gatewayUsage = settings?.dailyUsage(now: now) ?? []
            if now.timeIntervalSince(lastAntigravityAttempt) >= 600 {
                lastAntigravityAttempt = now
                if let fresh = await Self.antigravity(home: home, now: now) {
                    lastAntigravityReport = fresh
                }
            }
            let (account, quota, gatewayQuota) = await (claude, kimi, gateway)
            lastReports = [
                "claude": account,
                "kimi": quota,
                "claude_sub2api": gatewayQuota?.membership(now: Date()),
                "antigravity": lastAntigravityReport,
            ].compactMapValues { $0 }
            gatewayDailyUsage = await gatewayUsage
        }
        return lastReports.isEmpty ? nil : lastReports
    }

    private static func antigravity(home: URL, now: Date) async -> ToolMembership? {
        let paths = [
            home.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let result = boundedProcessResult(executable: executable, arguments: ["-p", "/usage"], timeout: 10)
        guard result.status == 0 else { return nil }
        return ToolMembershipSource.antigravity(result.output, now: now)
    }

    private static func claude(home: URL, now: Date) async -> ToolMembership? {
        let paths = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let result = boundedProcessResult(executable: executable, arguments: ["auth", "status"], timeout: 2)
        guard result.status == 0, let data = result.output.data(using: .utf8) else { return nil }
        return ToolMembershipSource.claudeAccount(data, now: now)
    }

    private static func kimi(home: URL, now: Date) async -> ToolMembership? {
        let manager = FileManager.default
        let base = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".kimi-code")
        let executables = [
            home.appendingPathComponent(".kimi-code/bin/kimi"),
            home.appendingPathComponent(".local/bin/kimi"),
            URL(fileURLWithPath: "/opt/homebrew/bin/kimi"),
            URL(fileURLWithPath: "/usr/local/bin/kimi"),
        ].filter { manager.isExecutableFile(atPath: $0.path) }
            .map { "n" + $0.resolvingSymlinksInPath().path }
        guard !executables.isEmpty else { return nil }
        let instanceDir = base.appendingPathComponent("server/instances")
        guard let files = try? manager.contentsOfDirectory(at: instanceDir, includingPropertiesForKeys: [.fileSizeKey]),
              let port = files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(5)
                .lazy.compactMap({ runningKimiPort($0, executables: executables, now: now) }).first else { return nil }
        let tokenFile = base.appendingPathComponent("server.token")
        guard let attributes = try? manager.attributesOfItem(atPath: tokenFile.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600,
              (attributes[.size] as? NSNumber)?.intValue ?? 1_024 <= 256,
              let token = (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
              token.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) != nil else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: ToolMembershipLoopback(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        @Sendable func get(_ endpoint: String) async -> Data? {
            let url = URL(string: "http://127.0.0.1:\(port)/api/v1/oauth/\(endpoint)")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (body, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return body
        }
        async let usage = get("usage")
        async let profile = get("userinfo")
        return await ToolMembershipSource.kimi(usage: usage, profile: profile, now: now)
    }

    private static func runningKimiPort(_ file: URL, executables: [String], now: Date) -> Int? {
        struct Instance: Decodable {
            var host: String
            var port: Int
            var pid: Int32
            var heartbeat_at: Int
        }
        guard file.pathExtension == "json",
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 4_096,
              let data = try? Data(contentsOf: file), let row = try? JSONDecoder().decode(Instance.self, from: data),
              row.host == "127.0.0.1", (1024...65535).contains(row.port), row.pid > 1, kill(row.pid, 0) == 0,
              (-5...120).contains(now.timeIntervalSince1970 - Double(row.heartbeat_at) / 1_000) else { return nil }
        let process = boundedProcessResult(executable: "/usr/sbin/lsof", arguments: [
            "-nP", "-a", "-p", String(row.pid), "-d", "txt", "-Fn",
        ], timeout: 0.5)
        // The first txt entry is the executable. Later entries are mapped libraries.
        let executable = process.output.split(separator: "\n").first { $0.hasPrefix("n") }.map(String.init)
        guard process.status == 0, let executable, executables.contains(executable) else { return nil }
        let listener = boundedProcessResult(executable: "/usr/sbin/lsof", arguments: [
            "-nP", "-a", "-p", String(row.pid), "-iTCP@127.0.0.1:\(row.port)", "-sTCP:LISTEN", "-Fn",
        ], timeout: 0.5)
        return listener.status == 0 && listener.output.split(separator: "\n").contains("n127.0.0.1:\(row.port)") ? row.port : nil
    }
}
