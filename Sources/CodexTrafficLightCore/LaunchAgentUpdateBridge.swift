import Darwin
import Foundation

public enum LaunchAgentUpdateBridgeError: Error, CustomStringConvertible {
    case targetVersionNotAllowed
    case unsafePreviousTarget
    case currentTargetMismatch
    case packagedVersionMismatch
    case mainDidNotStayRunning
    case updaterDidNotExit
    case activationFailed(String)
    case rollbackFailed(activation: String, rollback: String)

    public var description: String {
        switch self {
        case .targetVersionNotAllowed: return "launch agent bridge target is not the running release"
        case .unsafePreviousTarget: return "launch agent bridge previous target is unsafe"
        case .currentTargetMismatch: return "launch agent bridge current target changed"
        case .packagedVersionMismatch: return "launch agent bridge packaged version mismatch"
        case .mainDidNotStayRunning: return "new main app did not stay running during launch agent bridge"
        case .updaterDidNotExit: return "previous updater did not exit before bridge timeout"
        case .activationFailed(let detail): return "launch agent bridge activation failed: \(detail)"
        case .rollbackFailed(let activation, let rollback):
            return "launch agent bridge activation failed: \(activation); rollback failed: \(rollback)"
        }
    }
}

public enum LaunchAgentUpdateBridgeResult: Equatable, Sendable {
    case completed
    case alreadyCompleted
}

/// One-time compatibility bridge for releases installed by an older updater.
///
/// The old updater remains alive under the old launchd registration while it
/// swaps `current`. The bridge therefore repairs the main app immediately, but
/// waits until that updater process exits before refreshing the updater job.
/// No team configuration, token, prompt or activity database is read here.
public enum LaunchAgentUpdateBridge {
    @discardableResult
    public static func run(
        targetVersion: String,
        previousTarget: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        maximumUpdaterPolls: Int = 240,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.25) },
        runLaunchctl: (([String]) -> MainAppLaunchctlResult)? = nil
    ) throws -> LaunchAgentUpdateBridgeResult {
        guard targetVersion == ClientVersion.current else {
            throw LaunchAgentUpdateBridgeError.targetVersionNotAllowed
        }
        guard isSafeReleaseTarget(previousTarget), previousTarget != "releases/\(targetVersion)" else {
            throw LaunchAgentUpdateBridgeError.unsafePreviousTarget
        }

        let fileManager = FileManager.default
        let appRoot = home.appendingPathComponent(".wanhe-codex-token/app", isDirectory: true)
        let current = appRoot.appendingPathComponent("current")
        let expectedTarget = "releases/\(targetVersion)"
        guard (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) == expectedTarget else {
            throw LaunchAgentUpdateBridgeError.currentTargetMismatch
        }
        let packagedVersion = (try? String(contentsOf: current.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard packagedVersion == targetVersion else {
            throw LaunchAgentUpdateBridgeError.packagedVersionMismatch
        }
        let previousRelease = appRoot.appendingPathComponent(previousTarget, isDirectory: true).standardizedFileURL
        let releases = appRoot.appendingPathComponent("releases", isDirectory: true).standardizedFileURL
        guard previousRelease.deletingLastPathComponent() == releases,
              fileManager.fileExists(atPath: previousRelease.path) else {
            throw LaunchAgentUpdateBridgeError.unsafePreviousTarget
        }

        let marker = appRoot.appendingPathComponent("launch-agent-bridge-\(targetVersion).done")
        if fileManager.fileExists(atPath: marker.path) { return .alreadyCompleted }

        let runner = runLaunchctl ?? defaultRunLaunchctl
        do {
            try MainAppLaunchAgentInstaller.install(
                from: current,
                home: home,
                userID: userID,
                forceRebootstrap: true,
                runLaunchctl: runner
            )

            let mainService = "gui/\(userID)/\(MainAppLaunchAgentInstaller.label)"
            var mainRunning = false
            for poll in 0...12 {
                try assertCurrentTarget(current, expectedTarget: expectedTarget, targetVersion: targetVersion)
                let state = runner(["print", mainService])
                if state.status == 0, state.output.contains("state = running") {
                    mainRunning = true
                    break
                }
                if poll < 12 { pause() }
            }
            guard mainRunning else { throw LaunchAgentUpdateBridgeError.mainDidNotStayRunning }

            let updaterService = "gui/\(userID)/\(UpdaterLaunchAgentInstaller.label)"
            var updaterExited = false
            for poll in 0...max(0, maximumUpdaterPolls) {
                try assertCurrentTarget(current, expectedTarget: expectedTarget, targetVersion: targetVersion)
                let mainState = runner(["print", mainService])
                guard mainState.status == 0, mainState.output.contains("state = running") else {
                    throw LaunchAgentUpdateBridgeError.mainDidNotStayRunning
                }
                let state = runner(["print", updaterService])
                if state.status != 0 || !state.output.contains("state = running") {
                    updaterExited = true
                    break
                }
                if poll < maximumUpdaterPolls { pause() }
            }
            guard updaterExited else { throw LaunchAgentUpdateBridgeError.updaterDidNotExit }

            try assertCurrentTarget(current, expectedTarget: expectedTarget, targetVersion: targetVersion)
            try UpdaterLaunchAgentInstaller.install(
                from: current,
                home: home,
                userID: userID,
                forceRebootstrap: true,
                runLaunchctl: runner
            )
            try assertCurrentTarget(current, expectedTarget: expectedTarget, targetVersion: targetVersion)
            let finalMainState = runner(["print", mainService])
            guard finalMainState.status == 0, finalMainState.output.contains("state = running") else {
                throw LaunchAgentUpdateBridgeError.mainDidNotStayRunning
            }
            try targetVersion.write(to: marker, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            return .completed
        } catch {
            let activation = String(describing: error)
            do {
                try swapCurrentLink(current: current, target: previousTarget)
                try ExistingLaunchAgentRegistration.forceRebootstrap(
                    label: MainAppLaunchAgentInstaller.label,
                    home: home,
                    userID: userID,
                    runLaunchctl: runner
                )
                try ExistingLaunchAgentRegistration.forceRebootstrap(
                    label: UpdaterLaunchAgentInstaller.label,
                    home: home,
                    userID: userID,
                    runLaunchctl: runner
                )
            } catch {
                throw LaunchAgentUpdateBridgeError.rollbackFailed(
                    activation: activation,
                    rollback: String(describing: error)
                )
            }
            throw LaunchAgentUpdateBridgeError.activationFailed(activation)
        }
    }

    private static func isSafeReleaseTarget(_ value: String) -> Bool {
        guard value.hasPrefix("releases/") else { return false }
        let version = String(value.dropFirst("releases/".count))
        guard !version.isEmpty, !version.contains("/"), !version.contains("..") else { return false }
        return version.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter }
    }

    private static func assertCurrentTarget(_ current: URL, expectedTarget: String, targetVersion: String) throws {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == expectedTarget else {
            throw LaunchAgentUpdateBridgeError.currentTargetMismatch
        }
        let version = (try? String(contentsOf: current.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == targetVersion else { throw LaunchAgentUpdateBridgeError.packagedVersionMismatch }
    }

    private static func swapCurrentLink(current: URL, target: String) throws {
        let next = current.deletingLastPathComponent().appendingPathComponent("current.bridge.next")
        try? FileManager.default.removeItem(at: next)
        guard symlink(target, next.path) == 0 else {
            throw LaunchAgentUpdateBridgeError.activationFailed("rollback symlink errno=\(errno)")
        }
        guard rename(next.path, current.path) == 0 else {
            throw LaunchAgentUpdateBridgeError.activationFailed("rollback rename errno=\(errno)")
        }
    }

    private static func defaultRunLaunchctl(_ arguments: [String]) -> MainAppLaunchctlResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return MainAppLaunchctlResult(status: process.terminationStatus, output: output)
        } catch {
            return MainAppLaunchctlResult(status: -1, output: String(describing: error))
        }
    }
}
