import Foundation

public enum ClaudeUsageQuotaError: Error, CustomStringConvertible {
    case commandLaunchFailed(String)
    case commandFailed(Int, String)
    case parseFailed(String)
    case missingSessionQuota

    public var description: String {
        switch self {
        case .commandLaunchFailed(let reason):
            return "Could not run claude /usage: \(reason)"
        case .commandFailed(let code, let reason):
            return "claude /usage exited with code \(code): \(reason)"
        case .parseFailed(let reason):
            return "Could not parse claude /usage output: \(reason)"
        case .missingSessionQuota:
            return "claude /usage output did not include session quota"
        }
    }
}

public struct ClaudeUsageValues: Equatable, Sendable {
    public var sessionRemainingPercent: Int
    public var weeklyRemainingPercent: Int
    public var sessionResetsAt: Date?
    public var weeklyResetsAt: Date?

    public init(
        sessionRemainingPercent: Int,
        weeklyRemainingPercent: Int,
        sessionResetsAt: Date? = nil,
        weeklyResetsAt: Date? = nil
    ) {
        self.sessionRemainingPercent = min(100, max(0, sessionRemainingPercent))
        self.weeklyRemainingPercent = min(100, max(0, weeklyRemainingPercent))
        self.sessionResetsAt = sessionResetsAt
        self.weeklyResetsAt = weeklyResetsAt
    }
}

public struct ClaudeUsageQuotaCollector {
    public static let source = "claude-usage"

    private let claudeBinary: String
    private let timeout: TimeInterval

    public init(
        claudeBinary: String = Self.defaultClaudeBinary(),
        timeout: TimeInterval = 20
    ) {
        self.claudeBinary = claudeBinary
        self.timeout = timeout
    }

    public static func defaultClaudeBinary() -> String {
        if let configured = ProcessInfo.processInfo.environment["CODEX_TRAFFIC_LIGHT_CLAUDE_BIN"],
           !configured.isEmpty {
            return configured
        }
        return "claude"
    }

    public func fetch() throws -> ClaudeUsageValues {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [claudeBinary, "/usage", "--allowed-tools", ""]
        process.standardInput = nil

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_OAUTH_TOKEN"] = nil
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw ClaudeUsageQuotaError.commandLaunchFailed(String(describing: error))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            throw ClaudeUsageQuotaError.commandFailed(-1, "timed out after \(Int(timeout))s")
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClaudeUsageQuotaError.commandFailed(
                Int(process.terminationStatus),
                errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return try Self.parse(output)
    }

    public func fetchAndUpdate(store: StateStore = StateStore(), now: Date = Date()) throws -> StateSnapshot {
        let values = try fetch()
        return try store.updateProviderQuota(
            providerID: ProviderQuotaSnapshot.claudeProviderID,
            fiveHourPercent: nil,
            weeklyPercent: values.weeklyRemainingPercent,
            sessionPercent: values.sessionRemainingPercent,
            fiveHourResetsAt: nil,
            weeklyResetsAt: values.weeklyResetsAt,
            sessionResetsAt: values.sessionResetsAt,
            source: Self.source,
            now: now
        )
    }

    public static func parse(_ output: String) throws -> ClaudeUsageValues {
        let normalized = normalizeOutput(output)
        let lines = normalized.components(separatedBy: .newlines)

        guard let session = parseValue(fromSection: "current session", in: lines) else {
            throw ClaudeUsageQuotaError.missingSessionQuota
        }

        let weekly = parseValue(fromSection: "current week", in: lines) ?? session

        return ClaudeUsageValues(
            sessionRemainingPercent: session.percent,
            weeklyRemainingPercent: weekly.percent,
            sessionResetsAt: session.resetAt,
            weeklyResetsAt: weekly.resetAt
        )
    }

    private struct ParsedSection {
        let percent: Int
        let resetAt: Date?
    }

    private static func parseValue(fromSection label: String, in lines: [String]) -> ParsedSection? {
        let loweredLabel = label.lowercased()
        for (index, line) in lines.enumerated() where line.lowercased().contains(loweredLabel) {
            let scanRange = index..<min(lines.count, index + 20)
            var foundPercent: Int?
            var resetTextCandidate: String?

            for candidate in lines[scanRange] {
                if foundPercent == nil {
                    foundPercent = parsePercent(from: candidate)
                }
                if resetTextCandidate == nil, let candidateReset = resetText(from: candidate) {
                    resetTextCandidate = candidateReset
                }
                if foundPercent != nil && resetTextCandidate != nil {
                    break
                }
            }

            if let foundPercent {
                return ParsedSection(percent: foundPercent, resetAt: parseDate(from: resetTextCandidate))
            }
        }
        return nil
    }

    private static func parsePercent(from line: String) -> Int? {
        let lowercased = line.lowercased()
        if let left = firstPercent(
            from: lowercased,
            patterns: [
                #"left\s*[:=]?\s*([0-9]{1,3})\s*%"#,
                #"([0-9]{1,3})\s*%\s*(?:left|remaining|remain)"#
            ]
        ) {
            return left
        }
        if let remain = firstPercent(
            from: lowercased,
            patterns: [
                #"(?:remaining|remain)\s*[:=]?\s*([0-9]{1,3})\s*%"#,
                #"(?:remaining|remain)\s*[a-z]*\s*([0-9]{1,3})\s*%"#
            ]
        ) {
            return remain
        }
        if let used = firstPercent(
            from: lowercased,
            patterns: [
                #"used\s*[:=]?\s*([0-9]{1,3})\s*%"#,
                #"([0-9]{1,3})\s*%\s*used"#
            ]
        ) {
            return 100 - used
        }
        return firstPercent(from: lowercased, patterns: [#"([0-9]{1,3})\s*%"#])
    }

    private static func firstPercent(from line: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let matchRange = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = regex.firstMatch(in: line, range: matchRange), match.numberOfRanges >= 2 else {
                    continue
                }
                for index in 1..<match.numberOfRanges {
                    if let valueRange = Range(match.range(at: index), in: line),
                       let value = Int(line[valueRange].trimmingCharacters(in: .whitespaces)) {
                        return max(0, min(100, value))
                    }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private static func parseAbsoluteDate(_ text: String) -> Date? {
        let noZone = text.replacingOccurrences(
            of: #"\(.*?\)"#,
            with: "",
            options: .regularExpression
        )
        var cleaned = deduplicateResetText(noZone)
            .replacingOccurrences(of: "Resets", with: "", options: .caseInsensitive)
            .replacingOccurrences(
                of: #"^(?:mon|tue|wed|thu|fri|sat|sun)[a-z]{0,2}[,]?\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while let first = cleaned.first, first == ":" || first == "-" || first == "–" || first == "—" || first == "\u{FF0E}" {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if cleaned.isEmpty {
            return nil
        }

        let now = Date()
        let calendar = Calendar.current
        let year = calendar.component(.year, from: now)
        let candidates = [
            "EEE, MMM d, h:mm a",
            "EEE MMM d, h:mm a",
            "MMM d, h:mm a",
            "MMM d, h:mm",
            "EEE, MMM d h:mm a",
            "EEE MMM d h:mm a",
            "MMM d h:mm a",
            "MMM d h:mm",
            "MMM d yyyy h:mm a",
            "MMM d yyyy h:mm"
        ]

        for format in candidates {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format

            if let parsed = formatter.date(from: cleaned) {
                if !format.contains("yyyy") {
                    let components = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
                    var merged = DateComponents()
                    merged.year = year
                    merged.month = components.month
                    merged.day = components.day
                    merged.hour = components.hour
                    merged.minute = components.minute
                    return calendar.date(from: merged)
                }
                return parsed
            }
            if format.contains("yyyy"), let parsed = formatter.date(from: "\(year) \(cleaned)") {
                return parsed
            }
        }

        return nil
    }

    private static func resetText(from line: String) -> String? {
        let lowered = line.lowercased()
        if !lowered.contains("reset") && !lowered.contains(" in ") && !lowered.contains(" after ") {
            return nil
        }
        return deduplicateResetText(line).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseDate(from resetText: String?) -> Date? {
        guard let text = resetText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if let relative = parseRelativeDate(text) {
            return relative
        }
        return parseAbsoluteDate(text)
    }

    private static func parseRelativeDate(_ text: String) -> Date? {
        let cleaned = deduplicateResetText(text).lowercased()
        var seconds: TimeInterval = 0
        if let days = firstInt(from: cleaned, pattern: #"(\d+)\s*(?:day|days)"#) {
            seconds += TimeInterval(days) * 86_400
        }
        if let hours = firstInt(from: cleaned, pattern: #"(\d+)\s*(?:hour|hours|h|hrs|hr)"#) {
            seconds += TimeInterval(hours) * 3_600
        }
        if let minutes = firstInt(from: cleaned, pattern: #"(\d+)\s*(?:minute|minutes|min|mins|m)"#) {
            seconds += TimeInterval(minutes) * 60
        }
        if let secs = firstInt(from: cleaned, pattern: #"(\d+)\s*(?:second|seconds|sec|s)"#) {
            seconds += TimeInterval(secs)
        }

        if seconds <= 0 {
            return nil
        }
        return Date().addingTimeInterval(seconds)
    }

    private static func firstInt(from text: String, pattern: String) -> Int? {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            guard let match = regex.firstMatch(
                in: text,
                options: [],
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ) else {
                return nil
            }
            for index in 1..<(match.numberOfRanges) {
                if let range = Range(match.range(at: index), in: text) {
                    return Int(text[range].trimmingCharacters(in: .whitespaces))
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func deduplicateResetText(_ text: String) -> String {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let hit = text.range(of: "Resets", options: .caseInsensitive, range: searchStart..<text.endIndex) {
            ranges.append(hit)
            searchStart = text.index(after: hit.lowerBound)
        }
        guard ranges.count > 1, let last = ranges.last else { return text }
        return String(text[last.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func normalizeOutput(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\u{001B}\[[0-9;?]*[A-Za-z]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
