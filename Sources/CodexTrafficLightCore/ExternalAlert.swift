import Foundation

public struct ExternalAlert: Codable, Equatable, Sendable {
    public let eventIDs: [String]
    public let title: String
    public let body: String
    public let sourceURL: URL?
    public let createdAt: Date

    public init(eventIDs: [String], title: String, body: String, sourceURL: URL?, createdAt: Date) {
        self.eventIDs = eventIDs
        self.title = title
        self.body = body
        self.sourceURL = sourceURL
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case eventIDs = "event_ids"
        case title
        case body
        case sourceURL = "source_url"
        case createdAt = "created_at"
    }
}

public final class ExternalAlertStore: @unchecked Sendable {
    private struct DeliveryState: Codable {
        var deliveredEventIDs: [String]

        private enum CodingKeys: String, CodingKey {
            case deliveredEventIDs = "delivered_event_ids"
        }
    }

    public let alertURL: URL
    public let deliveryURL: URL

    public init(
        alertURL: URL = StateStore.defaultSupportDirectory().appendingPathComponent("external-alert.json"),
        deliveryURL: URL = StateStore.defaultSupportDirectory().appendingPathComponent("external-alert-delivery.json")
    ) {
        self.alertURL = alertURL
        self.deliveryURL = deliveryURL
    }

    public func nextUnread(now: Date = Date(), maxAge: TimeInterval = 24 * 60 * 60) -> ExternalAlert? {
        guard let data = try? Data(contentsOf: alertURL),
              let alert = try? Self.decoder.decode(ExternalAlert.self, from: data),
              !alert.eventIDs.isEmpty,
              now.timeIntervalSince(alert.createdAt) <= maxAge else { return nil }
        return isUnread(alert) ? alert : nil
    }

    public func isUnread(_ alert: ExternalAlert) -> Bool {
        let delivered = Set(readDeliveryState().deliveredEventIDs)
        return alert.eventIDs.contains(where: { !delivered.contains($0) })
    }

    public func markDelivered(_ alert: ExternalAlert) throws {
        var delivered = Set(readDeliveryState().deliveredEventIDs)
        delivered.formUnion(alert.eventIDs)
        let retained = Array(delivered).sorted().suffix(500)
        let state = DeliveryState(deliveredEventIDs: Array(retained))
        let data = try Self.encoder.encode(state)
        try FileManager.default.createDirectory(
            at: deliveryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: deliveryURL, options: .atomic)
    }

    private func readDeliveryState() -> DeliveryState {
        guard let data = try? Data(contentsOf: deliveryURL),
              let state = try? Self.decoder.decode(DeliveryState.self, from: data) else {
            return DeliveryState(deliveredEventIDs: [])
        }
        return state
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
