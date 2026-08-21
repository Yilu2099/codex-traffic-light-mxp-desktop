import Darwin
import Foundation

public enum DesktopMonitorInstallerError: Error, CustomStringConvertible {
    case packageMissing(String)
    case replaceFailed(Int32)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .packageMissing(let name): return "desktop monitor package is missing \(name)"
        case .replaceFailed(let code): return "desktop monitor replace failed: errno=\(code)"
        case .launchFailed(let detail): return "desktop monitor launch failed: \(detail)"
        }
    }
}

public enum DesktopMonitorInstaller {
    public static let label = "com.codex.traffic-light-codex-monitor"

    @discardableResult
    public static func install(
        from release: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        restartService: Bool = true
    ) throws -> Bool {
        let fileManager = FileManager.default
        let packagedMonitor = release.appendingPathComponent("codex-light-codex-monitor")
        let packagedTemplate = release.appendingPathComponent("com.codex.traffic-light-codex-monitor.plist.template")
        guard fileManager.fileExists(atPath: packagedMonitor.path) else {
            throw DesktopMonitorInstallerError.packageMissing(packagedMonitor.lastPathComponent)
        }
        guard fileManager.fileExists(atPath: packagedTemplate.path) else {
            throw DesktopMonitorInstallerError.packageMissing(packagedTemplate.lastPathComponent)
        }

        let bin = home.appendingPathComponent(".codex/bin", isDirectory: true)
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)

        let monitor = bin.appendingPathComponent("codex-light-codex-monitor")
        let plist = launchAgents.appendingPathComponent("\(label).plist")
        let monitorData = try Data(contentsOf: packagedMonitor)
        let template = try String(contentsOf: packagedTemplate, encoding: .utf8)
        let rendered = template
            .replacingOccurrences(of: "__MONITOR_PATH__", with: monitor.path)
            .replacingOccurrences(of: "__HOME__", with: home.path)
        let monitorChanged = (try? Data(contentsOf: monitor)) != monitorData
        let plistChanged = (try? String(contentsOf: plist, encoding: .utf8)) != rendered
        guard monitorChanged || plistChanged else { return false }

        if monitorChanged {
            let next = bin.appendingPathComponent("codex-light-codex-monitor.next")
            try? fileManager.removeItem(at: next)
            try monitorData.write(to: next, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: next.path)
            guard rename(next.path, monitor.path) == 0 else {
                throw DesktopMonitorInstallerError.replaceFailed(errno)
            }
        }
        if plistChanged {
            try rendered.write(to: plist, atomically: true, encoding: .utf8)
        }

        if restartService {
            let userID = getuid()
            _ = runLaunchctl(["bootout", "gui/\(userID)/\(label)"])
            let result = runLaunchctl(["bootstrap", "gui/\(userID)", plist.path])
            guard result.status == 0 else {
                throw DesktopMonitorInstallerError.launchFailed(result.output)
            }
        }
        return true
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
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
            return (process.terminationStatus, output)
        } catch {
            return (-1, String(describing: error))
        }
    }
}
