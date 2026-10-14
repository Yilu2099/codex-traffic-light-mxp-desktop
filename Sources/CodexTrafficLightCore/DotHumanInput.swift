import Foundation
import CryptoKit

public enum DotInputError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return "Dot 只读核对未完成（\(reason)）"
    }
}

// No send, login, refresh, read-receipt or subscription operation exists here.
public protocol DotInputReadTransport: Sendable {
    func get(_ path: String, query: [String: String]) async throws -> Data
    func route(origin: String, override: String) async throws
}

private final class DotNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct DotInputIdentity: Sendable {
    let account: String
    let user: String
    fileprivate let token: String
    public init(codexHome: URL) throws {
        struct Auth: Decodable { struct Tokens: Decodable { let access_token: String; let account_id: String }; let tokens: Tokens }
        let auth = try JSONDecoder().decode(Auth.self, from: Data(contentsOf: codexHome.appendingPathComponent("auth.json")))
        let parts = auth.tokens.access_token.split(separator: ".")
        guard parts.count == 3 else { throw DotInputError.unavailable("auth_shape") }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let claims = raw["https://api.openai.com/auth"] as? [String: Any],
              let account = (claims["chatgpt_account_id"] ?? claims["account_id"]) as? String,
              account == auth.tokens.account_id,
              let user = (claims["user_id"] ?? claims["chatgpt_user_id"]) as? String, !user.isEmpty else {
            throw DotInputError.unavailable("account_identity")
        }
        self.account = account; self.user = user; self.token = auth.tokens.access_token
    }
    // Synthetic identity only; callers still have to pass authenticated membership and room checks.
    public init(account: String, user: String) { self.account = account; self.user = user; self.token = "" }
}

public actor DotInputHTTP: DotInputReadTransport {
    private let identity: DotInputIdentity
    private let session: URLSession
    private var origin = "https://chatgpt.com"
    private var override = "NO_CONSTRAINT"
    public init(identity: DotInputIdentity) {
        self.identity = identity
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: DotNoRedirect(), delegateQueue: nil)
    }
    public func route(origin: String, override: String) throws {
        guard ["https://chatgpt.com", "https://gov.chatgpt.com"].contains(origin),
              ["NO_CONSTRAINT", "us", "us_cr"].contains(override) else { throw DotInputError.unavailable("route") }
        self.origin = origin; self.override = override
    }
    public func get(_ path: String, query: [String: String]) async throws -> Data {
        let valid = path == "/wham/accounts/check" || path == "/tbo/primary"
            || path.range(of: #"^/messaging/rooms/[A-Za-z0-9_-]+(/messages)?$"#, options: .regularExpression) != nil
        guard valid, Set(query.keys).isSubset(of: ["limit", "before"]), !identity.token.isEmpty,
              var url = URLComponents(string: origin + "/backend-api" + path) else { throw DotInputError.unavailable("read_scope") }
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer " + identity.token, forHTTPHeaderField: "Authorization")
        request.setValue(identity.account, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("wanhe-readonly-statistics", forHTTPHeaderField: "originator")
        if override != "NO_CONSTRAINT" { request.setValue(override, forHTTPHeaderField: "X-OpenAI-Account-Routing-Override") }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch { throw DotInputError.unavailable("transport") }
        guard let response = result.1 as? HTTPURLResponse, response.statusCode == 200 else {
            throw DotInputError.unavailable("http_\((result.1 as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard result.0.count <= 2 * 1024 * 1024,
              response.mimeType?.contains("json") == true else { throw DotInputError.unavailable("response_shape") }
        return result.0
    }
}

public struct HumanInputEvent: Codable, Equatable, Sendable {
    public var eventKey: String
    public var sourceAt: String
    public var source: String
    public var classification: String
    public var trigger: String?
    public init(eventKey: String, sourceAt: String, source: String, classification: String, trigger: String? = nil) {
        self.eventKey = eventKey; self.sourceAt = sourceAt; self.source = source
        self.classification = classification; self.trigger = trigger
    }
}

public struct DotInputReport: Encodable, Sendable {
    public let schema = "dot_human_input_pilot_v1"
    public var collectedAt: String
    public var identityVerified: Bool
    public var pages: Int
    public var windowLimited: Bool
    public var ownerMessages: [HumanInputEvent]
    public var excludedDotMessages: Int
    public var excludedAutomaticMessages: Int
    public var invalidMessages: Int
    public var lastOwnerMessageAt: String? { ownerMessages.max { (parseDotInputDate($0.sourceAt) ?? .distantPast) < (parseDotInputDate($1.sourceAt) ?? .distantPast) }?.sourceAt }
    enum CodingKeys: String, CodingKey {
        case schema, collectedAt, identityVerified, pages, windowLimited, ownerMessages
        case excludedDotMessages, excludedAutomaticMessages, invalidMessages, lastOwnerMessageAt
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(collectedAt, forKey: .collectedAt)
        try c.encode(identityVerified, forKey: .identityVerified); try c.encode(pages, forKey: .pages)
        try c.encode(windowLimited, forKey: .windowLimited); try c.encode(ownerMessages, forKey: .ownerMessages)
        try c.encode(excludedDotMessages, forKey: .excludedDotMessages)
        try c.encode(excludedAutomaticMessages, forKey: .excludedAutomaticMessages)
        try c.encode(invalidMessages, forKey: .invalidMessages)
        try c.encodeIfPresent(lastOwnerMessageAt, forKey: .lastOwnerMessageAt)
    }
}

public enum HumanInputSource {
    public static func automatic(_ trigger: String?) -> Bool {
        guard let trigger else { return false }
        return trigger.hasPrefix("automation_") || ["persistent_mode", "safety_buffer_retry"].contains(trigger)
    }
    public static func classification(trigger: String?) -> String {
        if automatic(trigger) { return "automatic" }
        if ["composer", "page_composer", "composer_queue", "composer_queue_run_now", "user", "realtime", "edit_user_message"].contains(trigger ?? "") { return "user_submission" }
        return "source_unknown"
    }
}

public struct DotInputCollector: Sendable {
    public init() {}
    private struct Accounts: Decodable {
        struct Account: Decodable { let id: String; let account_user_id: String?; let structure: String; let workspace_backend_origin: String; let account_routing_override: String; let is_deactivated: Bool?; let can_access_with_session: Bool? }
        let accounts: [Account]
    }
    private struct Primary: Decodable {
        struct Selection: Decodable { let aeon_id: String; let messaging_room_id: String; let thread_id: String; let available: Bool }
        struct Profile: Decodable { let id: String; let messaging_room_id: String; let active_root_thread_id: String? }
        let selection: Selection; let profile: Profile
    }
    private struct Room: Decodable {
        struct Member: Decodable { let account_user_id: String; let aeon_id: String? }
        let id: String; let type: String; let app_source: String; let aeon_id: String; let members: [Member]
    }
    private struct Page: Decodable {
        // Chat text, previews, attachments and raw assistant messages are not decoded.
        struct Message: Decodable {
            struct Metadata: Decodable { let turn_trigger: String? }
            let id: String; let room_id: String?; let account_user_id: String?
            let role: String?; let created_at: String?; let deleted_at: String?
            let message_metadata: Metadata?
        }
        let items: [Message]; let prev_cursor: String?
    }
    public func collect(identity: DotInputIdentity, transport: any DotInputReadTransport,
                        salt: Data, maxPages: Int = 3, now: Date = Date()) async throws -> DotInputReport {
        guard salt.count >= 16 else { throw DotInputError.unavailable("private_salt") }
        let began = ProcessInfo.processInfo.systemUptime
        let decoder = JSONDecoder()
        let accounts = try decoder.decode(Accounts.self, from: await transport.get("/wham/accounts/check", query: [:]))
        let selected = accounts.accounts.filter { $0.id == identity.account }
        guard selected.count == 1, selected[0].is_deactivated != true,
              selected[0].can_access_with_session != false else { throw DotInputError.unavailable("membership") }
        let account = selected[0]
        let owner = account.structure == "personal" ? identity.user : account.account_user_id
        guard let owner, !owner.isEmpty else { throw DotInputError.unavailable("owner") }
        try await transport.route(origin: account.workspace_backend_origin == "NO_CONSTRAINT" ? "https://chatgpt.com" : account.workspace_backend_origin, override: account.account_routing_override)
        let primary = try decoder.decode(Primary.self, from: await transport.get("/tbo/primary", query: [:]))
        guard primary.selection.available, primary.selection.aeon_id == primary.profile.id,
              primary.selection.messaging_room_id == primary.profile.messaging_room_id,
              primary.profile.active_root_thread_id == nil || primary.profile.active_root_thread_id == primary.selection.thread_id else { throw DotInputError.unavailable("selection") }
        let roomID = primary.profile.messaging_room_id
        guard roomID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw DotInputError.unavailable("room_identifier") }
        let path = "/messaging/rooms/" + roomID
        let room = try decoder.decode(Room.self, from: await transport.get(path, query: [:]))
        let dotMembers = room.members.filter { $0.aeon_id == primary.profile.id }
        guard room.id == roomID, room.type == "DM", room.app_source == "chatgpt:messaging",
              room.aeon_id == primary.profile.id, room.members.filter({ $0.account_user_id == owner }).count == 1,
              dotMembers.count == 1, dotMembers[0].account_user_id != owner else { throw DotInputError.unavailable("room_identity") }
        var report = DotInputReport(collectedAt: iso(now), identityVerified: true, pages: 0, windowLimited: false,
                                    ownerMessages: [], excludedDotMessages: 0, excludedAutomaticMessages: 0, invalidMessages: 0)
        var cursor: String?, seen = Set<String>(), cursors = Set<String>()
        for _ in 0..<max(1, min(maxPages, 5)) {
            var query = ["limit": "20"]
            if let cursor { query["before"] = cursor }
            let page = try decoder.decode(Page.self, from: await transport.get(path + "/messages", query: query))
            guard page.items.count <= 20 else { throw DotInputError.unavailable("page_limit") }
            report.pages += 1
            for message in page.items where seen.insert(message.id).inserted {
                if message.account_user_id == dotMembers[0].account_user_id { report.excludedDotMessages += 1; continue }
                guard message.account_user_id == owner, message.role == "user", message.room_id == nil || message.room_id == roomID,
                      message.deleted_at == nil, let source = message.created_at, let date = parseDotInputDate(source), date <= now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - began + 5) else { report.invalidMessages += 1; continue }
                let trigger = message.message_metadata?.turn_trigger
                if HumanInputSource.automatic(trigger) { report.excludedAutomaticMessages += 1; continue }
                let key = HMAC<SHA256>.authenticationCode(for: Data([identity.account, roomID, message.id].joined(separator: "|").utf8), using: SymmetricKey(data: salt)).map { String(format: "%02x", $0) }.joined()
                report.ownerMessages.append(HumanInputEvent(eventKey: key, sourceAt: source, source: "dot_room",
                                                           classification: "owner_message", trigger: nil))
            }
            guard page.items.count == 20 else { report.windowLimited = false; break }
            report.windowLimited = true
            guard let before = page.prev_cursor ?? page.items.first?.id, !before.isEmpty, cursors.insert(before).inserted else { break }
            cursor = before
        }
        report.collectedAt = iso(now.addingTimeInterval(ProcessInfo.processInfo.systemUptime - began))
        report.ownerMessages.sort { (parseDotInputDate($0.sourceAt) ?? .distantPast) < (parseDotInputDate($1.sourceAt) ?? .distantPast) }
        return report
    }
    public static func parse(_ value: String) -> Date? { parseDotInputDate(value) }
}

private func parseDotInputDate(_ value: String) -> Date? {
    guard value.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
