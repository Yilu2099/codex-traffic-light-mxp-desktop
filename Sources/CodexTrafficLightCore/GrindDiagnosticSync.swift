import Foundation

private final class DiagnosticNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension TeamUsageSyncService {
    /// One campaign, one registered device. No other member's normal sync scans
    /// historical input or uploads diagnostics. A receipt does not apply history.
    public func syncGrindDiagnosticIfNeeded() async throws -> GrindDiagnosticReceipt? {
        guard configuration.endpoint.host?.lowercased() == "c.wanhe.cn",
              configuration.endpoint.port == nil || configuration.endpoint.port == 443 else { return nil }
        // The registered credential is authoritative; local account labels and
        // hardware probes must not silently suppress the authorized campaign.
        let diagnosticBase = URL(string: "https://c.wanhe.cn")!
        let session = URLSession(configuration: .ephemeral, delegate: DiagnosticNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var campaignRequest = URLRequest(url: diagnosticBase.appendingPathComponent("api/collector/diagnostics/campaign"))
        campaignRequest.timeoutInterval = 10
        campaignRequest.cachePolicy = .reloadIgnoringLocalCacheData
        campaignRequest.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        let (campaignData, campaignResponse) = try await session.data(for: campaignRequest)
        guard (campaignResponse as? HTTPURLResponse)?.statusCode == 200 else { throw TeamUsageSyncError.invalidResponse }
        let campaign = try JSONDecoder().decode(GrindDiagnosticCampaign.self, from: campaignData)
        guard campaign.authorized, let scope = campaign.scope else { return nil }
        let queue = GrindDiagnosticQueue(url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/grind-diagnostic-20260930.json"))
        guard let report = try queue.pending(scope: scope, collect: {
            GrindDiagnosticCollector().collect(codexHome: configuration.codexHome)
        }) else { return nil }
        let body = try report.canonicalData()
        guard report.validForUpload, body.count <= 64 * 1024 else { throw StateStoreError.invalidInput("diagnostic size limit") }
        var request = URLRequest(url: diagnosticBase.appendingPathComponent("api/collector/diagnostics"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let receipt = try? JSONDecoder().decode(GrindDiagnosticReceipt.self, from: data), receipt.confirms(report) else {
            throw StateStoreError.invalidInput("diagnostic upload not confirmed")
        }
        try queue.acknowledge(scope: scope, report: report, receipt: receipt)
        return receipt
    }
}

public struct GrindDiagnosticCampaign: Codable, Sendable {
    public var enabled: Bool
    public var schema: String
    public var scope: String?
    public var authorized: Bool {
        enabled && schema == "grind_diagnostic_v2" && scope == "5421cd1880ea885bbbdb00fc44c76730075b09c9b4f891e3538ea73ea9e114cf"
    }
}
