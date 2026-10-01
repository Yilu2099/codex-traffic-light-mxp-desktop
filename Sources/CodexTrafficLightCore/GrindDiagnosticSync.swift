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
        guard configuration.endpoint.absoluteString == "https://c.wanhe.cn/api/usage" else { return nil }
        let scope = GrindDiagnosticReport.hash(Data("\(configuration.userID)|\(TeamDeviceIdentity.current().id)".utf8))
        guard scope == "5421cd1880ea885bbbdb00fc44c76730075b09c9b4f891e3538ea73ea9e114cf" else { return nil }
        let session = URLSession(configuration: .ephemeral, delegate: DiagnosticNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var healthRequest = URLRequest(url: websiteURL.appendingPathComponent("api/health"))
        healthRequest.timeoutInterval = 5
        healthRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let (healthData, healthResponse) = try await session.data(for: healthRequest)
        guard (healthResponse as? HTTPURLResponse)?.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: healthData) as? [String: Any],
              (health["collectorDiagnosticProtocols"] as? [String])?.contains("grind_diagnostic_v2") == true else { return nil }
        let queue = GrindDiagnosticQueue(url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/grind-diagnostic-20260930.json"))
        guard let report = try queue.pending(scope: scope, collect: {
            GrindDiagnosticCollector().collect(codexHome: configuration.codexHome)
        }) else { return nil }
        let body = try report.canonicalData()
        guard report.validForUpload, body.count <= 64 * 1024 else { throw StateStoreError.invalidInput("diagnostic size limit") }
        var request = URLRequest(url: websiteURL.appendingPathComponent("api/collector/diagnostics"))
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
