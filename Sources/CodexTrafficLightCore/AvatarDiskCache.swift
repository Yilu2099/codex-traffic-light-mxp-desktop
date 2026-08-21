import CryptoKit
import Foundation

public struct AvatarDiskCache: Sendable {
    public let directoryURL: URL

    public init(
        directoryURL: URL = StateStore.defaultSupportDirectory()
            .appendingPathComponent("avatars", isDirectory: true)
    ) {
        self.directoryURL = directoryURL
    }

    public func data(for remoteURL: URL) -> Data? {
        try? Data(contentsOf: fileURL(for: remoteURL))
    }

    public func store(_ data: Data, for remoteURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: remoteURL), options: [.atomic])
    }

    public func fileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        let rawExtension = remoteURL.pathExtension.lowercased()
        let fileExtension = ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(rawExtension)
            ? rawExtension
            : "img"
        return directoryURL.appendingPathComponent(key).appendingPathExtension(fileExtension)
    }
}
