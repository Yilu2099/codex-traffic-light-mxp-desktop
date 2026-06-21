import Foundation

public indirect enum CodexAppServerQuotaError: Error, CustomStringConvertible {
    case invalidJSON
    case invalidFrame(String)
    case responseNotFound(Int)
    case appServerReturnedError(String)
    case appServerError(String)
    case launchFailed(String)
    case processFailed(String)
    case initializeTimedOut(timeout: TimeInterval)
    case rateLimitsTimedOut(timeout: TimeInterval)
    case retryExhausted(attempts: Int, lastError: CodexAppServerQuotaError)
    case missingQuota

    public var description: String {
        switch self {
        case .invalidJSON:
            return "Invalid app-server JSON"
        case .invalidFrame(let detail):
            return "Invalid app-server frame: \(detail)"
        case .responseNotFound(let id):
            return "App-server response id \(id) was not found"
        case .appServerReturnedError(let message), .appServerError(let message):
            return "App-server error: \(message)"
        case .launchFailed(let message):
            return "could not launch codex app-server: \(message)"
        case .processFailed(let message):
            return "App-server process failed: \(message)"
        case .initializeTimedOut(let timeout):
            return "initialize timed out after \(Self.format(seconds: timeout))"
        case .rateLimitsTimedOut(let timeout):
            return "rate limits read timed out after \(Self.format(seconds: timeout))"
        case .retryExhausted(let attempts, let lastError):
            return "App-server quota failed after \(attempts) attempts: \(lastError.description)"
        case .missingQuota:
            return "App-server response did not include Codex 5-hour and weekly quota"
        }
    }

    public var summaryKey: String {
        switch self {
        case .invalidJSON:
            return "invalidJSON"
        case .invalidFrame:
            return "invalidFrame"
        case .responseNotFound:
            return "responseNotFound"
        case .appServerReturnedError, .appServerError:
            return "appServerReturnedError"
        case .launchFailed:
            return "launchFailed"
        case .processFailed:
            return "processFailed"
        case .initializeTimedOut:
            return "initializeTimedOut"
        case .rateLimitsTimedOut:
            return "rateLimitsTimedOut"
        case .retryExhausted(_, let lastError):
            return "retryExhausted:\(lastError.summaryKey)"
        case .missingQuota:
            return "missingQuota"
        }
    }

    private static func format(seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return "\(Int(seconds))s"
        }
        return "\(seconds)s"
    }
}

public enum CodexAppServerQuotaMapper {
    private static let fiveHourDurationMins = 300
    private static let weeklyDurationMins = 10_080

    public static func quotaValues(from data: Data) throws -> QuotaValues {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let response: AppServerRateLimitsResponse
        do {
            response = try decoder.decode(AppServerRateLimitsResponse.self, from: data)
        } catch {
            throw CodexAppServerQuotaError.invalidJSON
        }

        guard let snapshot = codexSnapshot(from: response),
              let values = quotaValues(from: snapshot) else {
            throw CodexAppServerQuotaError.missingQuota
        }
        return values
    }

    private static func codexSnapshot(from response: AppServerRateLimitsResponse) -> AppServerRateLimitSnapshot? {
        if let codex = response.rateLimitsByLimitId?["codex"] {
            return codex
        }
        if let byLimitID = response.rateLimitsByLimitId,
           let codex = byLimitID.values.first(where: { $0.limitId == "codex" }) {
            return codex
        }
        return response.rateLimits
    }

    private static func quotaValues(from snapshot: AppServerRateLimitSnapshot) -> QuotaValues? {
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let fiveHourWindow = windows.first { $0.windowDurationMins == fiveHourDurationMins }
            ?? fallbackWindow(snapshot.primary, duration: fiveHourDurationMins)
        let weeklyWindow = windows.first { $0.windowDurationMins == weeklyDurationMins }
            ?? fallbackWindow(snapshot.secondary, duration: weeklyDurationMins)

        guard let fiveHourWindow, let weeklyWindow else {
            return nil
        }
        return QuotaValues(
            fiveHourRemainingPercent: remainingPercent(fromUsedPercent: fiveHourWindow.usedPercent),
            weeklyRemainingPercent: remainingPercent(fromUsedPercent: weeklyWindow.usedPercent),
            fiveHourResetsAt: fiveHourWindow.resetsAt,
            weeklyResetsAt: weeklyWindow.resetsAt
        )
    }

    private static func fallbackWindow(_ window: AppServerRateLimitWindow?, duration: Int) -> AppServerRateLimitWindow? {
        guard let window, window.windowDurationMins == nil else {
            return nil
        }
        return window
    }

    private static func remainingPercent(fromUsedPercent usedPercent: Double) -> Int {
        let remaining = Int((100 - usedPercent).rounded())
        return min(100, max(0, remaining))
    }
}

public enum CodexAppServerJSONRPCFramer {
    public static func encodeRequest(id: Int, method: String, params: Any? = nil) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            object["params"] = params
        }
        return try encodeMessage(object)
    }

    public static func encodeMessage(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerQuotaError.invalidJSON
        }
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    public static func decodeMessages(from data: Data) throws -> [Data] {
        var messages: [Data] = []
        var offset = 0

        while offset < data.count {
            guard let headerRange = data.range(of: Data("\r\n\r\n".utf8), in: offset..<data.count) else {
                throw CodexAppServerQuotaError.invalidFrame("missing header terminator")
            }
            let headerData = data[offset..<headerRange.lowerBound]
            guard let header = String(data: headerData, encoding: .utf8) else {
                throw CodexAppServerQuotaError.invalidFrame("header is not UTF-8")
            }
            let length = try contentLength(from: header)
            let bodyStart = headerRange.upperBound
            let bodyEnd = bodyStart + length
            guard bodyEnd <= data.count else {
                throw CodexAppServerQuotaError.invalidFrame("body shorter than Content-Length")
            }
            messages.append(data[bodyStart..<bodyEnd])
            offset = bodyEnd
        }

        return messages
    }

    public static func resultData(forID id: Int, in messages: [Data]) throws -> Data {
        for message in messages {
            guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any],
                  let responseID = object["id"] as? Int,
                  responseID == id else {
                continue
            }
            if let error = object["error"] {
                throw CodexAppServerQuotaError.appServerReturnedError(String(describing: error))
            }
            guard let result = object["result"] else {
                throw CodexAppServerQuotaError.invalidJSON
            }
            return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        }
        throw CodexAppServerQuotaError.responseNotFound(id)
    }

    private static func contentLength(from header: String) throws -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased() == "content-length" else {
                continue
            }
            if let length = Int(parts[1]), length >= 0 {
                return length
            }
        }
        throw CodexAppServerQuotaError.invalidFrame("missing Content-Length")
    }
}

public enum CodexAppServerJSONRPCLineCodec {
    public static func encodeRequest(id: Int, method: String, params: Any? = nil) throws -> Data {
        var object: [String: Any] = [
            "id": id,
            "method": method
        ]
        if let params {
            object["params"] = params
        }
        return try encodeMessage(object)
    }

    public static func encodeMessage(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerQuotaError.invalidJSON
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    public static func decodeMessages(from data: Data) throws -> [Data] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexAppServerQuotaError.invalidJSON
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { String($0).data(using: .utf8) }
    }

    public static func resultData(forID id: Int, in messages: [Data]) throws -> Data {
        for message in messages {
            guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any],
                  let responseID = object["id"] as? Int,
                  responseID == id else {
                continue
            }
            if let error = object["error"] {
                throw CodexAppServerQuotaError.appServerReturnedError(String(describing: error))
            }
            guard let result = object["result"] else {
                throw CodexAppServerQuotaError.invalidJSON
            }
            return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        }
        throw CodexAppServerQuotaError.responseNotFound(id)
    }
}

public protocol CodexAppServerTransport {
    func readRateLimits() throws -> Data
}

public struct CodexAppServerRetryPolicy: Equatable, Sendable {
    public var retries: Int
    public var backoffSeconds: [TimeInterval]

    public init(retries: Int = 2, backoffSeconds: [TimeInterval] = [1, 3]) {
        self.retries = max(0, retries)
        self.backoffSeconds = backoffSeconds
    }

    public static let `default` = CodexAppServerRetryPolicy()
}

public struct CodexAppServerQuotaCollector {
    public static let source = "codex-app-server"

    private let transport: CodexAppServerTransport
    private let retryPolicy: CodexAppServerRetryPolicy
    private let sleep: (TimeInterval) -> Void

    public init(
        transport: CodexAppServerTransport = ProcessCodexAppServerTransport(),
        retryPolicy: CodexAppServerRetryPolicy = .default,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    public func fetchQuota() throws -> QuotaValues {
        var lastError: CodexAppServerQuotaError?
        let maxAttempts = retryPolicy.retries + 1
        for attempt in 1...maxAttempts {
            do {
                let data = try transport.readRateLimits()
                return try CodexAppServerQuotaMapper.quotaValues(from: data)
            } catch {
                let quotaError = Self.normalize(error)
                lastError = quotaError
                if attempt < maxAttempts {
                    let backoff = retryPolicy.backoffSeconds.indices.contains(attempt - 1)
                        ? retryPolicy.backoffSeconds[attempt - 1]
                        : 0
                    if backoff > 0 {
                        sleep(backoff)
                    }
                }
            }
        }
        throw CodexAppServerQuotaError.retryExhausted(
            attempts: maxAttempts,
            lastError: lastError ?? .missingQuota
        )
    }

    @discardableResult
    public func fetchAndUpdate(store: StateStore = StateStore(), now: Date = Date()) throws -> StateSnapshot {
        let quota = try fetchQuota()
        return try store.updateQuota(
            fiveHourPercent: quota.fiveHourRemainingPercent,
            weeklyPercent: quota.weeklyRemainingPercent,
            fiveHourResetsAt: quota.fiveHourResetsAt,
            weeklyResetsAt: quota.weeklyResetsAt,
            source: Self.source,
            now: now
        )
    }

    private static func normalize(_ error: Error) -> CodexAppServerQuotaError {
        if let quotaError = error as? CodexAppServerQuotaError {
            return quotaError
        }
        return .processFailed(String(describing: error))
    }
}

public struct ProcessCodexAppServerTransport: CodexAppServerTransport {
    private let codexBinary: String
    private let initializeTimeout: TimeInterval
    private let rateLimitsTimeout: TimeInterval

    public init(
        codexBinary: String = ProcessCodexAppServerTransport.defaultCodexBinary(),
        initializeTimeout: TimeInterval = 50,
        rateLimitsTimeout: TimeInterval = 20
    ) {
        self.codexBinary = codexBinary
        self.initializeTimeout = initializeTimeout
        self.rateLimitsTimeout = rateLimitsTimeout
    }

    public static func defaultCodexBinary() -> String {
        if let configured = ProcessInfo.processInfo.environment["CODEX_TRAFFIC_LIGHT_CODEX_BIN"],
           !configured.isEmpty {
            return configured
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localCodex = home.appendingPathComponent(".local/bin/codex").path
        if FileManager.default.isExecutableFile(atPath: localCodex) {
            return localCodex
        }
        return "codex"
    }

    public func readRateLimits() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [codexBinary, "app-server", "--stdio"]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        let responseBuffer = LockedDataBuffer()
        let errorBuffer = LockedDataBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            responseBuffer.append(chunk)
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            errorBuffer.append(chunk)
        }

        do {
            try process.run()
        } catch let launchError {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            throw CodexAppServerQuotaError.launchFailed(String(describing: launchError))
        }

        let initialize = try CodexAppServerJSONRPCLineCodec.encodeRequest(
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex-light-mxp",
                    "version": "1"
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false,
                    "optOutNotificationMethods": []
                ]
            ]
        )
        try input.fileHandleForWriting.write(contentsOf: initialize)

        let initializeDeadline = Date().addingTimeInterval(initializeTimeout)
        var initialized = false
        while Date() < initializeDeadline {
            if let messages = try? CodexAppServerJSONRPCLineCodec.decodeMessages(from: responseBuffer.snapshot()),
               (try? CodexAppServerJSONRPCLineCodec.resultData(forID: 1, in: messages)) != nil {
                initialized = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard initialized else {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            throw CodexAppServerQuotaError.initializeTimedOut(timeout: initializeTimeout)
        }

        let initializedNotification = try CodexAppServerJSONRPCLineCodec.encodeMessage(["method": "initialized"])
        let read = try CodexAppServerJSONRPCLineCodec.encodeRequest(id: 2, method: "account/rateLimits/read")
        try input.fileHandleForWriting.write(contentsOf: initializedNotification)
        try input.fileHandleForWriting.write(contentsOf: read)

        let readDeadline = Date().addingTimeInterval(rateLimitsTimeout)
        while Date() < readDeadline {
            let currentBuffer = responseBuffer.snapshot()

            if let messages = try? CodexAppServerJSONRPCLineCodec.decodeMessages(from: currentBuffer),
               let result = try? CodexAppServerJSONRPCLineCodec.resultData(forID: 2, in: messages) {
                output.fileHandleForReading.readabilityHandler = nil
                error.fileHandleForReading.readabilityHandler = nil
                process.terminate()
                return result
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        let stderr = String(data: errorBuffer.snapshot(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stderr, !stderr.isEmpty {
            throw CodexAppServerQuotaError.processFailed(stderr)
        }
        throw CodexAppServerQuotaError.rateLimitsTimedOut(timeout: rateLimitsTimeout)
    }
}

public final class QuotaRefreshCoordinator {
    private let logThrottleSeconds: TimeInterval
    private var refreshInFlight = false
    private var lastFailureKey: String?
    private var lastFailureLoggedAt: Date?

    public init(logThrottleSeconds: TimeInterval = 10 * 60) {
        self.logThrottleSeconds = logThrottleSeconds
    }

    public func beginRefresh() -> Bool {
        guard !refreshInFlight else { return false }
        refreshInFlight = true
        return true
    }

    public func endRefresh(success: Bool, now: Date = Date()) {
        refreshInFlight = false
        if success {
            lastFailureKey = nil
            lastFailureLoggedAt = nil
        }
    }

    public func failureLogLine(error: Error, now: Date = Date()) -> String? {
        let quotaError = error as? CodexAppServerQuotaError
        let key = quotaError?.summaryKey ?? String(describing: type(of: error))
        if key == lastFailureKey,
           let lastFailureLoggedAt,
           now.timeIntervalSince(lastFailureLoggedAt) < logThrottleSeconds {
            return nil
        }
        lastFailureKey = key
        lastFailureLoggedAt = now
        return "quota app-server failed: \(error)"
    }
}

private struct AppServerRateLimitsResponse: Decodable {
    var rateLimits: AppServerRateLimitSnapshot?
    var rateLimitsByLimitId: [String: AppServerRateLimitSnapshot]?
}

private struct AppServerRateLimitSnapshot: Decodable {
    var limitId: String?
    var primary: AppServerRateLimitWindow?
    var secondary: AppServerRateLimitWindow?
}

private struct AppServerRateLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: Date?
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}
