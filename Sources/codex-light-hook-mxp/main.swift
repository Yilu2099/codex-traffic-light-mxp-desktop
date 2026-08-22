import Foundation
import CodexTrafficLightCore

let fallbackName = CommandLine.arguments.dropFirst().first
let input = FileHandle.standardInput.readDataToEndOfFile()

do {
    let result = try HookBridge.apply(input: input, fallbackName: fallbackName)
    HookLogger.append(HookLogEntry(
        eventName: result.eventName,
        taskID: result.taskID,
        workspace: result.workspace,
        result: "ok",
        detail: nil,
        quotaSummary: result.quotaSummary
    ))
    print("{}")
} catch {
    let event = HookEvent.parse(jsonData: input, fallbackName: fallbackName)
    let workspace = ContextResolver.workspace(explicitWorkspace: nil, hookEvent: event)
    let taskID = ContextResolver.taskID(explicitTaskID: nil, workspace: workspace, hookEvent: event)
    let quota = QuotaExtractor.extract(from: input)
    HookLogger.append(HookLogEntry(
        eventName: event.name,
        taskID: taskID,
        workspace: workspace,
        result: "error",
        detail: String(describing: error),
        quotaSummary: quota?.summary
    ))
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    print("{}")
    exit(0)
}
