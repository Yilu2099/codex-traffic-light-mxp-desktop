import Cocoa
import CodexTrafficLightCore
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusBarControllerDelegate {
    private let store = StateStore()
    private lazy var statusBar = StatusBarController()
    private var currentSnapshot: StateSnapshot = .empty()
    private var quotaTimer: Timer?
    private var teamSyncTimer: Timer?
    private var teamRankingTimer: Timer?
    private var presenceTimer: Timer?
    private var teamSyncWatchdogTimer: Timer?
    private var externalAlertTimer: Timer?
    private var teamSyncConfiguration: TeamSyncConfiguration?
    private var isTeamSyncing = false
    private var teamSyncStartedAt: Date?
    private var isTeamRankingRefreshing = false
    private var isPresenceSyncing = false
    private var isExternalAlertRefreshing = false
    private var presenceFailureLogged = false
    private var latestQuotaDiagnostic: TeamQuotaDiagnostic?
    private let quotaRefreshCoordinator = QuotaRefreshCoordinator()
    private let externalAlertStore = ExternalAlertStore()
    private var selectedRankingRange: StatusRankingRange = .today
    private var rankingRequestSequence = 0
    private var rankingCache: [StatusRankingRange: TeamRankingSnapshot] = [:]
    private var isRankingCacheWarming = false
    private var bureauStatusBar: BureauStatusBarController?
    private var bureauTimer: Timer?
    private var isBureauRefreshing = false

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
        statusBar.onPopoverOpen = { [weak self] in self?.refreshInspirationUnread() }
        currentSnapshot = store.read()
        statusBar.apply(snapshot: currentSnapshot)
        configureExternalAlerts()
        DispatchQueue.global(qos: .utility).async {
            let result = ClientReleaseRetention.prune()
            if !result.removed.isEmpty {
                AppDelegate.appendTeamSyncLog("release cleanup removed \(result.removed.count) old paths")
            }
            for name in result.failures {
                AppDelegate.appendTeamSyncLog("release cleanup failed: \(name)")
            }
        }

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
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) {
            AppDelegate.ensureUpdaterSchedule()
        }
    }

    private func configureExternalAlerts() {
        checkExternalAlert()
        externalAlertTimer = Timer.scheduledTimer(
            timeInterval: 15,
            target: self,
            selector: #selector(externalAlertTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func externalAlertTimerFired() {
        checkExternalAlert()
    }

    private func checkExternalAlert() {
        if let configuration = teamSyncConfiguration {
            guard !isExternalAlertRefreshing else { return }
            isExternalAlertRefreshing = true
            Task { [weak self] in
                let alert = try? await TeamUsageSyncService(configuration: configuration).fetchExternalAlert()
                self?.isExternalAlertRefreshing = false
                if let alert { self?.deliverExternalAlert(alert) }
            }
            return
        }
        if let alert = externalAlertStore.nextUnread() { deliverExternalAlert(alert) }
    }

    private func deliverExternalAlert(_ alert: ExternalAlert) {
        guard externalAlertStore.isUnread(alert) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "on run argv\ndisplay notification item 2 of argv with title item 1 of argv sound name \"Glass\"\nend run",
            alert.title,
            alert.body,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [externalAlertStore] completed in
            guard completed.terminationStatus == 0 else {
                AppDelegate.appendTeamSyncLog("external alert delivery failed: exit=\(completed.terminationStatus)")
                return
            }
            do {
                try externalAlertStore.markDelivered(alert)
            } catch {
                AppDelegate.appendTeamSyncLog("external alert acknowledgement failed: \(error)")
            }
        }
        do {
            try process.run()
        } catch {
            AppDelegate.appendTeamSyncLog("external alert delivery failed: \(error)")
        }
    }

    private func configureTeamIntegration() {
        guard let configuration = TeamSyncConfiguration.load() else {
            statusBar.applyTeamRanking(nil, websiteURL: nil, syncDetail: "团队排行榜尚未注册")
            return
        }
        teamSyncConfiguration = configuration
        let websiteURL = TeamUsageSyncService(configuration: configuration).websiteURL
        statusBar.applyTeamRanking(nil, websiteURL: websiteURL, syncDetail: "正在读取团队数据…")
        refreshTeamRanking()
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
        Timer.scheduledTimer(
            timeInterval: 3,
            target: self,
            selector: #selector(presenceTimerFired),
            userInfo: nil,
            repeats: false
        )
        presenceTimer = Timer.scheduledTimer(
            timeInterval: Defaults.presenceRefreshSeconds,
            target: self,
            selector: #selector(presenceTimerFired),
            userInfo: nil,
            repeats: true
        )
        teamSyncWatchdogTimer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(teamSyncWatchdogTimerFired),
            userInfo: nil,
            repeats: true
        )
        configureBureauIntegration(configuration: configuration)
    }

    // 创新局是三个人的子系统，只在这三台机器上多挂一个菜单栏入口。
    private func configureBureauIntegration(configuration: TeamSyncConfiguration) {
        guard InnovationBureau.isMember(configuration.userID) else { return }
        let controller = BureauStatusBarController(currentUserID: configuration.userID)
        let service = TeamUsageSyncService(configuration: configuration)
        controller.apply(
            snapshot: nil,
            websiteURL: service.websiteURL,
            bureauPageURL: service.bureauPageURL,
            syncDetail: "正在读取创新局项目…"
        )
        controller.onPopoverOpen = { [weak self] in self?.refreshBureau() }
        bureauStatusBar = controller
        refreshBureau()
        bureauTimer = Timer.scheduledTimer(
            timeInterval: Defaults.bureauRefreshSeconds,
            target: self,
            selector: #selector(bureauTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func bureauTimerFired() {
        refreshBureau()
    }

    private func refreshBureau() {
        guard let configuration = teamSyncConfiguration, bureauStatusBar != nil, !isBureauRefreshing else { return }
        isBureauRefreshing = true
        let service = TeamUsageSyncService(configuration: configuration)
        Task { [weak self] in
            do {
                let snapshot = try await service.fetchBureau()
                self?.isBureauRefreshing = false
                self?.bureauStatusBar?.apply(
                    snapshot: snapshot,
                    websiteURL: service.websiteURL,
                    bureauPageURL: service.bureauPageURL,
                    syncDetail: "刚刚同步"
                )
            } catch {
                self?.isBureauRefreshing = false
                self?.bureauStatusBar?.setSyncDetail("创新局项目读取失败，稍后重试")
                AppDelegate.appendTeamSyncLog("bureau refresh failed: \(error)")
            }
        }
    }

    @objc private func teamSyncTimerFired() {
        syncTeamData()
    }

    @objc private func teamRankingTimerFired() {
        refreshTeamRanking()
    }

    @objc private func presenceTimerFired() {
        syncPresence()
    }

    @objc private func teamSyncWatchdogTimerFired() {
        guard let startedAt = teamSyncStartedAt,
              Date().timeIntervalSince(startedAt) >= 150 else { return }
        AppDelegate.appendTeamSyncLog("sync watchdog: team sync exceeded 150 seconds; restarting app")
        Darwin.exit(75)
    }

    private func syncPresence() {
        guard let configuration = teamSyncConfiguration, !isPresenceSyncing else { return }
        isPresenceSyncing = true
        let markerURL = TeamUsageSyncService.presenceMarkerURL()
        let lastActiveAt = (try? markerURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let taskMarkerURL = TeamUsageSyncService.taskActivityMarkerURL()
        let taskActiveAt = (try? taskMarkerURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let service = TeamUsageSyncService(configuration: configuration)
        Task { [weak self] in
            do {
                _ = try await service.syncPresence(lastActiveAt: lastActiveAt, taskActiveAt: taskActiveAt)
                self?.isPresenceSyncing = false
                self?.presenceFailureLogged = false
            } catch {
                self?.isPresenceSyncing = false
                if self?.presenceFailureLogged == false {
                    AppDelegate.appendTeamSyncLog("presence sync failed: \(error)")
                    self?.presenceFailureLogged = true
                }
            }
        }
    }

    private func refreshInspirationUnread() {
        guard let configuration = teamSyncConfiguration else { return }
        let service = TeamUsageSyncService(configuration: configuration)
        Task { [weak self] in
            if let count = try? await service.fetchInspirationUnreadCount() {
                self?.statusBar.setInspirationUnreadCount(count)
            }
        }
    }

    private func syncTeamData() {
        refreshInspirationUnread()
        guard let configuration = teamSyncConfiguration, !isTeamSyncing else { return }
        isTeamSyncing = true
        teamSyncStartedAt = Date()
        let quota = TeamQuotaReport.from(snapshot: store.read())
        let quotaDiagnostic = latestQuotaDiagnostic
        let service = TeamUsageSyncService(configuration: configuration)
        let requestedRange = selectedRankingRange
        statusBar.setTeamSyncDetail("正在同步本机数据…", websiteURL: service.websiteURL)
        Task { [weak self] in
            do {
                let ranking = try await Task.detached(priority: .utility) {
                    _ = try await service.sync(quota: quota, quotaDiagnostic: quotaDiagnostic)
                    return try await service.fetchRanking(range: requestedRange.rawValue)
                }.value
                self?.isTeamSyncing = false
                self?.teamSyncStartedAt = nil
                self?.rankingCache[requestedRange] = ranking
                self?.prefetchAvatars(for: ranking, websiteURL: service.websiteURL)
                guard self?.selectedRankingRange == requestedRange else { return }
                self?.applyRanking(ranking, configuration: configuration, service: service, syncDetail: "刚刚同步")
                self?.warmRankingCacheIfNeeded(service: service, configuration: configuration)
            } catch {
                self?.isTeamSyncing = false
                self?.teamSyncStartedAt = nil
                self?.statusBar.setTeamSyncDetail("团队数据同步失败，稍后重试", websiteURL: service.websiteURL)
                AppDelegate.appendTeamSyncLog("sync failed: \(error)")
            }
        }
    }

    private func refreshTeamRanking(range: StatusRankingRange? = nil, force: Bool = false) {
        refreshInspirationUnread()
        guard let configuration = teamSyncConfiguration else { return }
        if !force && (isTeamRankingRefreshing || isTeamSyncing) { return }
        let requestedRange = range ?? selectedRankingRange
        selectedRankingRange = requestedRange
        if let cached = rankingCache[requestedRange] {
            applyRanking(cached, configuration: configuration, service: TeamUsageSyncService(configuration: configuration))
        }
        rankingRequestSequence += 1
        let requestSequence = rankingRequestSequence
        isTeamRankingRefreshing = true
        let service = TeamUsageSyncService(configuration: configuration)
        Task { [weak self] in
            do {
                let ranking = try await Task.detached(priority: .utility) {
                    try await service.fetchRanking(range: requestedRange.rawValue)
                }.value
                guard let self else { return }
                self.rankingCache[requestedRange] = ranking
                self.prefetchAvatars(for: ranking, websiteURL: service.websiteURL)
                guard self.rankingRequestSequence == requestSequence,
                      self.selectedRankingRange == requestedRange else { return }
                self.isTeamRankingRefreshing = false
                self.applyRanking(ranking, configuration: configuration, service: service)
                self.warmRankingCacheIfNeeded(service: service, configuration: configuration)
            } catch {
                guard let self else { return }
                guard self.rankingRequestSequence == requestSequence else { return }
                self.isTeamRankingRefreshing = false
                self.statusBar.setRankingRangeLoading(false)
                AppDelegate.appendTeamSyncLog("ranking refresh failed: \(error)")
            }
        }
    }

    private func applyRanking(
        _ ranking: TeamRankingSnapshot,
        configuration: TeamSyncConfiguration,
        service: TeamUsageSyncService,
        syncDetail: String? = nil
    ) {
        statusBar.applyTeamRanking(
            ranking,
            websiteURL: service.websiteURL,
            syncDetail: syncDetail,
            currentUserID: configuration.userID,
            highlights: cachedHighlights()
        )
    }

    private func cachedHighlights() -> [String: MemberHighlight] {
        guard let today = rankingCache[.today],
              let week = rankingCache[.week],
              let month = rankingCache[.month] else { return [:] }
        return MemberHighlights.calculate(
            today: today,
            week: week,
            month: month,
            workday: MemberHighlights.workday()
        )
    }

    private func warmRankingCacheIfNeeded(
        service: TeamUsageSyncService,
        configuration: TeamSyncConfiguration
    ) {
        let missing = StatusRankingRange.allCases.filter { rankingCache[$0] == nil }
        guard !missing.isEmpty, !isRankingCacheWarming else { return }
        isRankingCacheWarming = true
        Task { [weak self] in
            let loaded = await withTaskGroup(of: (StatusRankingRange, TeamRankingSnapshot?).self) { group in
                for range in missing {
                    group.addTask {
                        let ranking = try? await service.fetchRanking(range: range.rawValue)
                        return (range, ranking)
                    }
                }
                var result: [(StatusRankingRange, TeamRankingSnapshot)] = []
                for await (range, ranking) in group {
                    if let ranking { result.append((range, ranking)) }
                }
                return result
            }
            guard let self else { return }
            self.isRankingCacheWarming = false
            for (range, ranking) in loaded {
                self.rankingCache[range] = ranking
                self.prefetchAvatars(for: ranking, websiteURL: service.websiteURL)
            }
            guard let current = self.rankingCache[self.selectedRankingRange] else { return }
            self.applyRanking(current, configuration: configuration, service: service)
        }
    }

    private func prefetchAvatars(for ranking: TeamRankingSnapshot, websiteURL: URL) {
        Task.detached(priority: .utility) {
            await PersistentAvatarCachePrefetcher.prefetch(ranking: ranking, websiteURL: websiteURL)
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
            let localObservation = CodexSessionQuotaCollector(
                stateURL: CodexSessionQuotaCollector.defaultStateURL()
            ).collect(
                codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
                now: now
            )
            let localIsFresh = localObservation.map {
                CodexSessionQuotaCollector.isFresh($0, now: now)
            } ?? false
            let existing = backgroundStore.read().quota
            let shouldApplyLocal = localObservation.map {
                CodexSessionQuotaCollector.shouldApply($0, over: existing, now: now)
            } ?? false

            if let localObservation, shouldApplyLocal {
                _ = try? backgroundStore.updateQuota(
                    weeklyPercent: localObservation.weeklyRemainingPercent,
                    weeklyResetsAt: localObservation.weeklyResetsAt,
                    fiveHourPercent: localObservation.fiveHourRemainingPercent,
                    fiveHourResetsAt: localObservation.fiveHourResetsAt,
                    primaryWindow: localObservation.primaryWindow,
                    source: CodexSessionQuotaCollector.source,
                    limitID: CodexSessionQuotaCollector.primaryLimitID,
                    planType: existing?.planType,
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
        let verifiedQuota = TeamQuotaReport.from(snapshot: snapshot)
        let errorCode: String? = {
            if let quotaError = error as? CodexAppServerQuotaError { return quotaError.summaryKey }
            if error != nil { return "unknown" }
            if verifiedQuota == nil { return "no_verified_quota" }
            return nil
        }()
        let diagnosticStatus: String
        if verifiedQuota == nil {
            diagnosticStatus = "unavailable"
        } else if error != nil {
            diagnosticStatus = "stale"
        } else {
            diagnosticStatus = "available"
        }
        latestQuotaDiagnostic = TeamQuotaDiagnostic(
            status: diagnosticStatus,
            checkedAt: Date(),
            source: verifiedQuota?.source,
            errorCode: errorCode
        )
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
        BoundedLog.append("\(timestamp) \(line)\n", to: url)
    }

    private nonisolated static func appendTeamSyncLog(_ line: String) {
        let url = StateStore.defaultSupportDirectory().appendingPathComponent("team-sync.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        BoundedLog.append("\(timestamp) \(line)\n", to: url)
    }

    private nonisolated static func ensureUpdaterSchedule() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.codex.traffic-light-mxp-updater.plist")
        guard let data = try? Data(contentsOf: plistURL),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (plist["StartInterval"] as? NSNumber)?.intValue != 300 else { return }
        plist["StartInterval"] = 300
        do {
            let updated = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try updated.write(to: plistURL, options: .atomic)
            let domain = "gui/\(getuid())"
            _ = runLaunchctl(["bootout", domain, plistURL.path])
            let result = runLaunchctl(["bootstrap", domain, plistURL.path])
            if result != 0 {
                appendTeamSyncLog("updater schedule reload failed: exit=\(result)")
            }
        } catch {
            appendTeamSyncLog("updater schedule update failed: \(error)")
        }
    }

    private nonisolated static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    func statusBarDidSelectRankingRange(_ range: StatusRankingRange) {
        selectedRankingRange = range
        refreshTeamRanking(range: range, force: true)
    }

    func statusBarDidRequestQuit() {
        quotaTimer?.invalidate()
        teamSyncTimer?.invalidate()
        teamRankingTimer?.invalidate()
        presenceTimer?.invalidate()
        teamSyncWatchdogTimer?.invalidate()
        externalAlertTimer?.invalidate()
        bureauTimer?.invalidate()
        NSApp.terminate(nil)
    }
}
