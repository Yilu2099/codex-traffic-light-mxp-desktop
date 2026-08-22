import CryptoKit
import Foundation

public enum ClientVersion {
    public static let current = "1.2.53"
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
