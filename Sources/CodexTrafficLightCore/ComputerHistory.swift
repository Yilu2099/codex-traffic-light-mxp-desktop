import Foundation
import CryptoKit

public struct ComputerHistoryRow: Codable, Equatable, Sendable {
    public var id: String
    public var recordedAt: String
    public var title: String
    public var summary: String
    public var applications: [String]
}

public struct ComputerHistoryReport: Codable, Equatable, Sendable {
    public var collectedAt: String
    public var status: String
    public var rows: [ComputerHistoryRow]
}

/// Read only completed Computer History summaries. Never change observation settings
/// or transmit raw events, screenshots, typed text, source paths or memory instructions.
public enum ComputerHistoryCollector {
    public static func collect(codexHome: URL, now: Date = Date()) -> ComputerHistoryReport {
        let root = codexHome.appendingPathComponent("memories/extensions/skysight/resources")
        let iso = ISO8601DateFormatter()
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { return ComputerHistoryReport(collectedAt: iso.string(from: now), status: "unavailable", rows: []) }
        let filenameDate = DateFormatter()
        filenameDate.locale = Locale(identifier: "en_US_POSIX")
        filenameDate.timeZone = TimeZone(secondsFromGMT: 0)
        filenameDate.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        var rows: [ComputerHistoryRow] = []
        for file in files.filter({ $0.lastPathComponent.contains("-10min-") && $0.pathExtension == "md" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(200) {
            guard let recorded = filenameDate.date(from: String(file.lastPathComponent.prefix(19))),
                  recorded >= now.addingTimeInterval(-7 * 86400), recorded <= now.addingTimeInterval(300),
                  let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? 0) <= 131072,
                  let content = try? String(contentsOf: file, encoding: .utf8), content.hasPrefix("---\n"),
                  let end = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else { continue }
            var fields: [String: String] = [:]
            for line in content[content.index(content.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon])
                guard ["title", "description", "applications"].contains(key) else { continue }
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2 && ((value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'")) { value = String(value.dropFirst().dropLast()) }
                fields[key] = value
            }
            guard let title = fields["title"], !title.isEmpty, let summary = fields["description"], !summary.isEmpty else { continue }
            let apps = (fields["applications"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").prefix(12).map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'" )).prefix(120)) }
            rows.append(ComputerHistoryRow(id: SHA256.hash(data: Data(file.lastPathComponent.utf8)).map { String(format: "%02x", $0) }.joined(), recordedAt: iso.string(from: recorded), title: String(title.prefix(200)), summary: String(summary.prefix(2000)), applications: apps))
            if rows.count == 50 { break }
        }
        return ComputerHistoryReport(collectedAt: iso.string(from: now), status: rows.isEmpty ? "no_records" : "available", rows: rows)
    }
}
