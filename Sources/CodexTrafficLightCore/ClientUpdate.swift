import CryptoKit
import Foundation

public enum ClientVersion {
    public static let current = "1.2.72"
    public static let signingPublicKeyBase64 = "kx2EJhi8RR4A+CTuoSs4Fx5f59+oicxN5z9wMPra3nc="

    public static func compare(_ left: String, _ right: String) -> ComparisonResult {
        func components(_ value: String) -> [Int] {
            value.split(separator: "-", maxSplits: 1).first.map(String.init)?
                .split(separator: ".")
                .map { Int($0) ?? 0 } ?? [0, 0, 0]
        }
        let lhs = components(left)
        let rhs = components(right)
        for index in 0..<max(3, lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }
}

public struct ClientUpdateManifest: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var updateAvailable: Bool
    public var currentVersion: String
    public var latestVersion: String
    public var mandatory: Bool
    public var rolloutEligible: Bool
    public var rolloutPercentage: Int
    public var version: String?
    public var minimumVersion: String?
    public var downloadURL: URL?
    public var sha256: String?
    public var signature: String?
    public var releaseNotes: String?
    public var publishedAt: String?
    public var checkAfterSeconds: Int

    public init(
        enabled: Bool,
        updateAvailable: Bool,
        currentVersion: String,
        latestVersion: String,
        mandatory: Bool,
        rolloutEligible: Bool,
        rolloutPercentage: Int,
        version: String? = nil,
        minimumVersion: String? = nil,
        downloadURL: URL? = nil,
        sha256: String? = nil,
        signature: String? = nil,
        releaseNotes: String? = nil,
        publishedAt: String? = nil,
        checkAfterSeconds: Int = 300
    ) {
        self.enabled = enabled
        self.updateAvailable = updateAvailable
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.mandatory = mandatory
        self.rolloutEligible = rolloutEligible
        self.rolloutPercentage = rolloutPercentage
        self.version = version
        self.minimumVersion = minimumVersion
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.signature = signature
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.checkAfterSeconds = checkAfterSeconds
    }
}

public enum ClientUpdateVerifier {
    public static func signingMessage(version: String, sha256: String) -> Data {
        Data("wanhe-macos-update-v1\n\(version)\n\(sha256.lowercased())\n".utf8)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(version: String, sha256: String, signatureBase64: String) -> Bool {
        guard let publicKeyData = Data(base64Encoded: ClientVersion.signingPublicKeyBase64),
              let signature = Data(base64Encoded: signatureBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: signingMessage(version: version, sha256: sha256))
    }
}

public struct ClientUpdateConfiguration: Equatable, Sendable {
    public var serverURL: URL
    public var token: String
    public var deviceID: String

    public static func load(from url: URL = TeamSyncConfiguration.defaultConfigURL()) -> ClientUpdateConfiguration? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let values = TeamSyncConfiguration.parseEnvironmentFile(source)
        guard let endpointText = values["WANHE_ENDPOINT"],
              let endpoint = URL(string: endpointText),
              let token = values["WANHE_INGEST_TOKEN"], !token.isEmpty else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        guard let serverURL = components?.url else { return nil }
        return ClientUpdateConfiguration(
            serverURL: serverURL,
            token: token,
            deviceID: TeamDeviceIdentity.current().id
        )
    }

    public var manifestURL: URL? {
        guard var components = URLComponents(url: serverURL.appendingPathComponent("api/client/macos/update"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "currentVersion", value: ClientVersion.current),
            URLQueryItem(name: "deviceId", value: deviceID),
        ]
        return components.url
    }

    public var statusURL: URL {
        serverURL.appendingPathComponent("api/client/macos/update-status")
    }
}

public struct UpdateAttempt: Codable, Equatable, Sendable {
    public var version: String
    public var failureCount: Int
    public var lastAttemptAt: Double

    public init(version: String, failureCount: Int, lastAttemptAt: Double) {
        self.version = version
        self.failureCount = failureCount
        self.lastAttemptAt = lastAttemptAt
    }
}

/// launchd re-runs the updater every 5 minutes. Without a memory of past failures a single bad
/// release makes every Mac re-download and re-extract the same package 288 times a day, leaving a
/// discarded copy behind on each attempt. This ledger makes a failing version back off instead.
public struct UpdateLedger {
    /// 5m -> 15m -> 45m -> 2h -> 6h. Past the last step the version is abandoned until a new one ships.
    public static let backoffSeconds: [Double] = [300, 900, 2700, 7200, 21600]

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/update-attempts.json")
    }

    public let url: URL

    public init(url: URL = UpdateLedger.defaultURL) {
        self.url = url
    }

    public func load() -> UpdateAttempt? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UpdateAttempt.self, from: data)
    }

    /// Seconds still to wait before `version` may be retried, or nil when an attempt is allowed.
    /// `.infinity` once the version has burned through every backoff step.
    public func waitBefore(retrying version: String, now: Date = Date()) -> Double? {
        guard let attempt = load(), attempt.version == version, attempt.failureCount > 0 else { return nil }
        guard attempt.failureCount <= Self.backoffSeconds.count else { return .infinity }
        let delay = Self.backoffSeconds[attempt.failureCount - 1]
        let elapsed = now.timeIntervalSince1970 - attempt.lastAttemptAt
        return elapsed >= delay ? nil : delay - elapsed
    }

    public func recordFailure(version: String, now: Date = Date()) {
        let previous = load()
        let count = previous?.version == version ? (previous?.failureCount ?? 0) + 1 : 1
        let attempt = UpdateAttempt(
            version: version, failureCount: count, lastAttemptAt: now.timeIntervalSince1970)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(attempt).write(to: url, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
