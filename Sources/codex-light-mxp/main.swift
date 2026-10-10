import Foundation
import CodexTrafficLightCore

struct CLIOptions {
    var taskID: String?
    var workspace: String?
    var json = false
    var stdin = false
    var appServer = false
    var fiveHourPercent: Int?
    var weeklyPercent: Int?
    var command: String?
    var month: String?
}

func usage() {
    FileHandle.standardError.write("""
    Usage: \(CommandContract.clientCommandName) status [--json]
           \(CommandContract.clientCommandName) audit --task <task-id> --workspace <path>
           \(CommandContract.clientCommandName) quota [--five-hour <0-100>] [--weekly <0-100>] [--json]
           \(CommandContract.clientCommandName) quota --stdin [--json]
           \(CommandContract.clientCommandName) quota --app-server [--json]
           \(CommandContract.clientCommandName) chat-usage [--json]
           \(CommandContract.clientCommandName) official-usage [--month YYYY-MM] [--json]

    """.data(using: .utf8)!)
}

func parse(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--month":
            index += 1
            guard index < arguments.count,
                  arguments[index].range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil else {
                throw StateStoreError.invalidInput("--month requires YYYY-MM")
            }
            options.month = arguments[index]
        case "--task":
            index += 1
            guard index < arguments.count else { throw StateStoreError.invalidInput("--task requires a value") }
            options.taskID = arguments[index]
        case "--workspace":
            index += 1
            guard index < arguments.count else { throw StateStoreError.invalidInput("--workspace requires a value") }
            options.workspace = arguments[index]
        case "--json": options.json = true
        case "--stdin": options.stdin = true
        case "--app-server": options.appServer = true
        case "--five-hour":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]) else {
                throw StateStoreError.invalidInput("--five-hour requires an integer")
            }
            options.fiveHourPercent = value
        case "--weekly":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]) else {
                throw StateStoreError.invalidInput("--weekly requires an integer")
            }
            options.weeklyPercent = value
        default:
            guard options.command == nil else { throw StateStoreError.invalidInput("too many commands") }
            options.command = arguments[index]
        }
        index += 1
    }
    return options
}

func printSnapshot(_ snapshot: StateSnapshot, json: Bool) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        FileHandle.standardOutput.write(try encoder.encode(snapshot))
        print("")
    } else if let quota = snapshot.quota?.preferredWindow {
        print("\(quota.kind.label) \(quota.remainingPercent)%")
    } else {
        print("--")
    }
}

do {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))
    guard let command = options.command else { usage(); exit(2) }
    let store = StateStore()

    switch command {
    case "computer-history":
        let report = ComputerHistoryCollector.collect(codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        FileHandle.standardOutput.write(try JSONEncoder().encode(report))
        print("")
    case "chat-usage":
        let report = try ChatUsageCollector.fetch(codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        FileHandle.standardOutput.write(try JSONEncoder().encode(report))
        print("")
    case "official-usage":
        let report = try OfficialCodexUsageCollector().fetch()
        if let month = options.month {
            let daily = report.dailyUsageBuckets.filter { $0.startDate.hasPrefix(month + "-") }
            let total = daily.reduce(0) { $0 + $1.tokens }
            let complete = report.lifetimeTokens.map { $0 == report.dailyUsageBuckets.reduce(0) { $0 + $1.tokens } } ?? false
            if options.json {
                let payload: [String: Any] = ["month": month, "tokens": total, "updatedAt": report.updatedAt,
                    "completeAccountResponse": complete, "dataThrough": report.dataThrough ?? "",
                    "dailyUsageBuckets": daily.map { ["startDate": $0.startDate, "tokens": $0.tokens] as [String: Any] }]
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
                print("")
            } else {
                print("\(month): \(String(format: "%.2f", Double(total) / 100_000_000)) 亿 Token")
            }
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            print("")
        }
    case "status":
        try printSnapshot(store.read(), json: options.json)
    case CommandContract.auditCommandName:
        guard let taskID = options.taskID, !taskID.isEmpty else { throw StateStoreError.invalidInput("audit requires --task") }
        guard let workspace = options.workspace, !workspace.isEmpty else { throw StateStoreError.invalidInput("audit requires --workspace") }
        let activityURL = store.stateURL.deletingLastPathComponent().appendingPathComponent("project-activity.json")
        try ProjectActivityStore(activityURL: activityURL).record(workspace: workspace, taskID: taskID)
        print(options.json ? "{\"status\":\"recorded\"}" : "recorded")
    case CommandContract.quotaCommandName:
        let snapshot: StateSnapshot
        if options.appServer {
            snapshot = try CodexAppServerQuotaCollector().fetchAndUpdate(store: store)
        } else if options.stdin {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let quota = QuotaExtractor.extract(from: input), quota.preferredWindow != nil else {
                throw StateStoreError.invalidInput("quota --stdin requires a 5-hour or weekly remaining percent")
            }
            snapshot = try store.updateQuota(
                weeklyPercent: quota.weeklyRemainingPercent,
                weeklyResetsAt: quota.weeklyResetsAt,
                fiveHourPercent: quota.fiveHourRemainingPercent,
                fiveHourResetsAt: quota.fiveHourResetsAt,
                primaryWindow: quota.primaryWindow,
                source: "cli",
                planType: quota.planType
            )
        } else if options.weeklyPercent != nil || options.fiveHourPercent != nil {
            snapshot = try store.updateQuota(
                weeklyPercent: options.weeklyPercent,
                fiveHourPercent: options.fiveHourPercent,
                primaryWindow: options.fiveHourPercent != nil ? .fiveHour : .weekly,
                source: "cli"
            )
        } else {
            throw StateStoreError.invalidInput("quota requires --five-hour, --weekly, --stdin, or --app-server")
        }
        try printSnapshot(snapshot, json: options.json)
    default:
        throw StateStoreError.invalidInput("unknown command: \(command)")
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    usage()
    exit(2)
}
