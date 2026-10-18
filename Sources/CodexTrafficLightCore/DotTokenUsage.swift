import Foundation
import CryptoKit
import CoreFoundation

public struct DotTokenLedger: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var total: Int = 0
        public var observedAt: String?
        public var local: [String: Int] = [:]
        public var utc: [String: Int] = [:]
        public var recent: [String: Int] = [:]
        public var pending: [String: Int] = [:]
        public var anomalies: [String: Int] = [:]
    }
    public var entries: [String: Entry] = [:]
    public var updatedAt = ""
    public var status = "waiting"
    public var accountHash = ""
    public var lastError: String?

    public init() {}

    public static func tokenTotal(_ raw: [String: Any]) -> Int? {
        let fields = ["inputTokens", "cachedInputTokens", "outputTokens", "reasoningOutputTokens", "totalTokens"]
        var values: [String: Int] = [:]
        for key in fields {
            guard let number = raw[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= 9_007_199_254_740_991,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
            values[key] = number.intValue
        }
        guard values["inputTokens"]! + values["outputTokens"]! == values["totalTokens"]!,
              values["cachedInputTokens"]! <= values["inputTokens"]!,
              values["reasoningOutputTokens"]! <= values["outputTokens"]! else { return nil }
        return values["totalTokens"]
    }

    /// Only a non-forked thread born during this connection has a proven zero
    /// starting point. Older/unknown threads retain the lifetime baseline rule.
    @discardableResult
    public mutating func prepareFirstObservation(key: String, thread: [String: Any], observingSince: Date?, now: Date) -> Bool {
        guard entries[key] == nil, let observingSince,
              thread["forkedFromId"] is NSNull, thread["parentThreadId"] is NSNull,
              let created = thread["createdAt"] as? NSNumber,
              CFGetTypeID(created) != CFBooleanGetTypeID(), created.doubleValue.isFinite,
              created.doubleValue >= observingSince.timeIntervalSince1970,
              created.doubleValue <= now.timeIntervalSince1970 else { return false }
        let start = Date(timeIntervalSince1970: created.doubleValue)
        var entry = Entry()
        entry.observedAt = SharedDateFormatters.shared.iso8601Fractional.string(from: start)
        entry.local[SharedDateFormatters.shared.shanghaiDay.string(from: start)] = 0
        entry.utc[String(entry.observedAt!.prefix(10))] = 0
        entries[key] = entry
        return true
    }

    public mutating func observe(key: String, total: Int, baseline: Bool, now: Date) {
        var entry = entries[key] ?? Entry()
        let localDay = SharedDateFormatters.shared.shanghaiDay.string(from: now)
        let utcDay = String(SharedDateFormatters.shared.iso8601Fractional.string(from: now).prefix(10))
        // A reconnect is not a new lifetime baseline for a known thread.
        // Only attribute its gap when both accounting days are unambiguous.
        let previous = entry.observedAt.flatMap { SharedDateFormatters.shared.iso8601Date(from: $0) }
        let sameDays = previous.map {
            $0 <= now && SharedDateFormatters.shared.shanghaiDay.string(from: $0) == localDay
                && String(SharedDateFormatters.shared.iso8601Fractional.string(from: $0).prefix(10)) == utcDay
        } ?? false
        let known = entries[key] != nil
        let observed = baseline && !known ? 0 : max(0, total - entry.total)
        let ambiguous = baseline && known && !sameDays
        let delta = observed <= 20_000_000 && !ambiguous ? observed : 0
        entry.total = total
        entry.observedAt = SharedDateFormatters.shared.iso8601Fractional.string(from: now)
        if observed > 0 && (observed > 20_000_000 || ambiguous) {
            entry.pending[localDay, default: 0] += observed
            entry.anomalies[localDay, default: 0] += 1
        }
        entry.local[localDay, default: 0] += delta
        entry.utc[utcDay, default: 0] += delta
        let cutoff = SharedDateFormatters.shared.shanghaiDay.string(from: now.addingTimeInterval(-3 * 86400))
        entry.local = entry.local.filter { $0.key >= cutoff }
        entry.utc = entry.utc.filter { $0.key >= cutoff }
        entry.pending = entry.pending.filter { $0.key >= cutoff }
        entry.anomalies = entry.anomalies.filter { $0.key >= cutoff }
        updatedAt = SharedDateFormatters.shared.iso8601Fractional.string(from: now)
        entry.recent = entry.recent.filter { (SharedDateFormatters.shared.iso8601Date(from: $0.key) ?? .distantPast) >= now.addingTimeInterval(-1800) }
        if delta > 0 { entry.recent[updatedAt, default: 0] += delta }
        entries[key] = entry
        entries = entries.filter { $0.value.local.keys.contains { $0 >= cutoff } }
    }

    public static func key(account: String, thread: String) -> String {
        SHA256.hash(data: Data("wanhe-dot-v1|\(account)|\(thread)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func latestIncrementAt(now: Date = Date()) -> Date? {
        entries.values.flatMap { $0.recent.keys }.compactMap { SharedDateFormatters.shared.iso8601Date(from: $0) }
            .filter { $0 <= now && $0 >= now.addingTimeInterval(-1800) }.max()
    }

    public func merging(_ report: TodayLiveUsageReport, now: Date = Date(), nativeKeys: Set<String> = []) -> TodayLiveUsageReport {
        var result = report
        let included = entries.filter { !nativeKeys.contains($0.key) }.values
        result.tokens += included.reduce(0) { $0 + ($1.local[report.day] ?? 0) }
        result.pendingTokens = (report.pendingTokens ?? 0) + included.reduce(0) { $0 + ($1.pending[report.day] ?? 0) }
        result.anomalyCount = (report.anomalyCount ?? 0) + included.reduce(0) { $0 + ($1.anomalies[report.day] ?? 0) }
        if let utcDay = report.utcDay, let utcTokens = report.utcTokens {
            result.utcTokens = utcTokens + included.reduce(0) { $0 + ($1.utc[utcDay] ?? 0) }
        }
        result.recent30MinuteTokens = (report.recent30MinuteTokens ?? 0) + included.reduce(0) { sum, entry in
            sum + entry.recent.filter {
                (SharedDateFormatters.shared.iso8601Date(from: $0.key) ?? .distantPast) >= now.addingTimeInterval(-1800)
            }.values.reduce(0, +)
        }
        return result
    }
}

private struct DotRPCFailure: Error, Sendable { let code: Int }

public actor DotTokenUsageObserver {
    private var audit: TokenCollectionAudit { TokenCollectionAudit(root: stateURL.deletingLastPathComponent().appendingPathComponent("token-audit")) }
    private let codexHome: URL
    private let stateURL: URL
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var requestID = 0
    private var subscriptions = Set<String>()
    private var baselines = Set<String>()
    private var observingSince: Date?
    private var nextInventoryAt = Date.distantPast
    private var retryAfter: [String: Date] = [:]
    private var stage = "connect"
    private var executors = Set<String>()
    private var account = ""
    private var ledger: DotTokenLedger
    private let testThreadID: String?

    public static var stateURL: URL {
        if let path = ProcessInfo.processInfo.environment["WANHE_DOT_STATE_FILE"], path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wanhe-codex-token/dot-token-usage.json")
    }

    public static func latestActivity(now: Date = Date()) -> Date? {
        guard let data = try? Data(contentsOf: stateURL), let ledger = try? JSONDecoder().decode(DotTokenLedger.self, from: data) else { return nil }
        return ledger.latestIncrementAt(now: now)
    }

    public static func runInHelper(codexHome: URL) async {
        while !Task.isCancelled {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("codex-light-mxp")
            process.arguments = ["dot-observer"]
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": codexHome.path]
            process.environment?["WANHE_DOT_STATE_FILE"] = stateURL.path
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            await withTaskCancellationHandler {
                do {
                    try process.run()
                    while process.isRunning && !Task.isCancelled { try await Task.sleep(for: .seconds(5)) }
                } catch {}
                if process.isRunning { process.terminate() }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    public init(codexHome: URL, stateURL: URL = DotTokenUsageObserver.stateURL, testThreadID: String? = nil) {
        self.codexHome = codexHome
        self.stateURL = stateURL
        self.testThreadID = testThreadID
        ledger = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(DotTokenLedger.self, from: $0) } ?? DotTokenLedger()
    }

    public static func executorIDs(in lines: String) -> Set<String> {
        let pattern = #"^\s*(?:"[^"]*[/\\]codex"|[^\s"]*[/\\]codex|codex)\s+(?:(?:-c|--config)\s+(?:"[^"]*"|\S+)\s+)*exec-server\s+.*?--environment-id\s+(?:"([^"]+)"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return Set(lines.split(separator: "\n").compactMap { row in
            let line = String(row)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            for index in [1, 2] { if let range = Range(match.range(at: index), in: line) { return String(line[range]) } }
            return nil
        })
    }

    public static func isLocalDotThread(_ thread: [String: Any], executors: Set<String>, now: Date = Date()) -> Bool {
        guard thread["originator"] as? String == "codex_work_cca", thread["threadSource"] as? String == "aeon_child",
              thread["path"] == nil || thread["path"] is NSNull, thread["ephemeral"] as? Bool != true,
              let environments = thread["environments"] as? [[String: Any]], environments.count == 1,
              let environment = environments[0]["environmentId"] as? String, executors.contains(environment),
              let updated = thread["updatedAt"] as? NSNumber, updated.doubleValue.isFinite,
              updated.doubleValue >= now.timeIntervalSince1970 - 86400,
              updated.doubleValue <= now.timeIntervalSince1970 + 300 else { return false }
        return true
    }

    private func localExecutors() -> Set<String> {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return Self.executorIDs(in: String(decoding: data, as: UTF8.self))
    }

    private func auth() -> (String, String)? {
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = raw["tokens"] as? [String: String],
              let token = tokens["access_token"], let account = tokens["account_id"] else { return nil }
        return (token, account)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ledger) { try? data.write(to: stateURL, options: .atomic) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func setStatus(_ status: String) {
        if ledger.status != status {
            ledger.status = status; save()
            audit.append([.init(source: "dot_local", kind: "connection", reason: status == "connected" ? "connected" : "unavailable", account: ledger.accountHash)])
        }
    }

    public func run() async {
        while !Task.isCancelled {
            executors = localExecutors()
            guard (!executors.isEmpty || testThreadID != nil), let (token, currentAccount) = auth() else {
                setStatus("waiting")
                try? await Task.sleep(for: .seconds(30)); continue
            }
            do {
                account = currentAccount
                stage = "connect"
                let hash = DotTokenLedger.key(account: account, thread: "account")
                if ledger.accountHash != hash { ledger = DotTokenLedger(); ledger.accountHash = hash; save() }
                var request = URLRequest(url: URL(string: "wss://codex-cloud-backend.chatgpt.com/")!)
                request.setValue("codex-app-server, codex-client.desktop, openai-bearer.\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
                request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
                request.setValue("codex", forHTTPHeaderField: "X-OpenAI-Product-Sku")
                request.setValue("wanhe-dot-usage", forHTTPHeaderField: "originator")
                let task = URLSession.shared.webSocketTask(with: request)
                socket = task; task.resume()
                receiver = Task { await self.receive(task) }
                _ = try await rpc("initialize", ["clientInfo": ["name": "wanhe_dot_usage", "version": ClientVersion.current], "capabilities": ["experimentalApi": true]])
                try await task.send(.string(#"{"method":"initialized","params":{}}"#))
                if let testThreadID {
                    let data = try await rpc("thread/read", ["threadId": testThreadID, "includeTurns": false])
                    let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let thread = result?["thread"] as? [String: Any]
                    let environments = thread?["environments"] as? [[String: Any]] ?? []
                    executors = Set(environments.compactMap { $0["environmentId"] as? String })
                    guard !executors.isEmpty else { throw URLError(.badServerResponse) }
                }
                observingSince = Date()
                setStatus("connected")
                audit.append(ledger.entries.map { key, entry in
                    .init(source: "dot_local", kind: "baseline", reason: "audit_enabled", key: key, account: ledger.accountHash, eventAt: entry.observedAt, values: ["cumulative": entry.total])
                })
                ledger.lastError = nil
                save()
                while !Task.isCancelled {
                    guard let (latestToken, latestAccount) = auth(), latestToken == token, latestAccount == account else { break }
                    let latest = testThreadID == nil ? localExecutors() : executors
                    guard latest == executors else { break }
                    try await discover()
                    do { try await inventoryOtherSources() }
                    catch { audit.append([.init(source: "collector", kind: "failure", reason: "inventory_unavailable", account: ledger.accountHash)]) }
                    try await Task.sleep(for: .seconds(5))
                }
            } catch {
                if !Task.isCancelled {
                    let code = (error as? DotRPCFailure)?.code ?? (error as NSError).code
                    ledger.lastError = "\(stage):\(code)"
                    ledger.status = "unavailable"
                    save()
                }
            }
            disconnect()
            try? await Task.sleep(for: .seconds(10))
        }
        disconnect()
    }

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        guard let transport = socket else { throw URLError(.notConnectedToInternet) }
        stage = method
        requestID += 1
        let id = requestID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { do { try await transport.send(.data(data)) } catch { fail(id) } }
                Task {
                    try? await Task.sleep(for: .seconds(15))
                    fail(id)
                }
            }
        } onCancel: {
            Task { await self.fail(id) }
        }
    }

    private func fail(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: URLError(.timedOut))
    }

    private func disconnect() {
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        for id in Array(pending.keys) { fail(id) }
        if observingSince != nil { audit.append([.init(source: "dot_local", kind: "connection", reason: "disconnected", account: ledger.accountHash)]) }
        subscriptions.removeAll(); baselines.removeAll(); retryAfter.removeAll(); observingSince = nil
    }

    /// Inventory metadata only; unsupported source token counts remain unknown.
    private func inventoryOtherSources() async throws {
        let now = Date()
        guard now >= nextInventoryAt else { return }
        nextInventoryAt = now.addingTimeInterval(900)
        var records: [TokenCollectionAudit.Record] = []
        for archived in [false, true] {
            var cursor: String?
            for _ in 0..<10 {
                let data = try await rpc("thread/list", ["archived": archived, "limit": 100, "sortKey": "updated_at", "sortDirection": "desc", "cursor": cursor as Any? ?? NSNull()])
                let page = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                for thread in page["data"] as? [[String: Any]] ?? [] {
                    guard !Self.isLocalDotThread(thread, executors: executors, now: now), let id = thread["id"] as? String,
                          let updated = thread["updatedAt"] as? NSNumber, updated.doubleValue.isFinite,
                          updated.doubleValue >= now.timeIntervalSince1970 - 86400, updated.doubleValue <= now.timeIntervalSince1970 + 300 else { continue }
                    let origin = thread["originator"] as? String ?? "other"
                    let source = origin == "codex_work_cca" && thread["threadSource"] as? String == "aeon_child" ? "dot_other_device" : "cloud_other"
                    var r = TokenCollectionAudit.Record(source: source, kind: "excluded", reason: "unsupported_source", key: DotTokenLedger.key(account: account, thread: id), account: ledger.accountHash, values: ["sourceUpdatedAt": Int(updated.doubleValue)])
                    r.origin = ["codex_cloud", "codex_work_mobile", "codex_work_web", "codex_work_cca"].contains(origin) ? origin : "other"
                    if let parent = thread["parentThreadId"] as? String { r.parent = DotTokenLedger.key(account: account, thread: parent) }
                    records.append(r)
                }
                cursor = page["nextCursor"] as? String
                if cursor == nil { break }
            }
            if cursor != nil { records.append(.init(source: "collector", kind: "failure", reason: "inventory_limit", account: ledger.accountHash)) }
        }
        audit.append(records)
    }

    private func discover() async throws {
        var cursor: String?
        for _ in 0..<10 {
            try Task.checkCancellation()
            let data = try await rpc("thread/list", ["archived": false, "limit": 100, "sortKey": "updated_at", "sortDirection": "desc", "originators": ["codex_work_cca"], "cursor": cursor as Any? ?? NSNull()])
            let page = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            for thread in page["data"] as? [[String: Any]] ?? [] {
                guard Self.isLocalDotThread(thread, executors: executors), let id = thread["id"] as? String,
                      (retryAfter[id] ?? .distantPast) <= Date(),
                      !subscriptions.contains(id) else { continue }
                let key = DotTokenLedger.key(account: account, thread: id)
                if ledger.prepareFirstObservation(key: key, thread: thread, observingSince: observingSince, now: Date()) {
                    audit.append([.init(source: "dot_local", kind: "baseline", reason: "fresh_zero", key: key, account: ledger.accountHash, values: ["cumulative": 0])]); save()
                }
                subscriptions.insert(id)
                do {
                    _ = try await rpc("thread/resume", ["threadId": id, "excludeTurns": true])
                } catch let error as DotRPCFailure {
                    subscriptions.remove(id)
                    retryAfter[id] = Date().addingTimeInterval(60)
                    ledger.lastError = "thread/resume:\(error.code)"
                    save()
                }
            }
            cursor = page["nextCursor"] as? String
            if cursor == nil { break }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let frame = try await task.receive()
                guard socket === task, !Task.isCancelled else { return }
                let data: Data
                switch frame { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                    if let error = message["error"] as? [String: Any] { continuation.resume(throwing: DotRPCFailure(code: error["code"] as? Int ?? -1)) }
                    else { continuation.resume(returning: try JSONSerialization.data(withJSONObject: message["result"] ?? [:])) }
                    continue
                }
                guard message["method"] as? String == "thread/tokenUsage/updated",
                      let params = message["params"] as? [String: Any], let thread = params["threadId"] as? String,
                      subscriptions.contains(thread), let usage = params["tokenUsage"] as? [String: Any],
                      let raw = usage["total"] as? [String: Any], let total = DotTokenLedger.tokenTotal(raw) else { continue }
                let now = Date(), key = DotTokenLedger.key(account: account, thread: thread)
                let previous = ledger.entries[key], baseline = baselines.insert(thread).inserted
                ledger.observe(key: key, total: total, baseline: baseline, now: now)
                let day = SharedDateFormatters.shared.shanghaiDay.string(from: now)
                let entry = ledger.entries[key]!
                let counted = (entry.local[day] ?? 0) - (previous?.local[day] ?? 0)
                let pending = (entry.pending[day] ?? 0) - (previous?.pending[day] ?? 0)
                var values = ["cumulative": total, "counted": counted, "pending": pending]
                if let previous { values["previous"] = previous.total; values["delta"] = max(0, total - previous.total) }
                for (field, name) in [("inputTokens", "input"), ("cachedInputTokens", "cached"), ("outputTokens", "output"), ("reasoningOutputTokens", "reasoning"), ("cacheWriteInputTokens", "cacheWrite")] {
                    if let value = raw[field] as? Int { values[name] = value }
                }
                let reason = previous == nil && baseline ? "first_existing" : total < (previous?.total ?? 0) ? "cumulative_reset" : pending > 0 ? "unattributed_or_large" : counted > 0 ? "confirmed" : "duplicate"
                audit.append([.init(source: "dot_local", kind: counted > 0 ? "increment" : pending > 0 ? "pending" : previous == nil ? "baseline" : "excluded", reason: reason, key: key, account: ledger.accountHash, values: values, now: now)])
                save()
            }
        } catch { if socket === task { for id in Array(pending.keys) { fail(id) } } }
    }

    public static func merging(_ report: TodayLiveUsageReport, codexHome: URL, index: CodexSessionFileIndex) -> TodayLiveUsageReport {
        guard let data = try? Data(contentsOf: stateURL), let ledger = try? JSONDecoder().decode(DotTokenLedger.self, from: data),
              let auth = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
              let object = try? JSONSerialization.jsonObject(with: auth) as? [String: Any],
              let tokens = object["tokens"] as? [String: String], let account = tokens["account_id"],
              ledger.accountHash == DotTokenLedger.key(account: account, thread: "account") else { return report }
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        let nativeKeys = Set(index.files.compactMap { file -> String? in
            let name = file.url.lastPathComponent
            guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
            return DotTokenLedger.key(account: account, thread: String(name[range]))
        })
        TokenCollectionAudit(root: stateURL.deletingLastPathComponent().appendingPathComponent("token-audit")).append(ledger.entries.keys.filter { nativeKeys.contains($0) }.map {
            .init(source: "dot_local", kind: "excluded", reason: "native_overlap", key: $0, account: ledger.accountHash)
        })
        return ledger.merging(report, nativeKeys: nativeKeys)
    }
}
