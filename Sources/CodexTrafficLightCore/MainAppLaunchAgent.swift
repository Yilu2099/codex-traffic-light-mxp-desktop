import Darwin
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

        let bootout = runner(["bootout", service])
        guard bootout.status == 0 || launchctlSaysServiceIsAbsent(bootout.output) else {
            throw MainAppLaunchAgentError.bootoutFailed(bootout.output)
        }
        let bootstrap = runner(["bootstrap", domain, plist.path])
        guard bootstrap.status == 0 else {
            throw MainAppLaunchAgentError.bootstrapFailed(bootstrap.output)
        }
        let kickstart = runner(["kickstart", "-k", service])
        guard kickstart.status == 0 else {
            throw MainAppLaunchAgentError.kickstartFailed(kickstart.output)
        }
        return true
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

        let bootout = runner(["bootout", service])
        guard bootout.status == 0 || launchctlSaysServiceIsAbsent(bootout.output) else {
            throw UpdaterLaunchAgentError.bootoutFailed(bootout.output)
        }
        let bootstrap = runner(["bootstrap", domain, plist.path])
        guard bootstrap.status == 0 else {
            throw UpdaterLaunchAgentError.bootstrapFailed(bootstrap.output)
        }
        let kickstart = runner(["kickstart", "-k", service])
        guard kickstart.status == 0 else {
            throw UpdaterLaunchAgentError.kickstartFailed(kickstart.output)
        }
        return true
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

public enum ExistingLaunchAgentRegistration {
    public static func forceRebootstrap(
        label: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        runLaunchctl: (([String]) -> MainAppLaunchctlResult)? = nil
    ) throws {
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            throw MainAppLaunchAgentError.templateMissing(plist.lastPathComponent)
        }
        let runner = runLaunchctl ?? { arguments in
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
        let domain = "gui/\(userID)"
        let service = "\(domain)/\(label)"
        let bootout = runner(["bootout", service])
        guard bootout.status == 0 || launchctlSaysServiceIsAbsent(bootout.output) else {
            throw MainAppLaunchAgentError.bootoutFailed(bootout.output)
        }
        let bootstrap = runner(["bootstrap", domain, plist.path])
        guard bootstrap.status == 0 else {
            throw MainAppLaunchAgentError.bootstrapFailed(bootstrap.output)
        }
        let kickstart = runner(["kickstart", "-k", service])
        guard kickstart.status == 0 else {
            throw MainAppLaunchAgentError.kickstartFailed(kickstart.output)
        }
    }
}

private func launchctlSaysServiceIsAbsent(_ output: String) -> Bool {
    let normalized = output.lowercased()
    return normalized.contains("could not find service")
        || normalized.contains("could not find specified service")
        || normalized.contains("no such process")
        || normalized.contains("service not found")
}
