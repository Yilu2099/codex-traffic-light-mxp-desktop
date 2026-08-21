import Foundation
import CodexTrafficLightCore

struct CLIOptions {
    var taskID: String?
    var workspace: String?
    var json = false
    var stdin = false
    var appServer = false
    var claude = false
    var fiveHourPercent: Int?
    var weeklyPercent: Int?
    var command: String?
}

func usage() {
        FileHandle.standardError.write(
        """
        Usage: \(CommandContract.lightCommandName) [--task <task-id>] [--workspace <path>] [--json] <working|done|waiting|idle|status|clear|quit>
               \(CommandContract.lightCommandName) --task <task-id> --workspace <path> audit
               \(CommandContract.lightCommandName) \(CommandContract.quotaCommandName) --five-hour <0-100> --weekly <0-100> [--json]
               \(CommandContract.lightCommandName) \(CommandContract.quotaCommandName) --stdin [--json]
               \(CommandContract.lightCommandName) \(CommandContract.quotaCommandName) --app-server [--json]
               \(CommandContract.lightCommandName) \(CommandContract.quotaCommandName) --claude [--json]
               \(CommandContract.lightCommandName) \(CommandContract.quotaCommandName) --app-server --claude [--json]

        """.data(using: .utf8)!
    )
}

func parse(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--task":
            index += 1
            guard index < arguments.count else { throw StateStoreError.invalidState("--task requires a value") }
            options.taskID = arguments[index]
        case "--workspace":
            index += 1
            guard index < arguments.count else { throw StateStoreError.invalidState("--workspace requires a value") }
            options.workspace = arguments[index]
        case "--json":
            options.json = true
        case "--stdin":
            options.stdin = true
        case "--app-server":
            options.appServer = true
        case "--claude":
            options.claude = true
        case "--five-hour":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]) else {
                throw StateStoreError.invalidState("--five-hour requires an integer")
            }
            options.fiveHourPercent = value
        case "--weekly":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]) else {
                throw StateStoreError.invalidState("--weekly requires an integer")
            }
            options.weeklyPercent = value
        default:
            if options.command != nil {
                throw StateStoreError.invalidState("too many commands")
            }
            options.command = argument
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
        let data = try encoder.encode(snapshot)
        FileHandle.standardOutput.write(data)
        print("")
    } else {
        print(snapshot.aggregateState.rawValue)
    }
}

do {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))
    guard let command = options.command else {
        usage()
        exit(2)
    }

    let store = StateStore()
    switch command {
    case "audit":
        guard let taskID = options.taskID, !taskID.isEmpty else {
            throw StateStoreError.invalidState("audit requires --task")
        }
        guard let workspace = options.workspace, !workspace.isEmpty else {
            throw StateStoreError.invalidState("audit requires --workspace")
        }
        let activityURL = store.stateURL.deletingLastPathComponent().appendingPathComponent("project-activity.json")
        try ProjectActivityStore(activityURL: activityURL).record(workspace: workspace, taskID: taskID)
        if options.json {
            print("{\"status\":\"recorded\"}")
        } else {
            print("recorded")
        }
    case "status":
        try printSnapshot(store.read(), json: options.json)
    case "clear":
        let snapshot = try store.clear()
        try printSnapshot(snapshot, json: options.json)
    case CommandContract.quotaCommandName:
        if options.appServer || options.claude {
            var snapshot = store.read()
            if options.appServer {
                snapshot = try CodexAppServerQuotaCollector().fetchAndUpdate(store: store)
            }
            if options.claude {
                snapshot = try ClaudeUsageQuotaCollector().fetchAndUpdate(store: store)
            }
            try printSnapshot(snapshot, json: options.json)
        } else if options.stdin {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let quota = QuotaExtractor.extract(from: input) else {
                throw StateStoreError.invalidState("quota --stdin requires JSON with five-hour and weekly remaining percent")
            }
            guard let five = quota.fiveHourRemainingPercent,
                  let weekly = quota.weeklyRemainingPercent else {
                throw StateStoreError.invalidState("quota --stdin requires JSON with five-hour and weekly remaining percent")
            }
            let snapshot = try store.updateQuota(
                fiveHourPercent: five,
                weeklyPercent: weekly,
                fiveHourResetsAt: quota.fiveHourResetsAt,
                weeklyResetsAt: quota.weeklyResetsAt,
                source: "cli"
            )
            try printSnapshot(snapshot, json: options.json)
        } else if let fiveHour = options.fiveHourPercent,
                  let weekly = options.weeklyPercent {
            let snapshot = try store.updateQuota(
                fiveHourPercent: fiveHour,
                weeklyPercent: weekly,
                source: "cli"
            )
            try printSnapshot(snapshot, json: options.json)
        } else {
            throw StateStoreError.invalidState("quota requires --five-hour and --weekly")
        }
    case "quit":
        let taskID = ContextResolver.taskID(explicitTaskID: options.taskID, workspace: options.workspace)
        let snapshot = try store.updateTask(
            taskID: taskID,
            state: .quit,
            workspace: ContextResolver.workspace(explicitWorkspace: options.workspace),
            source: "cli",
            hookEventName: nil,
            message: "Codex traffic light: quit"
        )
        try printSnapshot(snapshot, json: options.json)
    default:
        let state = try CommandParser.state(from: command)
        let workspace = ContextResolver.workspace(explicitWorkspace: options.workspace)
        let taskID = ContextResolver.taskID(explicitTaskID: options.taskID, workspace: workspace)
        let snapshot = try store.updateTask(
            taskID: taskID,
            state: state,
            workspace: workspace,
            source: "cli",
            hookEventName: nil,
            message: "Codex traffic light: \(state.rawValue)"
        )
        try printSnapshot(snapshot, json: options.json)
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    usage()
    exit(2)
}
