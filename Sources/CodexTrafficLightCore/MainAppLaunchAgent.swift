import Darwin
import Dispatch
import Foundation

public enum MainAppLaunchAgentError: Error, CustomStringConvertible {
    case templateMissing(String)
    case bootoutFailed(String)
    case bootstrapFailed(String)
    case kickstartFailed(String)

    public var description: String {
        switch self {
        case .templateMissing(let name): return "main app launch agent template is missing \(name)"
        case .bootoutFailed(let detail): return "main app launch agent bootout failed: \(detail)"
        case .bootstrapFailed(let detail): return "main app launch agent bootstrap failed: \(detail)"
        case .kickstartFailed(let detail): return "main app launch agent kickstart failed: \(detail)"
        }
    }
}

public enum UpdaterLaunchAgentError: Error, CustomStringConvertible {
    case templateMissing(String)
    case bootoutFailed(String)
    case bootstrapFailed(String)
    case kickstartFailed(String)

    public var description: String {
        switch self {
        case .templateMissing(let name): return "updater launch agent template is missing \(name)"
        case .bootoutFailed(let detail): return "updater launch agent bootout failed: \(detail)"
        case .bootstrapFailed(let detail): return "updater launch agent bootstrap failed: \(detail)"
        case .kickstartFailed(let detail): return "updater launch agent kickstart failed: \(detail)"
        }
    }
}

public struct MainAppLaunchctlResult: Equatable, Sendable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

private enum LaunchAgentRebootstrapFailure: Error {
    case bootout(String)
    case bootstrap(String)
}

/// `launchctl bootstrap` can transiently return EIO while launchd is still
/// retiring the prior registration. Retry exactly once, and only after a fresh
/// bootout plus explicit proof that the service is absent. Other errors remain
/// terminal; a loaded service is never treated as a successful removal.
private enum LaunchAgentRebootstrap {
    static func run(
        domain: String,
        service: String,
        plist: URL,
        maximumAbsencePolls: Int = 8,
        pause: () -> Void,
        runLaunchctl: ([String]) -> MainAppLaunchctlResult
    ) throws {
        let initialBootout = runLaunchctl(["bootout", service])
        guard initialBootout.status == 0
                || launchctlSaysServiceIsAbsent(initialBootout.output)
                || isEIO(initialBootout) else {
            throw LaunchAgentRebootstrapFailure.bootout(initialBootout.output)
        }
        try requireServiceAbsent(
            service,
            maximumPolls: maximumAbsencePolls,
            pause: pause,
            runLaunchctl: runLaunchctl
        )
        if isEIO(initialBootout) {
            pause()
            try requireServiceAbsent(service, maximumPolls: 0, pause: pause, runLaunchctl: runLaunchctl)
        }

        let firstBootstrap = runLaunchctl(["bootstrap", domain, plist.path])
        guard firstBootstrap.status != 0 else { return }
        guard isEIO(firstBootstrap) else {
            throw LaunchAgentRebootstrapFailure.bootstrap(firstBootstrap.output)
        }

        // A failed bootstrap may have partially registered the job. Remove it
        // again and prove absence before the sole retry.
        let retryBootout = runLaunchctl(["bootout", service])
        guard retryBootout.status == 0
                || launchctlSaysServiceIsAbsent(retryBootout.output)
                || isEIO(retryBootout) else {
            throw LaunchAgentRebootstrapFailure.bootout(retryBootout.output)
        }
        try requireServiceAbsent(
            service,
            maximumPolls: maximumAbsencePolls,
            pause: pause,
            runLaunchctl: runLaunchctl
        )
        pause()
        try requireServiceAbsent(service, maximumPolls: 0, pause: pause, runLaunchctl: runLaunchctl)

        let secondBootstrap = runLaunchctl(["bootstrap", domain, plist.path])
        guard secondBootstrap.status == 0 else {
            throw LaunchAgentRebootstrapFailure.bootstrap(secondBootstrap.output)
        }
    }

    private static func requireServiceAbsent(
        _ service: String,
        maximumPolls: Int,
        pause: () -> Void,
        runLaunchctl: ([String]) -> MainAppLaunchctlResult
    ) throws {
        var last = MainAppLaunchctlResult(status: -1, output: "service absence was not confirmed")
        for poll in 0...max(0, maximumPolls) {
            last = runLaunchctl(["print", service])
            if last.status != 0, launchctlSaysServiceIsAbsent(last.output) { return }
            if poll < maximumPolls { pause() }
        }
        throw LaunchAgentRebootstrapFailure.bootout(last.output.isEmpty ? "service remained registered" : last.output)
    }

    private static func isEIO(_ result: MainAppLaunchctlResult) -> Bool {
        result.status == EIO || result.output.lowercased().contains("input/output error")
    }
}

public enum MainAppLaunchAgentInstaller {
    public static let label = "com.codex.traffic-light-mxp"

    /// Re-renders the stable `current` path and, when forced, unregisters and
    /// registers the job even if the plist text is unchanged. macOS launch
    /// constraints bind a registered job to the executable's signing identity;
    /// changing the symlink target therefore requires a fresh bootstrap.
    @discardableResult
    public static func install(
        from release: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        forceRebootstrap: Bool = false,
        bootstrapRetryPause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) },
        runLaunchctl: (([String]) -> MainAppLaunchctlResult)? = nil
    ) throws -> Bool {
        let fileManager = FileManager.default
        let templateURL = release.appendingPathComponent("\(label).plist.template")
        guard fileManager.fileExists(atPath: templateURL.path) else {
            throw MainAppLaunchAgentError.templateMissing(templateURL.lastPathComponent)
        }

        let current = home.appendingPathComponent(".wanhe-codex-token/app/current", isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plist = launchAgents.appendingPathComponent("\(label).plist")
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let rendered = template
            .replacingOccurrences(of: "__APP_PATH__", with: current.appendingPathComponent("CodexTrafficLightApp").path)
            .replacingOccurrences(of: "__HOME__", with: home.path)
        let plistChanged = (try? String(contentsOf: plist, encoding: .utf8)) != rendered
        if plistChanged {
            try rendered.write(to: plist, atomically: true, encoding: .utf8)
        }

        let runner = runLaunchctl ?? defaultRunLaunchctl
        let domain = "gui/\(userID)"
        let service = "\(domain)/\(label)"
        let registered = runner(["print", service]).status == 0
        guard forceRebootstrap || plistChanged || !registered else { return false }

        do {
            try LaunchAgentRebootstrap.run(
                domain: domain,
                service: service,
                plist: plist,
                pause: bootstrapRetryPause,
                runLaunchctl: runner
            )
        } catch LaunchAgentRebootstrapFailure.bootout(let detail) {
            throw MainAppLaunchAgentError.bootoutFailed(detail)
        } catch LaunchAgentRebootstrapFailure.bootstrap(let detail) {
            throw MainAppLaunchAgentError.bootstrapFailed(detail)
        }
        // RunAtLoad starts the freshly bootstrapped job. An immediate
        // `kickstart -k` kills that valid first process and causes launchd's
        // crash throttle to leave the old updater's health check in a gap.
        return true
    }

    private static func defaultRunLaunchctl(_ arguments: [String]) -> MainAppLaunchctlResult {
        boundedProcessResult(executable: "/bin/launchctl", arguments: arguments)
    }
}

public enum UpdaterLaunchAgentInstaller {
    public static let label = "com.codex.traffic-light-mxp-updater"

    /// Re-registering the updater is separate from activating the main app:
    /// the updater job may still be running the predecessor binary while the
    /// stable `current` symlink is switched to a newly signed release.
    @discardableResult
    public static func install(
        from release: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        forceRebootstrap: Bool = false,
        bootstrapRetryPause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) },
        runLaunchctl: (([String]) -> MainAppLaunchctlResult)? = nil
    ) throws -> Bool {
        let fileManager = FileManager.default
        let templateURL = release.appendingPathComponent("\(label).plist.template")
        guard fileManager.fileExists(atPath: templateURL.path) else {
            throw UpdaterLaunchAgentError.templateMissing(templateURL.lastPathComponent)
        }

        let current = home.appendingPathComponent(".wanhe-codex-token/app/current", isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plist = launchAgents.appendingPathComponent("\(label).plist")
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let rendered = template
            .replacingOccurrences(of: "__UPDATER_PATH__", with: current.appendingPathComponent("wanhe-status-updater").path)
            .replacingOccurrences(of: "__HOME__", with: home.path)
        let plistChanged = (try? String(contentsOf: plist, encoding: .utf8)) != rendered
        if plistChanged {
            try rendered.write(to: plist, atomically: true, encoding: .utf8)
        }

        let runner = runLaunchctl ?? defaultRunLaunchctl
        let domain = "gui/\(userID)"
        let service = "\(domain)/\(label)"
        let registered = runner(["print", service]).status == 0
        guard forceRebootstrap || plistChanged || !registered else { return false }

        do {
            try LaunchAgentRebootstrap.run(
                domain: domain,
                service: service,
                plist: plist,
                pause: bootstrapRetryPause,
                runLaunchctl: runner
            )
        } catch LaunchAgentRebootstrapFailure.bootout(let detail) {
            throw UpdaterLaunchAgentError.bootoutFailed(detail)
        } catch LaunchAgentRebootstrapFailure.bootstrap(let detail) {
            throw UpdaterLaunchAgentError.bootstrapFailed(detail)
        }
        // RunAtLoad is sufficient; do not kill the just-started updater.
        return true
    }

    private static func defaultRunLaunchctl(_ arguments: [String]) -> MainAppLaunchctlResult {
        boundedProcessResult(executable: "/bin/launchctl", arguments: arguments)
    }
}

public enum ExistingLaunchAgentRegistration {
    public static func forceBootout(
        label: String,
        userID: uid_t = getuid(),
        runLaunchctl: ([String]) -> MainAppLaunchctlResult
    ) throws {
        let service = "gui/\(userID)/\(label)"
        let bootout = runLaunchctl(["bootout", service])
        guard bootout.status == 0 || launchctlSaysServiceIsAbsent(bootout.output) else {
            throw MainAppLaunchAgentError.bootoutFailed(bootout.output)
        }
    }

    public static func forceRebootstrap(
        label: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        bootstrapRetryPause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) },
        runLaunchctl: (([String]) -> MainAppLaunchctlResult)? = nil
    ) throws {
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            throw MainAppLaunchAgentError.templateMissing(plist.lastPathComponent)
        }
        let runner = runLaunchctl ?? { arguments in
            boundedProcessResult(executable: "/bin/launchctl", arguments: arguments)
        }
        let domain = "gui/\(userID)"
        do {
            try LaunchAgentRebootstrap.run(
                domain: domain,
                service: "\(domain)/\(label)",
                plist: plist,
                pause: bootstrapRetryPause,
                runLaunchctl: runner
            )
        } catch LaunchAgentRebootstrapFailure.bootout(let detail) {
            throw MainAppLaunchAgentError.bootoutFailed(detail)
        } catch LaunchAgentRebootstrapFailure.bootstrap(let detail) {
            throw MainAppLaunchAgentError.bootstrapFailed(detail)
        }
        // RunAtLoad is sufficient; rollback must not self-induce throttling.
    }
}

/// launchctl and lsof are local, but a wedged child must not retain the bridge
/// lock forever. On timeout no blocking pipe read or wait is performed after
/// SIGKILL; the monitor can atomically move the request to its failed marker.
func boundedProcessResult(
    executable: String,
    arguments: [String],
    timeout: TimeInterval = 5
) -> MainAppLaunchctlResult {
    let process = Process()
    let pipe = Pipe()
    let finished = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
    } catch {
        return MainAppLaunchctlResult(status: -1, output: String(describing: error))
    }
    if finished.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
        process.terminate()
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        return MainAppLaunchctlResult(status: -2, output: "process timed out")
    }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return MainAppLaunchctlResult(status: process.terminationStatus, output: output)
}

func launchctlSaysServiceIsAbsent(_ output: String) -> Bool {
    let normalized = output.lowercased()
    return normalized.contains("could not find service")
        || normalized.contains("could not find specified service")
        || normalized.contains("no such process")
        || normalized.contains("service not found")
}
