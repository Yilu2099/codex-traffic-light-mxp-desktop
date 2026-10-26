import Darwin
import Foundation

/// Repairs only this installed app's local launchd registration. Download,
/// signatures, rollout policy and failure backoff remain the updater's job.
public enum UpdaterScheduleRepair {
    /// Construct the dispatch source outside MainActor isolation. The callback
    /// is explicitly Sendable because launchd checks run on a utility queue.
    public static func makeTimer(initialDelay: TimeInterval = 12, repeating: TimeInterval = 600,
                                 handler: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + initialDelay, repeating: repeating, leeway: .seconds(1))
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    public enum Result: String, Sendable {
        case healthy, repaired, deferred, notInstalled, missingBinary, invalidPackage
        case inspectionFailed, writeFailed, enableFailed, bootoutFailed, bootstrapFailed
    }

    public static func check(
        runningExecutable: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        runLaunchctl: (([String]) -> MainAppLaunchctlResult)? = nil
    ) -> Result {
        let result = repair(runningExecutable: runningExecutable, home: home, userID: userID, runLaunchctl: runLaunchctl)
        if result != .notInstalled {
            let health = home.appendingPathComponent(".wanhe-codex-token/updater-health.json")
            if let data = try? JSONSerialization.data(withJSONObject: ["status": result.rawValue, "checkedAt": ISO8601DateFormatter().string(from: Date())]) {
                try? data.write(to: health, options: .atomic)
            }
        }
        return result
    }

    private static func repair(runningExecutable: URL, home: URL, userID: uid_t,
                               runLaunchctl: (([String]) -> MainAppLaunchctlResult)?) -> Result {
        let fm = FileManager.default
        let app = home.appendingPathComponent(".wanhe-codex-token/app")
        let current = app.appendingPathComponent("current")
        let release = current.resolvingSymlinksInPath().standardizedFileURL
        guard release.deletingLastPathComponent() == app.appendingPathComponent("releases").resolvingSymlinksInPath().standardizedFileURL,
              runningExecutable.resolvingSymlinksInPath().standardizedFileURL == release.appendingPathComponent("CodexTrafficLightApp") else { return .notInstalled }
        let binary = release.appendingPathComponent("wanhe-status-updater")
        guard fm.isExecutableFile(atPath: binary.path) else { return .missingBinary }
        let template = release.appendingPathComponent("\(UpdaterLaunchAgentInstaller.label).plist.template")
        let version = (try? String(contentsOf: release.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == release.lastPathComponent, version == ClientVersion.current,
              [release, binary, template].allSatisfy({ url in
                  guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
                        let attributes = try? fm.attributesOfItem(atPath: url.path),
                        (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == userID,
                        let mode = attributes[.posixPermissions] as? NSNumber else { return false }
                  return mode.intValue & 0o022 == 0
              }),
              let source = try? String(contentsOf: template, encoding: .utf8) else { return .invalidPackage }
        let rendered = source.replacingOccurrences(of: "__UPDATER_PATH__", with: current.appendingPathComponent("wanhe-status-updater").path)
            .replacingOccurrences(of: "__HOME__", with: home.path)
        guard let data = rendered.data(using: .utf8),
              let expected = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              expected["Label"] as? String == UpdaterLaunchAgentInstaller.label,
              expected["ProgramArguments"] as? [String] == [current.appendingPathComponent("wanhe-status-updater").path],
              Set(expected.keys).isSubset(of: ["Label", "ProgramArguments", "RunAtLoad", "StartInterval", "ProcessType", "StandardOutPath", "StandardErrorPath"]),
              (expected["StartInterval"] as? NSNumber)?.intValue == 300,
              expected["RunAtLoad"] as? Bool == true else { return .invalidPackage }
        let runner = runLaunchctl ?? { boundedProcessResult(executable: "/bin/launchctl", arguments: $0) }
        let domain = "gui/\(userID)", service = "gui/\(userID)/\(UpdaterLaunchAgentInstaller.label)"
        let registration = runner(["print", service])
        guard registration.status == 0 || launchctlSaysServiceIsAbsent(registration.output) else { return .inspectionFailed }
        let disabledState = runner(["print-disabled", domain])
        guard disabledState.status == 0 else { return .inspectionFailed }
        let disabled = disabledState.output.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\"\(UpdaterLaunchAgentInstaller.label)\" => true")
        }
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(UpdaterLaunchAgentInstaller.label).plist")
        let installed = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let changed = installed.map { !NSDictionary(dictionary: $0).isEqual(to: expected) } ?? true
        let loadedProgram = registration.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("program = ") }.map { String($0.dropFirst("program = ".count)) }
        let logs = home.appendingPathComponent(".wanhe-codex-token/logs")
        var logsIsDirectory: ObjCBool = false
        let logsMissing = !fm.fileExists(atPath: logs.path, isDirectory: &logsIsDirectory) || !logsIsDirectory.boolValue
        let needsReload = changed || logsMissing || registeredInterval(registration.output) != 300
            || (loadedProgram.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL != binary } ?? false)
        if !needsReload && !disabled && registration.status == 0 { return .healthy }
        // Do not interrupt a running updater, including its short pre-lock phase.
        if registration.output.contains("state = running") || registration.output.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }) { return .deferred }
        var updateLock = try? UpdaterProcessLock(url: app.appendingPathComponent("update-process.lock"))
        guard updateLock != nil else { return .deferred }
        defer { withExtendedLifetime(updateLock) {} }
        guard current.resolvingSymlinksInPath().standardizedFileURL == release else { return .deferred }
        // Retire the idle registration before changing its source plist. If
        // removal fails, the unchanged plist keeps the next retry actionable.
        if registration.status == 0 && needsReload {
            let removed = runner(["bootout", service])
            guard removed.status == 0 || launchctlSaysServiceIsAbsent(removed.output) else { return .bootoutFailed }
        }
        do {
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            if changed {
                try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: plist, options: .atomic)
            }
        } catch { return .writeFailed }
        if disabled && runner(["enable", service]).status != 0 { return .enableFailed }
        // RunAtLoad must be able to acquire its own update lock immediately.
        // All plist changes and any retirement of the idle job are complete.
        updateLock = nil
        if registration.status != 0 || needsReload {
            guard runner(["bootstrap", domain, plist.path]).status == 0 else { return .bootstrapFailed }
        }
        let verified = runner(["print", service])
        return verified.status == 0 && registeredInterval(verified.output) == 300 ? .repaired : .bootstrapFailed
    }

    private static func registeredInterval(_ output: String) -> Int? {
        guard let line = output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("run interval = ") }),
              let seconds = line.dropFirst("run interval = ".count).split(separator: " ").first else { return nil }
        return Int(seconds)
    }
}
