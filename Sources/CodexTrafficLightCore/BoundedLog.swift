import Darwin
import Foundation

public enum BoundedLog {
    public static let defaultMaximumBytes: Int64 = 1_048_576
    private static let processLock = NSLock()

    public static func append(
        _ data: Data,
        to url: URL,
        maximumBytes: Int64 = defaultMaximumBytes
    ) {
        let fileManager = FileManager.default
        processLock.lock()
        defer { processLock.unlock() }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let byteLimit = max(1, maximumBytes)
            let integerLimit = byteLimit > Int64(Int.max) ? Int.max : Int(byteLimit)
            let payload = data.count > integerLimit ? Data(data.suffix(integerLimit)) : data
            let lockURL = url.appendingPathExtension("lock")
            let lockDescriptor = lockURL.path.withCString {
                Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            }
            guard lockDescriptor >= 0 else { return }
            defer { Darwin.close(lockDescriptor) }
            guard Darwin.lockf(lockDescriptor, F_LOCK, 0) == 0 else { return }
            defer { _ = Darwin.lockf(lockDescriptor, F_ULOCK, 0) }

            let currentSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if currentSize > 0 && currentSize > byteLimit - Int64(payload.count) {
                let previous = url.appendingPathExtension("previous")
                try? fileManager.removeItem(at: previous)
                if currentSize > byteLimit {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(currentSize - byteLimit))
                    try (handle.readDataToEndOfFile()).write(to: previous, options: .atomic)
                    try fileManager.removeItem(at: url)
                } else {
                    try fileManager.moveItem(at: url, to: previous)
                }
            }
            if fileManager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: url, options: .atomic)
            }
        } catch {
            return
        }
    }

    public static func append(
        _ text: String,
        to url: URL,
        maximumBytes: Int64 = defaultMaximumBytes
    ) {
        append(Data(text.utf8), to: url, maximumBytes: maximumBytes)
    }
}
