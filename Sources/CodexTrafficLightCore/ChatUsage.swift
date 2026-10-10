import Foundation
import CryptoKit

public struct ChatUsageRow: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var weeklyPercent: Double?
    public var credits: Double?
    public var subagents: Int
}

public struct ChatUsageReport: Codable, Equatable, Sendable {
    public var collectedAt: String
    public var dataAsOf: String?
    public var rows: [ChatUsageRow]
}

/// Titles and official percentages only. Credentials and conversation text stay on-device.
public enum ChatUsageCollector {
    public static func cached(codexHome: URL, now: Date = Date()) -> ChatUsageReport? {
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")), let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tokens = auth["tokens"] as? [String: String], let account = tokens["account_id"] else { return nil }
        let key = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wanhe-codex-token/chat-usage-\(key).json")
        let attempt = cache.appendingPathExtension("attempt")
        let old = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode(ChatUsageReport.self, from: $0) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: attempt.path)[.modificationDate]) as? Date
        let attemptVersion = try? String(contentsOf: attempt, encoding: .utf8)
        let retryAfter: TimeInterval = old == nil || FileManager.default.fileExists(atPath: cache.appendingPathExtension("error").path) ? 300 : 1800
        if let modified, attemptVersion == ClientVersion.current, now.timeIntervalSince(modified) < retryAfter { return old }
        try? Data(ClientVersion.current.utf8).write(to: attempt, options: .atomic)
        let fresh: ChatUsageReport
        do { fresh = try fetch(codexHome: codexHome, now: now) }
        catch {
            let code: String
            switch error {
            case CodexAppServerQuotaError.invalidJSON: code = "rpc_incomplete_json"
            case CodexAppServerQuotaError.appServerReturnedError: code = "rpc_unavailable"
            case OfficialCodexUsageError.usageTimedOut: code = "collection_timeout"
            default: code = "collection_unavailable"
            }
            try? Data(code.utf8).write(to: cache.appendingPathExtension("error"), options: .atomic)
            return old
        }
        try? FileManager.default.removeItem(at: cache.appendingPathExtension("error"))
        if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: cache, options: .atomic) }
        return fresh
    }

    public static func fetch(codexHome: URL, now: Date = Date()) throws -> ChatUsageReport {
        let auth = try JSONSerialization.jsonObject(with: Data(contentsOf: codexHome.appendingPathComponent("auth.json"))) as? [String: Any]
        guard let tokens = auth?["tokens"] as? [String: String], let access = tokens["access_token"], let account = tokens["account_id"] else {
            throw OfficialCodexUsageError.invalidResponse
        }
        let rpc = try ChatUsageRPC(codexHome: codexHome)
        defer { rpc.close() }
        let cutoff = now.addingTimeInterval(-30 * 86400).timeIntervalSince1970
        var roots: [[String: Any]] = [], cursor: String?, seen = Set<String>()
        repeat {
            let page = try rpc.call("thread/list", ["limit": 100, "sortKey": "updated_at", "useStateDbOnly": true, "archived": false, "cursor": cursor as Any? ?? NSNull()])
            let rows = page["data"] as? [[String: Any]] ?? []
            roots += rows.filter { ($0["name"] as? String)?.isEmpty == false && ($0["parentThreadId"] == nil || $0["parentThreadId"] is NSNull) && ($0["updatedAt"] as? Double ?? 0) >= cutoff }
            cursor = page["nextCursor"] as? String
            if rows.contains(where: { ($0["updatedAt"] as? Double ?? 0) < cutoff }) { break }
            if let cursor, !seen.insert(cursor).inserted { throw OfficialCodexUsageError.invalidResponse }
        } while roots.count < 30 && cursor != nil
        roots = Array(roots.prefix(30))
        var query: [[String: Any]] = [], counts: [String: Int] = [:], allIDs = Set<String>()
        for root in roots {
            guard let id = root["id"] as? String else { throw OfficialCodexUsageError.invalidResponse }
            var descendants = Set<String>()
            for archived in [false, true] {
                cursor = nil; seen = []
                repeat {
                    let page = try rpc.call("thread/list", ["ancestorThreadId": id, "archived": archived, "limit": 100, "useStateDbOnly": true,
                        "sourceKinds": ["subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther"], "cursor": cursor as Any? ?? NSNull()])
                    descendants.formUnion((page["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
                    cursor = page["nextCursor"] as? String
                    if descendants.count >= 1000 || (cursor != nil && !seen.insert(cursor!).inserted) { throw OfficialCodexUsageError.invalidResponse }
                } while cursor != nil
            }
            let ids = descendants.union([id])
            guard allIDs.isDisjoint(with: ids) else { throw OfficialCodexUsageError.invalidResponse }
            allIDs.formUnion(ids); counts[id] = descendants.count
            query.append(["thread_id": id, "created_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: root["createdAt"] as? Double ?? 0)), "descendant_thread_ids": Array(descendants)])
        }
        var usage: [String: [String: Any]] = [:], timestamps: [String] = []
        // Bound the number of identities in each request to the same limit used by the app.
        var batches: [[[String: Any]]] = [], batch: [[String: Any]] = [], count = 0
        for item in query {
            let size = 1 + (item["descendant_thread_ids"] as? [String] ?? []).count
            if count + size > 1000 { batches.append(batch); batch = []; count = 0 }
            batch.append(item); count += size
        }
        if !batch.isEmpty { batches.append(batch) }
        for batch in batches {
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage/thread_usage/query_v2")!)
            request.httpMethod = "POST"; request.timeoutInterval = 30
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-ID")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["threads": batch])
            let box = ChatUsageBuffer(), done = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                if (response as? HTTPURLResponse)?.statusCode == 200, let data { box.append(data) }
                done.signal()
            }
            task.resume()
            guard done.wait(timeout: .now() + 35) == .success else { task.cancel(); throw OfficialCodexUsageError.usageTimedOut }
            guard let result = try JSONSerialization.jsonObject(with: box.snapshot()) as? [String: Any], let rows = result["threads"] as? [[String: Any]] else { throw OfficialCodexUsageError.invalidResponse }
            if let timestamp = result["data_as_of"] as? String { timestamps.append(timestamp) }
            for row in rows { if let id = row["thread_id"] as? String { usage[id] = row } }
        }
        let rows = roots.map { root -> ChatUsageRow in
            let id = root["id"] as? String ?? "", raw = usage[id] ?? [:]
            let available = raw["data_status"] as? String == "available"
            func number(_ key: String) -> Double? { guard available else { return nil }; return (raw[key] as? NSNumber)?.doubleValue ?? (raw[key] as? String).flatMap(Double.init) }
            return ChatUsageRow(id: SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined(), title: String((root["name"] as? String ?? "未命名聊天").prefix(200)), weeklyPercent: number("weekly_limit_percent"), credits: number("balance_usage_credits"), subagents: counts[id] ?? 0)
        }
        return ChatUsageReport(collectedAt: ISO8601DateFormatter().string(from: now), dataAsOf: timestamps.count == batches.count ? timestamps.min() : nil, rows: rows)
    }
}

private final class ChatUsageBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk) }
    // Pipe reads may end inside a UTF-8 character or JSON object. Parse complete lines only.
    func takeLines() -> Data {
        lock.lock(); defer { lock.unlock() }
        let lines = CodexAppServerJSONRPCLineCodec.completeLinePrefix(from: data)
        data.removeFirst(lines.count)
        return lines
    }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class ChatUsageRPC {
    private let process = Process(), input = Pipe(), output = Pipe(), buffer = ChatUsageBuffer()
    private var id = 0
    private let deadline = Date().addingTimeInterval(90)
    init(codexHome: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [OfficialCodexUsageCollector.defaultCodexBinary(), "app-server", "--stdio"]
        process.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": codexHome.path]) { _, new in new }
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let buffer = self.buffer
        output.fileHandleForReading.readabilityHandler = { handle in let data = handle.availableData; if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) } }
        try process.run()
        do {
            _ = try call("initialize", ["clientInfo": ["name": "wanhe-chat-usage", "version": "1.0"], "capabilities": ["experimentalApi": true]])
            try input.fileHandleForWriting.write(contentsOf: CodexAppServerJSONRPCLineCodec.encodeMessage(["method": "initialized", "params": [:]]))
        }
        catch { close(); throw error }
    }
    func close() { output.fileHandleForReading.readabilityHandler = nil; if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close() }
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        id += 1
        try input.fileHandleForWriting.write(contentsOf: CodexAppServerJSONRPCLineCodec.encodeRequest(id: id, method: method, params: params))
        let until = min(deadline, Date().addingTimeInterval(15))
        while Date() < until && process.isRunning {
            let messages = try CodexAppServerJSONRPCLineCodec.decodeMessages(from: buffer.takeLines())
            do {
                let result = try CodexAppServerJSONRPCLineCodec.resultData(forID: id, in: messages)
                if let object = try JSONSerialization.jsonObject(with: result) as? [String: Any] { return object }
                throw OfficialCodexUsageError.invalidResponse
            } catch CodexAppServerQuotaError.responseNotFound { }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw OfficialCodexUsageError.usageTimedOut
    }
}
