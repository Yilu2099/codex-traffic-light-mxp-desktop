import Foundation
import CodexTrafficLightCore

struct CLIOptions {
    var taskID: String?
    var workspace: String?
    var json = false
    var stdin = false
    var appServer = false
    var weeklyPercent: Int?
    var command: String?
}

func usage() {
    FileHandle.standardError.write("""
    Usage: \(CommandContract.clientCommandName) status [--json]
           \(CommandContract.clientCommandName) audit --task <task-id> --workspace <path>
           \(CommandContract.clientCommandName) quota --weekly <0-100> [--json]
           \(CommandContract.clientCommandName) quota --stdin [--json]
           \(CommandContract.clientCommandName) quota --app-server [--json]

    """.data(using: .utf8)!)
}

func parse(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
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
    } else if let quota = snapshot.quota {
        print("\(quota.weeklyRemainingPercent)%")
    } else {
        print("--")
    }
}

do {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))
    guard let command = options.command else { usage(); exit(2) }
    let store = StateStore()

    switch command {
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
            guard let quota = QuotaExtractor.extract(from: input), let weekly = quota.weeklyRemainingPercent else {
                throw StateStoreError.invalidInput("quota --stdin requires weekly remaining percent")
            }
            snapshot = try store.updateQuota(
                weeklyPercent: weekly,
                weeklyResetsAt: quota.weeklyResetsAt,
                source: "cli"
            )
        } else if let weekly = options.weeklyPercent {
            snapshot = try store.updateQuota(weeklyPercent: weekly, source: "cli")
        } else {
            throw StateStoreError.invalidInput("quota requires --weekly, --stdin, or --app-server")
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
