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

    public static func antigravityQuotaSummary(_ data: Data, now: Date = Date()) -> ToolMembership? {
        guard let root = object(data) else { return nil }
        var buckets: [[String: Any]] = []
        if let groups = root["groups"] as? [[String: Any]] {
            for group in groups {
                if let list = group["buckets"] as? [[String: Any]] {
                    buckets.append(contentsOf: list)
                }
            }
        }
        if let top = root["buckets"] as? [[String: Any]] {
            buckets.append(contentsOf: top)
        }
        var seen = Set<String>()
        var windows: [ToolMembership.Window] = []
        for bucket in buckets {
            if bucket["disabled"] as? Bool == true { continue }
            guard let bucketID = (bucket["bucketId"] as? String)?.lowercased(),
                  let remainingFraction = number(bucket["remainingFraction"]),
                  (0...1).contains(remainingFraction) else { continue }
            let windowKind = (bucket["window"] as? String)?.lowercased() ?? ""
            let key: String
            if bucketID.hasPrefix("gemini-") && !bucketID.hasPrefix("gemini-argon-") && !bucketID.hasPrefix("gemini-carbon-") {
                if windowKind == "5h" || bucketID.hasSuffix("-5h") { key = "five_hour" }
                else if windowKind == "weekly" || bucketID.hasSuffix("-weekly") { key = "seven_day" }
                else { continue }
            } else if bucketID.hasPrefix("3p-") {
                if windowKind == "5h" || bucketID.hasSuffix("-5h") { key = "bonus_five_hour" }
                else if windowKind == "weekly" || bucketID.hasSuffix("-weekly") { key = "bonus_seven_day" }
                else { continue }
            } else {
                continue
            }
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let reset = (bucket["resetTime"] as? String).flatMap(date)
            let validReset = reset.flatMap { ($0 > now && $0.timeIntervalSince(now) <= 45 * 86_400) ? $0 : nil }
            let usedPercent = max(0, min(100, (1 - remainingFraction) * 100))
            windows.append(.init(key: key, usedPercent: usedPercent, resetsAt: validReset.map(ISO8601DateFormatter().string(from:))))
        }
        return report(plan: nil, windows: windows, now: now)
    }

    public static func kimiDirectUsage(_ data: Data, now: Date = Date()) -> ToolMembership? {
        guard let root = object(data) else { return nil }
        var windows: [ToolMembership.Window] = []

        func validReset(_ raw: Any?) -> String? {
            guard let text = raw as? String, let parsed = date(text),
                  parsed > now, parsed.timeIntervalSince(now) <= 45 * 86_400 else { return nil }
            return ISO8601DateFormatter().string(from: parsed)
        }
        func usedPercent(from detail: [String: Any]?) -> Double? {
            guard let detail else { return nil }
            let limit = number(detail["limit"]) ?? (detail["limit"] as? String).flatMap(Double.init)
            let remaining = number(detail["remaining"]) ?? (detail["remaining"] as? String).flatMap(Double.init)
            guard let limit, let remaining, limit > 0, limit.isFinite, remaining.isFinite else { return nil }
            return max(0, min(100, ((limit - remaining) / limit) * 100))
        }

        let usages = root["usages"] as? [String: Any]
        if let l5 = usages?["limit_5h"] as? [String: Any], let ratio = number(l5["used_ratio"]), (0...1).contains(ratio) {
            windows.append(.init(key: "five_hour", usedPercent: ratio * 100, resetsAt: validReset(l5["reset_time"])))
        } else if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                let win = entry["window"] as? [String: Any]
                let dur = number(win?["duration"]) ?? 0
                let unit = (win?["timeUnit"] as? String) ?? ""
                let mins = unit == "TIME_UNIT_HOUR" ? dur * 60 : unit == "TIME_UNIT_DAY" ? dur * 1440 : dur
                if mins > 0 && mins <= 1440, let detail = entry["detail"] as? [String: Any], let used = usedPercent(from: detail) {
                    windows.append(.init(key: "five_hour", usedPercent: used, resetsAt: validReset(detail["resetTime"])))
                    break
                }
            }
        }

        if let l7 = usages?["limit_7d"] as? [String: Any], let ratio = number(l7["used_ratio"]), (0...1).contains(ratio) {
            windows.append(.init(key: "seven_day", usedPercent: ratio * 100, resetsAt: validReset(l7["reset_time"])))
        } else if let usage = root["usage"] as? [String: Any], let used = usedPercent(from: usage) {
            windows.append(.init(key: "seven_day", usedPercent: used, resetsAt: validReset(usage["resetTime"])))
        }

        return report(plan: nil, windows: windows, now: now)
    }

    public static func grokBilling(_ data: Data, now: Date = Date()) -> ToolMembership? {
        guard let root = object(data), let config = root["config"] as? [String: Any] else { return nil }
        let period = config["currentPeriod"] as? [String: Any]
        let rawType = (period?["type"] as? String ?? "").uppercased()
        let key = rawType.contains("WEEKLY") ? "seven_day" : rawType.contains("MONTHLY") ? "month_total" : "seven_day"
        let reset = (period?["end"] as? String).flatMap(date)
        let validReset = reset.flatMap { ($0 > now && $0.timeIntervalSince(now) <= 45 * 86_400) ? $0 : nil }
        let usedPercent: Double
        if let pct = number(config["creditUsagePercent"]), (0...100).contains(pct) {
            usedPercent = pct
        } else if validReset != nil && (rawType.contains("WEEKLY") || rawType.contains("MONTHLY")) {
            usedPercent = 0
        } else {
            return nil
        }
        return report(plan: nil, windows: [.init(key: key, usedPercent: usedPercent, resetsAt: validReset.map(ISO8601DateFormatter().string(from:)))], now: now)
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
            async let grok = Self.grok(home: home, now: now)
            let settings = try? Sub2APIQuota.Configuration.load()
            async let gateway = try? settings?.fetch()
            async let gatewayUsage = settings?.dailyUsage(now: now) ?? []
            if now.timeIntervalSince(lastAntigravityAttempt) >= 300 {
                lastAntigravityAttempt = now
                if let fresh = await Self.antigravity(home: home, now: now) {
                    lastAntigravityReport = fresh
                }
            }
            let (account, quota, grokQuota, gatewayQuota) = await (claude, kimi, grok, gateway)
            lastReports = [
                "claude": account,
                "kimi": quota,
                "grok": grokQuota,
                "claude_sub2api": gatewayQuota?.membership(now: Date()),
                "antigravity": lastAntigravityReport,
            ].compactMapValues { $0 }
            gatewayDailyUsage = await gatewayUsage
        }
        return lastReports.isEmpty ? nil : lastReports
    }

    private static let nonInteractiveEnv: [String: String] = [
        "BROWSER": "/usr/bin/false",
        "NO_BROWSER": "1",
        "GOOGLE_AUTH_DISABLE_BROWSER": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    ]

    private static func makeEphemeralSession(timeout: TimeInterval = 8) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: ToolMembershipLoopback(), delegateQueue: nil)
    }

    private static func decodeGoKeyringSecret(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("go-keyring-base64:") {
            let b64 = String(trimmed.dropFirst("go-keyring-base64:".count))
            if let data = Data(base64Encoded: b64), let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
        } else if trimmed.hasPrefix("go-keyring-encoded:") {
            let hex = String(trimmed.dropFirst("go-keyring-encoded:".count))
            var bytes = [UInt8]()
            var index = hex.startIndex
            while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
                if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
                index = next
            }
            if let decoded = String(bytes: bytes, encoding: .utf8) { return decoded }
        }
        return trimmed
    }

    /// Silent direct Antigravity quota read from macOS Keychain (no `agy` CLI spawn, zero browser prompts).
    private static func antigravity(home: URL, now: Date) async -> ToolMembership? {
        let sec = boundedProcessResult(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"],
            timeout: 3
        )
        guard sec.status == 0, !sec.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let decoded = decodeGoKeyringSecret(sec.output)
        guard let data = decoded.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokenObj = json["token"] as? [String: Any],
              let accessToken = (tokenObj["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else { return nil }
        if let expiryStr = tokenObj["expiry"] as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let exp = fmt.date(from: expiryStr) ?? ISO8601DateFormatter().date(from: expiryStr),
               exp <= now.addingTimeInterval(30) {
                return nil
            }
        }

        let session = makeEphemeralSession(timeout: 8)
        defer { session.finishTasksAndInvalidate() }
        let endpoints = [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        ]
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = Data("{}".utf8)
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)", forHTTPHeaderField: "User-Agent")
            guard let (body, response) = try? await session.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if let report = ToolMembershipSource.antigravityQuotaSummary(body, now: now) {
                return report
            }
        }
        return nil
    }

    private static func grok(home: URL, now: Date) async -> ToolMembership? {
        let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".grok")
        let authFile = grokHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authFile), data.count <= 65_536,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let entry = (root["https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"] as? [String: Any])
            ?? (root["https://accounts.x.ai/sign-in"] as? [String: Any])
        guard let entry, (entry["auth_mode"] as? String) != "api_key",
              let token = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }

        let session = makeEphemeralSession(timeout: 8)
        defer { session.finishTasksAndInvalidate() }
        guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (body, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ToolMembershipSource.grokBilling(body, now: now)
    }

    private static func claude(home: URL, now: Date) async -> ToolMembership? {
        let paths = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let executable = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let result = boundedProcessResult(executable: executable, arguments: ["auth", "status"], timeout: 2, environment: nonInteractiveEnv)
        guard result.status == 0, let data = result.output.data(using: .utf8) else { return nil }
        return ToolMembershipSource.claudeAccount(data, now: now)
    }

    private static func kimi(home: URL, now: Date) async -> ToolMembership? {
        if let direct = await kimiDirect(home: home, now: now) {
            return direct
        }
        return await kimiLoopback(home: home, now: now)
    }

    private static func kimiDirect(home: URL, now: Date) async -> ToolMembership? {
        let base = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".kimi-code")
        let credFile = base.appendingPathComponent("credentials/kimi-code.json")
        guard let data = try? Data(contentsOf: credFile), data.count <= 32_768,
              let creds = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let fileAccess = (creds["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = (creds["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresAt = (creds["expires_at"] as? NSNumber)?.doubleValue ?? 0

        let session = makeEphemeralSession(timeout: 8)
        defer { session.finishTasksAndInvalidate() }

        var accessToken: String?
        if let fileAccess, !fileAccess.isEmpty, expiresAt > now.timeIntervalSince1970 + 60 {
            accessToken = fileAccess
        } else if let refreshToken, !refreshToken.isEmpty, let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token") {
            var req = URLRequest(url: tokenURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var comps = URLComponents()
            comps.queryItems = [
                URLQueryItem(name: "client_id", value: "17e5f671-d194-4dfb-9706-5516cb48c098"),
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "refresh_token", value: refreshToken),
            ]
            req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
            if let (body, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               let fresh = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !fresh.isEmpty {
                accessToken = fresh
            }
        }
        guard let token = accessToken, let url = URL(string: "https://api.kimi.com/coding/v1/usages") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (body, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ToolMembershipSource.kimiDirectUsage(body, now: now)
    }

    private static func kimiLoopback(home: URL, now: Date) async -> ToolMembership? {
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
