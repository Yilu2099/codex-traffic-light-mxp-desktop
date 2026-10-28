import Foundation

/// Immutable metadata snapshot of the local Codex conversation tree.
///
/// A regular team sync creates this once and shares it across collectors. The
/// snapshot contains metadata only; constructing it never opens conversation
/// files or reads their contents.
public struct CodexSessionFileIndex: Sendable {
    public struct Entry: Sendable, Equatable {
        public var url: URL
        public var modifiedAt: Date
        public var size: Int64
        public var isArchived: Bool
        public var fileIdentifier: String?

        public init(
            url: URL,
            modifiedAt: Date,
            size: Int64,
            isArchived: Bool,
            fileIdentifier: String? = nil
        ) {
            self.url = url
            self.modifiedAt = modifiedAt
            self.size = max(0, size)
            self.isArchived = isArchived
            self.fileIdentifier = fileIdentifier
        }

        public var path: String { url.standardizedFileURL.path }

        /// Rollout filenames contain a UUID and remain unchanged when Codex
        /// moves a live session into archived_sessions.
        public var stableKey: String { url.lastPathComponent }
    }

    public var codexHome: URL
    public var files: [Entry]
    /// False when directory traversal or metadata reads fail. An empty result
    /// alone cannot prove that the device had no usage.
    public var enumerationComplete: Bool

    public init(codexHome: URL) {
        self.codexHome = codexHome
        var entries: [Entry] = []
        var complete = (try? codexHome.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        for folder in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(folder)
            do {
                guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { complete = false; continue }
            } catch {
                let code = (error as NSError).code
                if code != NSFileNoSuchFileError && code != NSFileReadNoSuchFileError { complete = false }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey,
                ],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in complete = false; return true }
            ) else { complete = false; continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(
                    forKeys: [
                        .isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey,
                    ]
                ) else { complete = false; continue }
                guard values.isRegularFile == true else { continue }
                entries.append(Entry(
                    url: url,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    size: Int64(max(0, values.fileSize ?? 0)),
                    isArchived: folder == "archived_sessions",
                    fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
                ))
            }
        }
        files = entries.sorted { $0.path < $1.path }
        enumerationComplete = complete
    }

    /// Test/support initializer for callers that already own a metadata list.
    public init(codexHome: URL, files: [Entry], enumerationComplete: Bool = true) {
        self.codexHome = codexHome
        self.files = files.sorted { $0.path < $1.path }
        self.enumerationComplete = enumerationComplete
    }

    public func uniqueFiles(modifiedSince cutoff: Date = .distantPast) -> [Entry] {
        var unique: [String: Entry] = [:]
        for file in files where file.modifiedAt >= cutoff {
            guard let existing = unique[file.stableKey] else {
                unique[file.stableKey] = file
                continue
            }
            if file.modifiedAt > existing.modifiedAt
                || (file.modifiedAt == existing.modifiedAt && file.size > existing.size)
                || (file.modifiedAt == existing.modifiedAt && file.size == existing.size
                    && !file.isArchived && existing.isArchived) {
                unique[file.stableKey] = file
            }
        }
        return unique.values.sorted { $0.path < $1.path }
    }
}
