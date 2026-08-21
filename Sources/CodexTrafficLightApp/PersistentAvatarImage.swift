import AppKit
import CodexTrafficLightCore
import Foundation
import SwiftUI

@MainActor
private final class PersistentAvatarLoader: ObservableObject {
    @Published private(set) var image: NSImage?

    private static var inFlight: [URL: Task<Data?, Never>] = [:]
    private let remoteURL: URL
    private let cache: AvatarDiskCache

    init(remoteURL: URL, cache: AvatarDiskCache = AvatarDiskCache()) {
        self.remoteURL = remoteURL
        self.cache = cache
        if let data = cache.data(for: remoteURL), let cachedImage = NSImage(data: data) {
            image = cachedImage
        } else {
            image = nil
            fetchAndPersist()
        }
    }

    private func fetchAndPersist() {
        let task: Task<Data?, Never>
        if let existing = Self.inFlight[remoteURL] {
            task = existing
        } else {
            let url = remoteURL
            let cache = cache
            task = Task {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          NSImage(data: data) != nil else { return nil }
                    try cache.store(data, for: url)
                    return data
                } catch {
                    return nil
                }
            }
            Self.inFlight[remoteURL] = task
        }

        let url = remoteURL
        Task { [weak self] in
            let data = await task.value
            Self.inFlight[url] = nil
            guard let data else { return }
            self?.image = NSImage(data: data)
        }
    }
}

struct PersistentAvatarImage: View {
    @StateObject private var loader: PersistentAvatarLoader
    private let fallbackText: String

    init(url: URL, fallbackText: String) {
        _loader = StateObject(wrappedValue: PersistentAvatarLoader(remoteURL: url))
        self.fallbackText = fallbackText
    }

    var body: some View {
        if let image = loader.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Text(fallbackText)
                .font(.system(size: 14, weight: .bold))
        }
    }
}

enum PersistentAvatarCachePrefetcher {
    static func prefetch(ranking: TeamRankingSnapshot, websiteURL: URL) async {
        let cache = AvatarDiskCache()
        await withTaskGroup(of: Void.self) { group in
            for member in ranking.members {
                guard let path = member.avatar, path.hasPrefix("/") else { continue }
                let filename = path.split(separator: "/").last.map(String.init) ?? ""
                guard !filename.hasPrefix("codex-") else { continue }
                var remoteURL = websiteURL
                remoteURL.append(path: String(path.dropFirst()))
                guard cache.data(for: remoteURL) == nil else { continue }

                group.addTask {
                    do {
                        let (data, response) = try await URLSession.shared.data(from: remoteURL)
                        guard let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/") == true,
                              !data.isEmpty else { return }
                        try cache.store(data, for: remoteURL)
                    } catch {
                        return
                    }
                }
            }
        }
    }
}
