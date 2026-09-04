import Darwin
import Foundation

public enum LaunchAgentUpdateBridgeError: Error, CustomStringConvertible {
    case targetVersionNotAllowed
    case unsafePreviousTarget
    case currentTargetMismatch
    case packagedVersionMismatch
    case mainDidNotStayRunning
    case updaterDidNotExit
    case updaterDidNotRunCleanly
    case legacyUpdaterTakeoverFailed
    case legacyUpdaterProcessGroupStillRunning(pid_t)
    case legacyUpdaterServiceStillRegistered
    case bridgeTimedOut
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
        case .updaterDidNotRunCleanly: return "new updater did not complete its first RunAtLoad launch"
        case .legacyUpdaterTakeoverFailed: return "legacy updater could not be safely handed over"
        case .legacyUpdaterProcessGroupStillRunning(let group):
            return "legacy updater process group \(group) remained after job removal"
        case .legacyUpdaterServiceStillRegistered:
            return "legacy updater launchd service remained registered after job removal"
        case .bridgeTimedOut: return "launch agent bridge exceeded its hard deadline"
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

public struct RunningUpdaterProcess: Equatable, Sendable {
    public var pid: pid_t
    public var executable: URL

    public init(pid: pid_t, executable: URL) {
        self.pid = pid
        self.executable = executable
    }
}

public enum LegacyUpdaterProcessGroupTakeover {
    public static func run(
        snapshot: RunningUpdaterProcess,
        expectedExecutable: URL,
        installedPlist: URL,
        service: String,
        maximumPolls: Int = 40,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.05) },
        revalidate: () -> RunningUpdaterProcess?,
        processGroupID: (pid_t) -> pid_t,
        processGroupExists: (pid_t) -> Bool,
        terminateProcessGroup: (pid_t) -> Bool,
        runLaunchctl: ([String]) -> MainAppLaunchctlResult
    ) throws {
        guard snapshot.executable.standardizedFileURL == expectedExecutable.standardizedFileURL,
              let plistData = try? Data(contentsOf: installedPlist),
              let plistObject = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let plistDictionary = plistObject as? [String: Any],
              plistDictionary["Label"] as? String == UpdaterLaunchAgentInstaller.label,
              plistDictionary["AbandonProcessGroup"] as? Bool != true,
              processGroupID(snapshot.pid) == snapshot.pid,
              revalidate() == snapshot else {
            throw LaunchAgentUpdateBridgeError.legacyUpdaterTakeoverFailed
        }

        // With the updater as its process-group leader and launchd retaining
        // the default group ownership, bootout asks launchd to terminate both
        // the parent and any already-spawned child. The CLI itself may time out
        // while launchd is still draining, so only the verified PGID below is
        // authoritative for completion.
        _ = runLaunchctl(["bootout", service])
        var processGroupIsGone = false
        for poll in 0...max(0, maximumPolls) {
            if !processGroupExists(snapshot.pid) {
                processGroupIsGone = true
                break
            }
            if poll < maximumPolls { pause() }
        }
        if !processGroupIsGone {
            guard terminateProcessGroup(snapshot.pid) else {
                throw LaunchAgentUpdateBridgeError.legacyUpdaterProcessGroupStillRunning(snapshot.pid)
            }
            for poll in 0...max(0, maximumPolls) {
                if !processGroupExists(snapshot.pid) {
                    processGroupIsGone = true
                    break
                }
                if poll < maximumPolls { pause() }
            }
        }
        guard processGroupIsGone else {
            throw LaunchAgentUpdateBridgeError.legacyUpdaterProcessGroupStillRunning(snapshot.pid)
        }

        // Process exit alone is insufficient: a loaded StartInterval job can
        // start the old executable again. Require launchd to say the service is
        // absent, retrying bootout when it is still registered or indeterminate.
        for poll in 0...max(0, maximumPolls) {
            let state = runLaunchctl(["print", service])
            if state.status != 0, launchctlSaysServiceIsAbsent(state.output) { return }
            _ = runLaunchctl(["bootout", service])
            if poll < maximumPolls { pause() }
        }
        throw LaunchAgentUpdateBridgeError.legacyUpdaterServiceStillRegistered
    }
}

public enum LegacyIdleUpdaterServiceRemoval {
    public static func run(
        installedPlist: URL,
        service: String,
        maximumPolls: Int = 40,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.05) },
        runLaunchctl: ([String]) -> MainAppLaunchctlResult
    ) throws {
        guard let plistData = try? Data(contentsOf: installedPlist),
              let plistObject = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let plistDictionary = plistObject as? [String: Any],
              plistDictionary["Label"] as? String == UpdaterLaunchAgentInstaller.label,
              plistDictionary["AbandonProcessGroup"] as? Bool != true else {
            throw LaunchAgentUpdateBridgeError.legacyUpdaterTakeoverFailed
        }
        for poll in 0...max(0, maximumPolls) {
            let state = runLaunchctl(["print", service])
            if state.status != 0, launchctlSaysServiceIsAbsent(state.output) { return }
            guard state.status == 0, !state.output.contains("state = running") else {
                throw LaunchAgentUpdateBridgeError.legacyUpdaterServiceStillRegistered
            }
            _ = runLaunchctl(["bootout", service])
            if poll < maximumPolls { pause() }
        }
        throw LaunchAgentUpdateBridgeError.legacyUpdaterServiceStillRegistered
    }
}

public enum LegacyLaunchAgentBridgeRequest {
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
            previousTarget = currentTarget
        } else {
            let executable: URL?
            if let runningUpdaterExecutable {
                executable = runningUpdaterExecutable()
            } else {
                executable = runningUpdaterProcess(userID: userID)?.executable
            }
            guard let executable else { return nil }
            guard executable.lastPathComponent == "wanhe-status-updater" else {
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

    public static func runningUpdaterProcess(userID: uid_t = getuid()) -> RunningUpdaterProcess? {
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
        let executable = opened.output.split(separator: "\n").compactMap { line -> URL? in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst())
            guard (path as NSString).lastPathComponent == "wanhe-status-updater" else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        }.first
        guard let executable else { return nil }
        return RunningUpdaterProcess(pid: pid_t(pid), executable: executable)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let result = boundedProcessResult(executable: executable, arguments: arguments)
        return (result.status, result.output)
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

    /// Repairs the target updater registration when the legacy updater has
    /// already exited successfully before the monitor was scheduled. No
    /// predecessor is guessed and `current` is never changed on this path.
    @discardableResult
    public static func repairCurrentUpdaterIfIdle(
        targetVersion: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        maximumDuration: TimeInterval = 45,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.25) },
        runLaunchctl: (([String]) -> MainAppLaunchctlResult)? = nil
    ) throws -> Bool {
        guard targetVersion == ClientVersion.current else {
            throw LaunchAgentUpdateBridgeError.targetVersionNotAllowed
        }
        let appRoot = home.appendingPathComponent(".wanhe-codex-token/app", isDirectory: true)
        let current = appRoot.appendingPathComponent("current", isDirectory: true)
        let expectedTarget = "releases/\(targetVersion)"
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == expectedTarget else {
            return false
        }
        let targetRelease = appRoot.appendingPathComponent(expectedTarget, isDirectory: true)
        let targetValues = try? targetRelease.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard targetValues?.isDirectory == true,
              targetValues?.isSymbolicLink != true,
              FileManager.default.fileExists(atPath: targetRelease.appendingPathComponent("CodexTrafficLightApp").path),
              FileManager.default.fileExists(atPath: targetRelease.appendingPathComponent("wanhe-status-updater").path) else {
            throw LaunchAgentUpdateBridgeError.packagedVersionMismatch
        }
        try assertCurrentTarget(current, expectedTarget: expectedTarget, targetVersion: targetVersion)
        let deadline = Date().addingTimeInterval(max(1, maximumDuration))
        let runner = runLaunchctl ?? { arguments in
            boundedProcessResult(
                executable: "/bin/launchctl",
                arguments: arguments,
                timeout: min(5, max(0.1, deadline.timeIntervalSinceNow))
            )
        }
        let mainService = "gui/\(userID)/\(MainAppLaunchAgentInstaller.label)"
        let updaterService = "gui/\(userID)/\(UpdaterLaunchAgentInstaller.label)"
        let mainState = runner(["print", mainService])
        guard mainState.status == 0, mainState.output.contains("state = running") else {
            throw LaunchAgentUpdateBridgeError.mainDidNotStayRunning
        }

        let initialUpdaterState = runner(["print", updaterService])
        if initialUpdaterState.status == 0, initialUpdaterState.output.contains("state = running") {
            return false
        }
        if !(initialUpdaterState.status != 0 && launchctlSaysServiceIsAbsent(initialUpdaterState.output)) {
            guard initialUpdaterState.status == 0 else {
                throw LaunchAgentUpdateBridgeError.legacyUpdaterServiceStillRegistered
            }
            try LegacyIdleUpdaterServiceRemoval.run(
                installedPlist: home.appendingPathComponent("Library/LaunchAgents/\(UpdaterLaunchAgentInstaller.label).plist"),
                service: updaterService,
                pause: pause,
                runLaunchctl: runner
            )
        }

        try ensureBefore(deadline)
        try UpdaterLaunchAgentInstaller.install(
            from: current,
            home: home,
            userID: userID,
            forceRebootstrap: true,
            runLaunchctl: runner
        )
        while true {
            try ensureBefore(deadline)
            try assertCurrentTarget(current, expectedTarget: expectedTarget, targetVersion: targetVersion)
            switch updaterLaunchState(runner(["print", updaterService])) {
            case .completedSuccessfully:
                let finalMainState = runner(["print", mainService])
                guard finalMainState.status == 0, finalMainState.output.contains("state = running") else {
                    throw LaunchAgentUpdateBridgeError.mainDidNotStayRunning
                }
                let marker = appRoot.appendingPathComponent("launch-agent-bridge-\(targetVersion).done")
                try targetVersion.write(to: marker, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
                return true
            case .completedWithFailure:
                throw LaunchAgentUpdateBridgeError.updaterDidNotRunCleanly
            case .pending:
                pause()
            }
        }
    }

    @discardableResult
    public static func run(
        targetVersion: String,
        previousTarget: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        maximumUpdaterPolls: Int = 240,
        maximumDuration: TimeInterval = 75,
        allowActivationFromPrevious: Bool = false,
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.25) },
        runLaunchctl: (([String]) -> MainAppLaunchctlResult)? = nil,
        takeOverLegacyUpdater: ((String) throws -> Void)? = nil
    ) throws -> LaunchAgentUpdateBridgeResult {
        guard targetVersion == ClientVersion.current else {
            throw LaunchAgentUpdateBridgeError.targetVersionNotAllowed
        }
        let previousVersion = rollbackVersion(previousTarget)
        guard isSafeReleaseTarget(previousTarget),
              stableVersionComponents(previousVersion) != nil,
              stableVersionComponents(targetVersion) != nil,
              versionIsLess(previousVersion, targetVersion) else {
            throw LaunchAgentUpdateBridgeError.unsafePreviousTarget
        }

        let fileManager = FileManager.default
        let appRoot = home.appendingPathComponent(".wanhe-codex-token/app", isDirectory: true)
        let current = appRoot.appendingPathComponent("current")
        let expectedTarget = "releases/\(targetVersion)"
        let initialCurrentTarget = try? fileManager.destinationOfSymbolicLink(atPath: current.path)
        guard initialCurrentTarget == expectedTarget
                || (allowActivationFromPrevious && initialCurrentTarget == previousTarget) else {
            throw LaunchAgentUpdateBridgeError.currentTargetMismatch
        }
        let targetRelease = appRoot.appendingPathComponent(expectedTarget, isDirectory: true)
        let targetValues = try? targetRelease.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let packagedVersion = (try? String(contentsOf: targetRelease.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard targetValues?.isDirectory == true,
              targetValues?.isSymbolicLink != true,
              packagedVersion == targetVersion,
              fileManager.fileExists(atPath: targetRelease.appendingPathComponent("CodexTrafficLightApp").path),
              fileManager.fileExists(atPath: targetRelease.appendingPathComponent("wanhe-status-updater").path) else {
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

        let overallDeadline = Date().addingTimeInterval(max(1, maximumDuration))
        let activationDeadline = Date().addingTimeInterval(max(0.5, maximumDuration - 15))
        let runner = runLaunchctl ?? { arguments in
            let remaining = max(0.1, overallDeadline.timeIntervalSinceNow)
            return boundedProcessResult(
                executable: "/bin/launchctl",
                arguments: arguments,
                timeout: min(5, remaining)
            )
        }
        var predecessorUpdaterWasTakenOver = false
        do {
            try ensureBefore(activationDeadline)
            // Every predecessor updater, including 1.2.91+, must be retired
            // before this transaction changes `current` or either LaunchAgent.
            // Otherwise its own post-download bootstrap can race this helper
            // and produce launchd EIO/constraint failures.
            if let takeOverLegacyUpdater {
                try takeOverLegacyUpdater(previousTarget)
            } else {
                try defaultTakeOverLegacyUpdater(
                    previousTarget: previousTarget,
                    home: home,
                    userID: userID,
                    runLaunchctl: runner
                )
            }
            predecessorUpdaterWasTakenOver = true
            let targetAfterTakeover = try? fileManager.destinationOfSymbolicLink(atPath: current.path)
            if targetAfterTakeover == previousTarget {
                try swapCurrentLink(current: current, target: expectedTarget)
            } else if targetAfterTakeover != expectedTarget {
                throw LaunchAgentUpdateBridgeError.currentTargetMismatch
            }
            try assertCurrentTarget(current, expectedTarget: expectedTarget, targetVersion: targetVersion)
            try MainAppLaunchAgentInstaller.install(
                from: current,
                home: home,
                userID: userID,
                forceRebootstrap: true,
                runLaunchctl: runner
            )
            try ensureBefore(activationDeadline)

            let mainService = "gui/\(userID)/\(MainAppLaunchAgentInstaller.label)"
            var mainRunning = false
            for poll in 0...12 {
                try ensureBefore(activationDeadline)
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
                try ensureBefore(activationDeadline)
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

            try ensureBefore(activationDeadline)
            try assertCurrentTarget(current, expectedTarget: expectedTarget, targetVersion: targetVersion)
            try UpdaterLaunchAgentInstaller.install(
                from: current,
                home: home,
                userID: userID,
                forceRebootstrap: true,
                runLaunchctl: runner
            )
            var updaterStartedCleanly = false
            while !updaterStartedCleanly {
                try ensureBefore(activationDeadline)
                try assertCurrentTarget(current, expectedTarget: expectedTarget, targetVersion: targetVersion)
                switch updaterLaunchState(runner(["print", updaterService])) {
                case .completedSuccessfully:
                    updaterStartedCleanly = true
                case .completedWithFailure:
                    throw LaunchAgentUpdateBridgeError.updaterDidNotRunCleanly
                case .pending:
                    pause()
                }
            }
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
            // Persist backoff before bootstrapping the rollback updater. Its
            // RunAtLoad process must observe the failed target immediately and
            // must not start a second overlapping download/install attempt.
            UpdateLedger(
                url: home.appendingPathComponent(".wanhe-codex-token/update-attempts.json")
            ).recordFailure(version: targetVersion)
            if !predecessorUpdaterWasTakenOver
                || (error as? LaunchAgentUpdateBridgeError).map({ takeoverFailureRequiresFormalRepair($0) }) == true {
                // A surviving child may still carry the predecessor's queued
                // kickstart. Never change current or either launch agent until
                // a formal repair can prove that process group is gone.
                throw LaunchAgentUpdateBridgeError.activationFailed(activation)
            }
            do {
                try ensureBefore(overallDeadline)
                let rollbackRelease = appRoot.appendingPathComponent(previousTarget, isDirectory: true)
                let rollbackVersion = Self.rollbackVersion(previousTarget)
                let rollbackPackagedVersion = (try? String(
                    contentsOf: rollbackRelease.appendingPathComponent("VERSION"),
                    encoding: .utf8
                ))?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rollbackValues = try? rollbackRelease.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard rollbackValues?.isDirectory == true,
                      rollbackValues?.isSymbolicLink != true,
                      rollbackPackagedVersion == rollbackVersion,
                      fileManager.fileExists(atPath: rollbackRelease.appendingPathComponent("CodexTrafficLightApp").path),
                      fileManager.fileExists(atPath: rollbackRelease.appendingPathComponent("wanhe-status-updater").path) else {
                    throw LaunchAgentUpdateBridgeError.unsafePreviousTarget
                }
                try swapCurrentLink(current: current, target: previousTarget)
                try ExistingLaunchAgentRegistration.forceRebootstrap(
                    label: UpdaterLaunchAgentInstaller.label,
                    home: home,
                    userID: userID,
                    runLaunchctl: runner
                )
                try ExistingLaunchAgentRegistration.forceRebootstrap(
                    label: MainAppLaunchAgentInstaller.label,
                    home: home,
                    userID: userID,
                    runLaunchctl: runner
                )
                try ensureBefore(overallDeadline)
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

    private static func versionIsLess(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = stableVersionComponents(lhs), let right = stableVersionComponents(rhs) else { return false }
        return left.lexicographicallyPrecedes(right)
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

    private static func ensureBefore(_ deadline: Date) throws {
        guard Date() < deadline else { throw LaunchAgentUpdateBridgeError.bridgeTimedOut }
    }

    private static func takeoverFailureRequiresFormalRepair(_ error: LaunchAgentUpdateBridgeError) -> Bool {
        switch error {
        case .legacyUpdaterProcessGroupStillRunning, .legacyUpdaterServiceStillRegistered:
            return true
        default:
            return false
        }
    }

    private enum UpdaterLaunchState {
        case pending
        case completedSuccessfully
        case completedWithFailure
    }

    private static func updaterLaunchState(_ result: MainAppLaunchctlResult) -> UpdaterLaunchState {
        guard result.status == 0 else { return .pending }
        let output = result.output.lowercased()
        let completed = output.contains("state = exited") || output.contains("state = not running")
        guard completed else { return .pending }
        if output.contains("last exit code = 0") || output.contains("last exit status = 0") {
            return .completedSuccessfully
        }
        let hasExitCode = output.contains("last exit code =") || output.contains("last exit status =")
        return hasExitCode ? .completedWithFailure : .pending
    }

    private static func defaultTakeOverLegacyUpdater(
        previousTarget: String,
        home: URL,
        userID: uid_t,
        runLaunchctl: ([String]) -> MainAppLaunchctlResult
    ) throws {
        let expected = home.appendingPathComponent(".wanhe-codex-token/app")
            .appendingPathComponent(previousTarget)
            .appendingPathComponent("wanhe-status-updater")
            .standardizedFileURL
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(UpdaterLaunchAgentInstaller.label).plist")
        let service = "gui/\(userID)/\(UpdaterLaunchAgentInstaller.label)"
        guard let snapshot = LegacyLaunchAgentBridgeRequest.runningUpdaterProcess(userID: userID) else {
            try LegacyIdleUpdaterServiceRemoval.run(
                installedPlist: plist,
                service: service,
                runLaunchctl: runLaunchctl
            )
            return
        }
        try LegacyUpdaterProcessGroupTakeover.run(
            snapshot: snapshot,
            expectedExecutable: expected,
            installedPlist: plist,
            service: service,
            revalidate: { LegacyLaunchAgentBridgeRequest.runningUpdaterProcess(userID: userID) },
            processGroupID: { getpgid($0) },
            processGroupExists: { processGroup in
                if kill(-processGroup, 0) == 0 { return true }
                return errno != ESRCH
            },
            terminateProcessGroup: { processGroup in
                if kill(-processGroup, SIGKILL) == 0 { return true }
                return errno == ESRCH
            },
            runLaunchctl: runLaunchctl
        )
    }
}
