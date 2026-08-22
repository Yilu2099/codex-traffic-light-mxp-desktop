import CodexTrafficLightCore
import Darwin
import Foundation

enum UpdateFailure: Error, CustomStringConvertible {
    case configurationMissing
    case invalidManifest
    case invalidDownload
    case checksumMismatch
    case signatureInvalid
    case packageInvalid(String)
    case commandFailed(String)
    case launchFailed

    var description: String {
        switch self {
        case .configurationMissing: return "update configuration is missing"
        case .invalidManifest: return "server returned an invalid update manifest"
        case .invalidDownload: return "update download failed"
        case .checksumMismatch: return "update checksum did not match"
        case .signatureInvalid: return "update signature is invalid"
        case .packageInvalid(let detail): return "update package is invalid: \(detail)"
        case .commandFailed(let detail): return "command failed: \(detail)"
        case .launchFailed: return "new version did not stay running"
        }
    }
}

struct ProcessResult {
    var status: Int32
    var output: String
}

@main
struct WanheStatusUpdater {
    static let appLabel = "com.codex.traffic-light-mxp"

    static func main() async {
        guard let configuration = ClientUpdateConfiguration.load() else {
            appendLog("skip: configuration missing")
            return
        }
        do {
            try ensureMainAppLaunchAgent()
        } catch {
            appendLog("main app watchdog repair failed: \(error)")
        }
        do {
            let manifest = try await fetchManifest(configuration)
            guard manifest.enabled, manifest.updateAvailable else {
                appendLog("checked: current=\(ClientVersion.current) latest=\(manifest.latestVersion) available=false")
                return
            }
            try await install(manifest, configuration: configuration)
        } catch {
            appendLog("failed: \(error)")
            await report(configuration, version: ClientVersion.current, status: "failed", error: String(describing: error))
        }
    }

    static func fetchManifest(_ configuration: ClientUpdateConfiguration) async throws -> ClientUpdateManifest {
        guard let url = configuration.manifestURL else { throw UpdateFailure.invalidManifest }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateFailure.invalidManifest }
        return try JSONDecoder().decode(ClientUpdateManifest.self, from: data)
    }

    static func install(_ manifest: ClientUpdateManifest, configuration: ClientUpdateConfiguration) async throws {
        guard let version = manifest.version,
              ClientVersion.compare(version, ClientVersion.current) == .orderedDescending,
              let downloadURL = manifest.downloadURL,
              downloadURL.scheme == "https",
              let expectedHash = manifest.sha256?.lowercased(), expectedHash.count == 64,
              let signature = manifest.signature else { throw UpdateFailure.invalidManifest }

        await report(configuration, version: ClientVersion.current, status: "downloading", error: nil)
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 180
        let (archiveData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateFailure.invalidDownload }
        guard ClientUpdateVerifier.sha256Hex(archiveData) == expectedHash else { throw UpdateFailure.checksumMismatch }
        guard ClientUpdateVerifier.verify(version: version, sha256: expectedHash, signatureBase64: signature) else {
            throw UpdateFailure.signatureInvalid
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let appRoot = home.appendingPathComponent(".wanhe-codex-token/app", isDirectory: true)
        let releases = appRoot.appendingPathComponent("releases", isDirectory: true)
        let staging = appRoot.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("update.tar.gz")
        try archiveData.write(to: archive, options: .atomic)
        let extract = run("/usr/bin/tar", ["-xzf", archive.path, "-C", payload.path])
        guard extract.status == 0 else { throw UpdateFailure.commandFailed("tar \(extract.output)") }
        try validatePayload(payload, version: version)

        try fileManager.createDirectory(at: releases, withIntermediateDirectories: true)
        let release = releases.appendingPathComponent(version, isDirectory: true)
        if fileManager.fileExists(atPath: release.path) {
            let failed = appRoot.appendingPathComponent("failed-\(version)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
            try fileManager.moveItem(at: release, to: failed)
        }
        try fileManager.moveItem(at: payload, to: release)

        try DesktopMonitorInstaller.install(from: release, home: home)

        let current = appRoot.appendingPathComponent("current")
        let previousTarget = try? fileManager.destinationOfSymbolicLink(atPath: current.path)
        _ = run("/bin/launchctl", ["kill", "SIGTERM", "gui/\(getuid())/\(appLabel)"])
        try swapCurrentLink(current: current, target: "releases/\(version)")
        ensureCommandLinks(home: home)
        _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(appLabel)"])
        try await Task.sleep(for: .seconds(3))

        let launchState = run("/bin/launchctl", ["print", "gui/\(getuid())/\(appLabel)"])
        guard launchState.status == 0, launchState.output.contains("state = running") else {
            if let previousTarget {
                try? swapCurrentLink(current: current, target: previousTarget)
                _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(appLabel)"])
            }
            throw UpdateFailure.launchFailed
        }

        appendLog("installed: \(ClientVersion.current) -> \(version) mandatory=\(manifest.mandatory)")
        await report(configuration, version: version, status: "installed", error: nil)
    }

    static func validatePayload(_ payload: URL, version: String) throws {
        let fileManager = FileManager.default
        let required = [
            "CodexTrafficLightApp", "codex-light-mxp", "codex-light-hook-mxp", "wanhe-status-updater",
            "codex-light-codex-monitor", "com.codex.traffic-light-codex-monitor.plist.template",
            "com.codex.traffic-light-mxp.plist.template",
            "CodexTrafficLightMXP_CodexTrafficLightApp.bundle", "VERSION",
        ]
        for name in required where !fileManager.fileExists(atPath: payload.appendingPathComponent(name).path) {
            throw UpdateFailure.packageInvalid("missing \(name)")
        }
        let packagedVersion = try String(contentsOf: payload.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard packagedVersion == version else { throw UpdateFailure.packageInvalid("version mismatch") }
        for name in required.prefix(5) {
            let url = payload.appendingPathComponent(name)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static func swapCurrentLink(current: URL, target: String) throws {
        let next = current.deletingLastPathComponent().appendingPathComponent("current.next")
        try? FileManager.default.removeItem(at: next)
        guard symlink(target, next.path) == 0 else { throw UpdateFailure.commandFailed("symlink errno=\(errno)") }
        guard rename(next.path, current.path) == 0 else { throw UpdateFailure.commandFailed("rename errno=\(errno)") }
    }

    static func ensureCommandLinks(home: URL) {
        let bin = home.appendingPathComponent(".codex/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["codex-light-mxp", "codex-light-hook-mxp"] {
            let link = bin.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../.wanhe-codex-token/app/current/\(name)")
        }
    }

    static func ensureMainAppLaunchAgent(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let current = home.appendingPathComponent(".wanhe-codex-token/app/current", isDirectory: true)
        let templateURL = current.appendingPathComponent("com.codex.traffic-light-mxp.plist.template")
        guard FileManager.default.fileExists(atPath: templateURL.path) else { return }

        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistURL = launchAgents.appendingPathComponent("\(appLabel).plist")
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        let rendered = template
            .replacingOccurrences(of: "__APP_PATH__", with: current.appendingPathComponent("CodexTrafficLightApp").path)
            .replacingOccurrences(of: "__HOME__", with: home.path)
        let existing = try? String(contentsOf: plistURL, encoding: .utf8)
        let domain = "gui/\(getuid())"

        if existing != rendered {
            try rendered.write(to: plistURL, atomically: true, encoding: .utf8)
            _ = run("/bin/launchctl", ["bootout", "\(domain)/\(appLabel)"])
            let bootstrap = run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
            guard bootstrap.status == 0 else {
                throw UpdateFailure.commandFailed("launchctl bootstrap \(bootstrap.output)")
            }
            appendLog("repaired: main app launch agent KeepAlive enabled")
            return
        }

        let state = run("/bin/launchctl", ["print", "\(domain)/\(appLabel)"])
        if state.status != 0 {
            let bootstrap = run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
            guard bootstrap.status == 0 else {
                throw UpdateFailure.commandFailed("launchctl bootstrap \(bootstrap.output)")
            }
            appendLog("repaired: main app launch agent was missing and has been restored")
        }
    }

    static func report(_ configuration: ClientUpdateConfiguration, version: String, status: String, error: String?) async {
        var request = URLRequest(url: configuration.statusURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "currentVersion": version,
            "status": status,
            "error": error ?? "",
        ])
        _ = try? await URLSession.shared.data(for: request)
    }

    static func run(_ executable: String, _ arguments: [String]) -> ProcessResult {
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
            return ProcessResult(status: process.terminationStatus, output: output)
        } catch {
            return ProcessResult(status: -1, output: String(describing: error))
        }
    }

    static func appendLog(_ line: String) {
        let fileManager = FileManager.default
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/logs/updater.log")
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(timestamp) \(line)\n".utf8)
        if fileManager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
