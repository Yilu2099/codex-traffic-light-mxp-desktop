import Foundation

struct Sub2APIQuota: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        var reset: Date? { Sub2APIQuota.date(resetsAt) }
        var remaining: Double? {
            guard let utilization, utilization.isFinite, utilization >= 0,
                  let reset, reset > Date() else { return nil }
            return max(0, 100 - utilization)
        }
    }

    private let error: String?
    private let errorCode: String?
    let updatedAt: String?
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayFable: Window?

    private struct Envelope: Decodable {
        let code: Int
        let data: Sub2APIQuota?
    }

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }

    static func decode(_ data: Data) throws -> Self? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Envelope.self, from: data)
        guard response.code == 0, let quota = response.data,
              quota.error?.isEmpty != false, quota.errorCode?.isEmpty != false else { return nil }
        return quota
    }

    struct Configuration: Decodable {
        let origin: URL
        let accountID: Int
        let apiKey: String

        static let localFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/claude-sub2api.json")

        static func load(from file: URL = localFile) throws -> Self {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let mode = attributes[.posixPermissions] as? Int, mode & 0o077 == 0 else {
                throw URLError(.noPermissionsToReadFile)
            }
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        }

        func fetch(refresh: Bool = false) async throws -> Sub2APIQuota? {
            guard var url = URLComponents(url: origin, resolvingAgainstBaseURL: false),
                  url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
                  accountID > 0, !apiKey.isEmpty else { throw URLError(.badURL) }
            url.path = "/api/v1/admin/accounts/\(accountID)/usage"
            url.queryItems = [URLQueryItem(name: "source", value: refresh ? "active" : "passive")]
            if refresh { url.queryItems?.append(URLQueryItem(name: "force", value: "true")) }
            url.fragment = nil
            guard let endpoint = url.url else { throw URLError(.badURL) }
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try Sub2APIQuota.decode(data)
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

enum Sub2APIQuotaState {
    case loading, unavailable, sample(Sub2APIQuota)
}
