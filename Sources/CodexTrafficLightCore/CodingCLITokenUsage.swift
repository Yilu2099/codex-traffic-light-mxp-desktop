import CryptoKit
import Foundation

// Read only recorded turn/message metadata, never context-size snapshots or credentials.
enum CodingCLITokenUsage {
    private struct GeminiRecord: Decodable {
        struct Tokens: Decodable {
            let input, output, cached, thoughts, tool, total: Int?
        }

        struct Update: Decodable {
            let messages: [GeminiRecord]?
        }

        let sessionId, id, type, timestamp: String?
        let tokens: Tokens?
        let messages: [GeminiRecord]?
        let update: Update?

        enum CodingKeys: String, CodingKey {
            case sessionId, id, type, timestamp, tokens, messages
            case update = "$set"
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try? fields.decode(String.self, forKey: .sessionId)
            id = try? fields.decode(String.self, forKey: .id)
            type = try? fields.decode(String.self, forKey: .type)
            timestamp = try? fields.decode(String.self, forKey: .timestamp)
            tokens = try? fields.decode(Tokens.self, forKey: .tokens)
            messages = try? fields.decode([GeminiRecord].self, forKey: .messages)
            update = try? fields.decode(Update.self, forKey: .update)
        }
    }

    private struct GrokRecord: Decodable {
        struct Params: Decodable {
            struct Meta: Decodable {
                let eventId: String?
                let agentTimestampMs: Double?
            }

            struct Update: Decodable {
                let sessionUpdate: String
                let usage: Usage?
            }

            let sessionId: String?
            let update: Update
            let meta: Meta?

            enum CodingKeys: String, CodingKey {
                case sessionId, update
                case meta = "_meta"
            }
        }

        struct Usage: Decodable {
            let inputTokens, outputTokens, cachedReadTokens, cacheCreationTokens, reasoningTokens, totalTokens: Int?
            let modelUsage: [String: Usage]?
        }

        let timestamp: Double?
        let params: Params
    }

    private static let maxTokens = 1_000_000_000_000

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).description
    }

    static func geminiChatRoots(home: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        func isDirectory(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: keys)
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        return [".gemini/tmp", ".cache/.gemini/tmp"].flatMap { path in
            let root = home.appendingPathComponent(path)
            let projects = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )) ?? []
            return projects.filter(isDirectory).map { $0.appendingPathComponent("chats") }.filter(isDirectory)
        }
    }

    static func read(
        _ file: URL, tool: String, cutoff: Date, now: Date, day: (Date) -> String
    ) -> [String: ToolDailyUsage] {
        let decoder = JSONDecoder()
        var rows: [String: ToolDailyUsage] = [:]

        func store(id: String, date: Date, input: Int, cached: Int, write: Int, output: Int) {
            guard date >= cutoff, date <= now else { return }
            let row = ToolDailyUsage(tool: tool, day: day(date), inputTokens: input,
                                     cachedInputTokens: cached, cacheWriteInputTokens: write, outputTokens: output)
            if row.totalTokens > 0 {
                rows[tool + ":" + hash(id)] = row
            }
        }

        if tool == "gemini" {
            let iso = ISO8601DateFormatter()
            iso.formatOptions.insert(.withFractionalSeconds)
            let wholeSeconds = ISO8601DateFormatter()
            var session = ""

            func recordMessage(_ message: GeminiRecord) {
                guard !session.isEmpty, message.type == "gemini", let id = message.id, !id.isEmpty,
                      let stamp = message.timestamp, let date = iso.date(from: stamp) ?? wholeSeconds.date(from: stamp),
                      let tokens = message.tokens,
                      valid([tokens.input, tokens.output, tokens.cached, tokens.thoughts, tokens.tool, tokens.total])
                else { return }
                let cached = tokens.cached ?? 0
                var input = (tokens.input ?? 0) + (tokens.tool ?? 0)
                let output = (tokens.output ?? 0) + (tokens.thoughts ?? 0)
                if let total = tokens.total, total > 0 {
                    // Google prompt tokens include cache reads. Accept legacy exclusive
                    // counters when their authoritative total proves the decomposition.
                    if cached > 0, total == input + output + cached { input += cached }
                    guard total == input + output else { return }
                }
                guard cached <= input else { return }
                store(id: session + ":" + id, date: date, input: input, cached: cached, write: 0, output: output)
            }

            func record(_ envelope: GeminiRecord) {
                if let id = envelope.sessionId { session = id }
                (envelope.messages ?? envelope.update?.messages ?? [envelope]).forEach(recordMessage)
            }

            if file.pathExtension == "json" {
                // Legacy sessions are whole JSON documents. Keep a bound on allocations.
                let bound = 64 * 1024 * 1024
                if let attributes = try? file.resourceValues(forKeys: [.fileSizeKey]),
                   let size = attributes.fileSize, size <= bound,
                   let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                   data.count <= bound, let envelope = try? decoder.decode(GeminiRecord.self, from: data) {
                    record(envelope)
                }
            } else {
                readLines(file) { line in
                    if let envelope = try? decoder.decode(GeminiRecord.self, from: line) { record(envelope) }
                }
            }
        } else {
            readLines(file) { line in
                guard let envelope = try? decoder.decode(GrokRecord.self, from: line),
                      envelope.params.update.sessionUpdate == "turn_completed",
                      let usage = envelope.params.update.usage
                else { return }
                let meta = envelope.params.meta
                let seconds = meta?.agentTimestampMs.flatMap { $0 > 0 ? $0 / 1000 : nil } ?? envelope.timestamp ?? 0
                guard seconds.isFinite, seconds > 0 else { return }
                let date = Date(timeIntervalSince1970: seconds)
                let session = envelope.params.sessionId ?? file.deletingLastPathComponent().lastPathComponent
                guard !session.isEmpty else { return }
                let counts = normalizedGrok(usage)
                guard let counts else { return }
                let id = meta?.eventId.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "\(seconds):\(counts.fingerprint)"
                store(id: session + ":" + id, date: date, input: counts.input, cached: counts.cached,
                      write: counts.write, output: counts.output)
            }
        }
        return rows
    }

    private static func valid(_ values: [Int?]) -> Bool {
        values.compactMap { $0 }.allSatisfy { (0...maxTokens).contains($0) }
    }

    private static func normalizedGrok(_ usage: GrokRecord.Usage) -> (input: Int, cached: Int, write: Int, output: Int, fingerprint: String)? {
        // A completed turn may have either model splits or the aggregate. Use one,
        // otherwise the same requests would be counted twice.
        let models = usage.modelUsage ?? [:]
        let records = models.isEmpty ? [("", usage)] : models.sorted { $0.key < $1.key }
        var totals = (input: 0, cached: 0, write: 0, output: 0)
        var fingerprints: [String] = []
        for (model, record) in records {
            guard valid([record.inputTokens, record.outputTokens, record.cachedReadTokens,
                         record.cacheCreationTokens, record.reasoningTokens, record.totalTokens]) else { return nil }
            let input = record.inputTokens ?? 0, output = record.outputTokens ?? 0
            let cached = record.cachedReadTokens ?? 0, write = record.cacheCreationTokens ?? 0
            let reasoning = record.reasoningTokens ?? 0
            guard cached + write <= input, reasoning <= output,
                  record.totalTokens.map({ $0 == 0 || $0 == input + output }) ?? true,
                  totals.input + totals.write + input <= maxTokens, totals.output + output <= maxTokens
            else { return nil }
            // Both cache fields are included in Grok's input; reasoning is included in output.
            totals.input += input - write
            totals.cached += cached
            totals.write += write
            totals.output += output
            fingerprints.append("\(model):\(input):\(cached):\(write):\(output):\(reasoning)")
        }
        if let total = usage.totalTokens, total > 0, total != totals.input + totals.write + totals.output { return nil }
        return (totals.input, totals.cached, totals.write, totals.output, fingerprints.joined(separator: "|"))
    }

    private static func readLines(_ file: URL, _ consume: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let maxLineSize = 16 * 1024 * 1024
        var pending = Data()
        var oversized = false
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            var start = chunk.startIndex
            for end in chunk.indices where chunk[end] == 10 {
                if !oversized, pending.count + end - start <= maxLineSize {
                    pending.append(contentsOf: chunk[start..<end])
                    consume(pending)
                }
                pending.removeAll(keepingCapacity: true)
                oversized = false
                start = end + 1
            }
            if !oversized, pending.count + chunk.endIndex - start <= maxLineSize {
                pending.append(contentsOf: chunk[start...])
            } else {
                pending.removeAll(keepingCapacity: true)
                oversized = true
            }
        }
        // An unterminated tail may still be in flight.
    }
}
