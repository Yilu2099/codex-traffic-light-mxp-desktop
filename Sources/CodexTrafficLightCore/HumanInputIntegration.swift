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

    /// Failure cannot stop quota or native collection, or substitute a token/heartbeat timestamp.
    public static func run(configuration: TeamSyncConfiguration) async {
        guard enabled(configuration: configuration) else { return }
        let sampler = DotInputSampler(cacheURL: DotInputSampler.defaultCacheURL(codexHome: configuration.codexHome))
        while !Task.isCancelled {
            if let identity = try? DotInputIdentity(codexHome: configuration.codexHome) {
                _ = try? await sampler.sample(identity: identity, transport: DotInputHTTP(identity: identity), maxPages: 5)
            }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }
}
