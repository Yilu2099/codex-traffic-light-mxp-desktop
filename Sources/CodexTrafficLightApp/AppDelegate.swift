import Cocoa
import CodexTrafficLightCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusBarControllerDelegate {
    private let store = StateStore()
    private lazy var statusBar = StatusBarController()
    private var currentSnapshot: StateSnapshot = .empty()
    private var quotaTimer: Timer?
    private var teamSyncTimer: Timer?
    private var teamRankingTimer: Timer?
    private var teamSyncConfiguration: TeamSyncConfiguration?
    private var isTeamSyncing = false
    private var isTeamRankingRefreshing = false
    private let quotaRefreshCoordinator = QuotaRefreshCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let release = Bundle.main.executableURL?.deletingLastPathComponent() {
            do {
                try DesktopMonitorInstaller.install(from: release)
            } catch DesktopMonitorInstallerError.packageMissing(_) {
                // Local development builds do not contain the packaged monitor files.
            } catch {
                AppDelegate.appendTeamSyncLog("desktop monitor install failed: \(error)")
            }
        }
        statusBar.delegate = self
        currentSnapshot = store.read()
        statusBar.apply(snapshot: currentSnapshot)

        Timer.scheduledTimer(
            timeInterval: 1.5,
            target: self,
            selector: #selector(quotaTimerFired),
            userInfo: nil,
            repeats: false
        )
        quotaTimer = Timer.scheduledTimer(
            timeInterval: Defaults.appServerQuotaRefreshSeconds,
            target: self,
            selector: #selector(quotaTimerFired),
            userInfo: nil,
            repeats: true
        )

        configureTeamIntegration()
    }

    private func configureTeamIntegration() {
        guard let configuration = TeamSyncConfiguration.load() else {
            statusBar.applyTeamRanking(nil, websiteURL: nil, syncDetail: "团队排行榜尚未注册")
            return
        }
        teamSyncConfiguration = configuration
        let websiteURL = TeamUsageSyncService(configuration: configuration).websiteURL
        statusBar.applyTeamRanking(nil, websiteURL: websiteURL, syncDetail: "正在读取团队数据…")
        Timer.scheduledTimer(
            timeInterval: 2.5,
            target: self,
            selector: #selector(teamRankingTimerFired),
            userInfo: nil,
            repeats: false
        )
        Timer.scheduledTimer(
            timeInterval: 8,
            target: self,
            selector: #selector(teamSyncTimerFired),
            userInfo: nil,
            repeats: false
        )
        teamRankingTimer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(teamRankingTimerFired),
            userInfo: nil,
            repeats: true
        )
        teamSyncTimer = Timer.scheduledTimer(
            timeInterval: Defaults.teamSyncRefreshSeconds,
            target: self,
            selector: #selector(teamSyncTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func teamSyncTimerFired() {
        syncTeamData()
    }

    @objc private func teamRankingTimerFired() {
        refreshTeamRanking()
    }

    private func syncTeamData() {
        guard let configuration = teamSyncConfiguration, !isTeamSyncing else { return }
        isTeamSyncing = true
        let quota = TeamQuotaReport.from(snapshot: store.read())
        let service = TeamUsageSyncService(configuration: configuration)
        statusBar.setTeamSyncDetail("正在同步本机数据…", websiteURL: service.websiteURL)
        Task { [weak self] in
            do {
                let ranking = try await Task.detached(priority: .utility) {
                    _ = try await service.sync(quota: quota)
                    let ranking = try await service.fetchRanking(range: "today")
                    await PersistentAvatarCachePrefetcher.prefetch(
                        ranking: ranking,
                        websiteURL: service.websiteURL
                    )
                    return ranking
                }.value
                self?.isTeamSyncing = false
                self?.statusBar.applyTeamRanking(ranking, websiteURL: service.websiteURL, syncDetail: "刚刚同步")
            } catch {
                self?.isTeamSyncing = false
                self?.statusBar.setTeamSyncDetail("团队数据同步失败，稍后重试", websiteURL: service.websiteURL)
                AppDelegate.appendTeamSyncLog("sync failed: \(error)")
            }
        }
    }

    private func refreshTeamRanking() {
        guard let configuration = teamSyncConfiguration, !isTeamRankingRefreshing, !isTeamSyncing else { return }
        isTeamRankingRefreshing = true
        let service = TeamUsageSyncService(configuration: configuration)
        Task { [weak self] in
            do {
                let ranking = try await Task.detached(priority: .utility) {
                    let ranking = try await service.fetchRanking(range: "today")
                    await PersistentAvatarCachePrefetcher.prefetch(
                        ranking: ranking,
                        websiteURL: service.websiteURL
                    )
                    return ranking
                }.value
                self?.isTeamRankingRefreshing = false
                self?.statusBar.applyTeamRanking(ranking, websiteURL: service.websiteURL)
            } catch {
                self?.isTeamRankingRefreshing = false
                AppDelegate.appendTeamSyncLog("ranking refresh failed: \(error)")
            }
        }
    }

    @objc private func quotaTimerFired() {
        refreshQuotaFromAppServer()
    }

    private func refreshQuotaFromAppServer() {
        guard quotaRefreshCoordinator.beginRefresh() else { return }
        let stateURL = store.stateURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let backgroundStore = StateStore(stateURL: stateURL)
            var lastError: Error?
            let now = Date()
            let localObservation = CodexSessionQuotaCollector().collect(
                codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
                now: now
            )
            let localIsFresh = localObservation.map { now.timeIntervalSince($0.observedAt) <= 15 * 60 } ?? false
            let existing = backgroundStore.read().providerQuota(for: ProviderQuotaSnapshot.codexProviderID)
            let localIsNewer = localObservation.map { existing == nil || $0.observedAt > existing!.updatedAt } ?? false

            if let localObservation, localIsNewer {
                _ = try? backgroundStore.updateProviderQuota(
                    providerID: ProviderQuotaSnapshot.codexProviderID,
                    fiveHourPercent: localObservation.fiveHourRemainingPercent,
                    weeklyPercent: localObservation.weeklyRemainingPercent,
                    fiveHourResetsAt: localObservation.fiveHourResetsAt,
                    weeklyResetsAt: localObservation.weeklyResetsAt,
                    source: CodexSessionQuotaCollector.source,
                    now: localObservation.observedAt
                )
            } else if localIsFresh {
                // The local event already matches the stored quota; avoid a
                // slower duplicate app-server query.
            } else {
                do {
                    let transport = ProcessCodexAppServerTransport(initializeTimeout: 50, rateLimitsTimeout: 20)
                    let collector = CodexAppServerQuotaCollector(
                        transport: transport,
                        retryPolicy: CodexAppServerRetryPolicy(retries: 0)
                    )
                    _ = try collector.fetchAndUpdate(store: backgroundStore)
                } catch {
                    lastError = error
                }
            }

            let snapshot = backgroundStore.read()
            DispatchQueue.main.async {
                self?.handleQuotaRefreshCompletion(snapshot: snapshot, error: lastError)
            }
        }
    }

    private func handleQuotaRefreshCompletion(snapshot: StateSnapshot, error: Error?) {
        quotaRefreshCoordinator.endRefresh(success: error == nil)
        let previousQuotaUpdatedAt = TeamQuotaReport.from(snapshot: currentSnapshot)?.updatedAt
        currentSnapshot = snapshot
        statusBar.apply(snapshot: currentSnapshot)
        if error == nil,
           TeamQuotaReport.from(snapshot: snapshot)?.updatedAt != previousQuotaUpdatedAt {
            syncTeamData()
        }
        if let error, let line = quotaRefreshCoordinator.failureLogLine(error: error) {
            AppDelegate.appendQuotaLog(line)
        }
    }

    private nonisolated static func appendQuotaLog(_ line: String) {
        let url = StateStore.defaultSupportDirectory().appendingPathComponent("quota-mxp.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let data = "\(timestamp) \(line)\n".data(using: .utf8)!
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private nonisolated static func appendTeamSyncLog(_ line: String) {
        let url = StateStore.defaultSupportDirectory().appendingPathComponent("team-sync.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let data = "\(timestamp) \(line)\n".data(using: .utf8)!
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }

    func statusBarDidRequestQuit() {
        statusBar.stopAnimation()
        quotaTimer?.invalidate()
        teamSyncTimer?.invalidate()
        teamRankingTimer?.invalidate()
        NSApp.terminate(nil)
    }
}
