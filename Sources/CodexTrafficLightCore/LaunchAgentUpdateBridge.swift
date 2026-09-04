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

public enum LegacyLaunchAgentBridgeRequest {
    private static let firstSelfBridgingUpdaterVersion = "1.2.91"

    /// Creates the metadata-only handoff consumed by the monitor. Before the
    /// symlink swap the actual current target is authoritative. After the swap,
    /// use the executable vnode of the still-running predecessor updater. Disk
    /// inventory is never used to guess: stale release directories may contain
    /// versions that were downloaded but never successfully registered.
    @discardableResult
    public static func prepare(
        targetVersion: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        runningUpdaterExecutable: (() -> URL?)? = nil
    ) throws -> String? {
        guard targetVersion == ClientVersion.current,
              stableVersionComponents(targetVersion) != nil else {
            throw LaunchAgentUpdateBridgeError.targetVersionNotAllowed
        }
        let fileManager = FileManager.default
        let appRoot = home.appendingPathComponent(".wanhe-codex-token/app", isDirectory: true)
        let releases = appRoot.appendingPathComponent("releases", isDirectory: true)
        let targetRelease = releases.appendingPathComponent(targetVersion, isDirectory: true)
        guard releaseIsValid(targetRelease, version: targetVersion, appRoot: appRoot) else {
            throw LaunchAgentUpdateBridgeError.packagedVersionMismatch
        }

        let current = appRoot.appendingPathComponent("current")
        let currentTarget = try fileManager.destinationOfSymbolicLink(atPath: current.path)
        let expectedTarget = "releases/\(targetVersion)"
        let previousTarget: String
        if currentTarget != expectedTarget {
            guard currentTarget.hasPrefix("releases/") else {
                throw LaunchAgentUpdateBridgeError.unsafePreviousTarget
            }
            let currentVersion = String(currentTarget.dropFirst("releases/".count))
            let currentRelease = appRoot.appendingPathComponent(currentTarget, isDirectory: true)
            guard isStrictlyOlderStable(currentVersion, than: targetVersion),
                  releaseIsValid(currentRelease, version: currentVersion, appRoot: appRoot) else {
                throw LaunchAgentUpdateBridgeError.unsafePreviousTarget
            }
            // 1.2.91+ writes its own authoritative request after activating
            // main. Starting the legacy bridge too would race two simultaneous
            // bootout/bootstrap sequences against the same main job.
            guard versionIsLess(currentVersion, firstSelfBridgingUpdaterVersion) else { return nil }
            previousTarget = currentTarget
        } else {
            let executable: URL?
            if let runningUpdaterExecutable {
                executable = runningUpdaterExecutable()
            } else {
                executable = defaultRunningUpdaterExecutable(userID: userID)
            }
            guard let executable,
                  executable.lastPathComponent == "wanhe-status-updater" else {
                throw LaunchAgentUpdateBridgeError.unsafePreviousTarget
            }
            let predecessorRelease = executable.deletingLastPathComponent().standardizedFileURL
            guard predecessorRelease.deletingLastPathComponent() == releases.standardizedFileURL else {
                throw LaunchAgentUpdateBridgeError.unsafePreviousTarget
            }
            let predecessorVersion = predecessorRelease.lastPathComponent
            guard predecessorVersion != targetVersion,
                  isStrictlyOlderStable(predecessorVersion, than: targetVersion),
                  releaseIsValid(predecessorRelease, version: predecessorVersion, appRoot: appRoot) else {
                throw LaunchAgentUpdateBridgeError.unsafePreviousTarget
            }
            guard versionIsLess(predecessorVersion, firstSelfBridgingUpdaterVersion) else { return nil }
            previousTarget = "releases/\(predecessorVersion)"
        }

        let request = appRoot.appendingPathComponent("launch-agent-bridge.request")
        try "\(targetVersion)\n\(previousTarget)\n".write(to: request, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
        return previousTarget
    }

    private static func releaseIsValid(_ release: URL, version: String, appRoot: URL) -> Bool {
        guard stableVersionComponents(version) != nil,
              release.standardizedFileURL.deletingLastPathComponent()
                == appRoot.appendingPathComponent("releases", isDirectory: true).standardizedFileURL,
              let values = try? release.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
        let packagedVersion = (try? String(contentsOf: release.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard packagedVersion == version else { return false }
        return FileManager.default.fileExists(atPath: release.appendingPathComponent("CodexTrafficLightApp").path)
            && FileManager.default.fileExists(atPath: release.appendingPathComponent("wanhe-status-updater").path)
    }

    private static func isStrictlyOlderStable(_ version: String, than target: String) -> Bool {
        guard stableVersionComponents(version) != nil else { return false }
        return versionIsLess(version, target)
    }

    private static func versionIsLess(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = stableVersionComponents(lhs), let right = stableVersionComponents(rhs) else { return false }
        return left.lexicographicallyPrecedes(right)
    }

    private static func stableVersionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...999_999).contains(value) else { return nil }
            components.append(value)
        }
        return components
    }

    private static func defaultRunningUpdaterExecutable(userID: uid_t) -> URL? {
        let service = "gui/\(userID)/\(UpdaterLaunchAgentInstaller.label)"
        let state = run("/bin/launchctl", ["print", service])
        guard state.status == 0 else { return nil }
        let pid = state.output.split(separator: "\n").compactMap { line -> Int? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("pid = ") else { return nil }
            return Int(text.dropFirst("pid = ".count))
        }.first
        guard let pid, pid > 1 else { return nil }

        // `lsof -d txt` reports the resolved executable vnode rather than the
        // stable `current` argv path, which is exactly the predecessor identity
        // needed after the symlink has already changed.
        let opened = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "txt", "-Fn"])
        guard opened.status == 0 else { return nil }
        return opened.output.split(separator: "\n").compactMap { line -> URL? in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst())
            guard (path as NSString).lastPathComponent == "wanhe-status-updater" else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }.first
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, String(describing: error))
        }
    }
}

/// One-time compatibility bridge for releases installed by an older updater.
///
/// The old updater remains alive under the old launchd registration while it
/// swaps `current`. The bridge therefore repairs the main app immediately, but
/// waits until that updater process exits before refreshing the updater job.
/// No team configuration, token, prompt or activity database is read here.
public enum LaunchAgentUpdateBridge {
    public static func rollbackVersion(_ symlinkTarget: String) -> String {
        (symlinkTarget as NSString).lastPathComponent
    }

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
