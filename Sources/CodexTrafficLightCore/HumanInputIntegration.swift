import Foundation

/// Only timestamp evidence is exported; device signals and cache secrets stay local.
public struct HumanInputMetadata: Codable, Equatable, Sendable {
    public var schema = "human_input_metadata_v1"
    public var dot: DotInputSnapshot?
    public var nativeCoverage: NativeInputCoverage?
    public init(dot: DotInputSnapshot? = nil, nativeCoverage: NativeInputCoverage? = nil) {
        self.dot = dot; self.nativeCoverage = nativeCoverage
    }
}

public struct NativeInputCoverage: Codable, Equatable, Sendable {
    public var complete: Bool
    public var startDay: String
    public var endDay: String
    public var throughAt: String? = nil
    public init(complete: Bool, startDay: String, endDay: String, throughAt: String? = nil) {
        self.complete = complete; self.startDay = startDay; self.endDay = endDay; self.throughAt = throughAt
    }
}

public enum HumanInputIntegration {
    // Own-account trial until source -> signed client -> server acceptance is verified.
    public static func enabled(configuration: TeamSyncConfiguration) -> Bool { configuration.userID == "zlu" }

    public static func cachedDot(configuration: TeamSyncConfiguration, now: Date = Date()) -> DotInputSnapshot? {
        guard enabled(configuration: configuration),
              let identity = try? DotInputIdentity(codexHome: configuration.codexHome) else { return nil }
        return DotInputSampler.read(cacheURL: DotInputSampler.defaultCacheURL(codexHome: configuration.codexHome), identity: identity, now: now)
    }

    /// Use the same helper identity as the verified CLI transport. An application
    /// executable's default HTTP identity is rejected by the upstream read endpoint.
    /// The child contains no credentials in argv or environment and is cancelled with the app.
    public static func run(configuration: TeamSyncConfiguration) async {
        guard enabled(configuration: configuration) else { return }
        while !Task.isCancelled {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("codex-light-mxp")
            process.arguments = ["dot-input-sample", "--json"]
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": configuration.codexHome.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            await withTaskCancellationHandler {
                do {
                    try process.run()
                    while process.isRunning && !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
                } catch {}
                if process.isRunning { process.terminate() }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}
