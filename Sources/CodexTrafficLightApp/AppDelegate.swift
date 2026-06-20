import Cocoa
import CodexTrafficLightCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, StatusBarControllerDelegate {
    private let store = StateStore()
    private let preferencesStore = PreferencesStore()
    private lazy var statusBar = StatusBarController()
    private lazy var floatingWindow = FloatingLightWindow()
    private lazy var soundController = SoundController(muted: preferences.muted)
    private var preferences = AppPreferences.defaults()
    private var currentState: LightState = .idle
    private var currentQuota: QuotaSnapshot?
    private var lastModified = Date.distantPast
    private var blinkTimer: Timer?
    private var waitingBlinkStopTimer: Timer?
    private var idleTimer: Timer?
    private var quotaTimer: Timer?
    private let quotaRefreshCoordinator = QuotaRefreshCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = preferencesStore.read()
        soundController = SoundController(muted: preferences.muted)
        statusBar.delegate = self

        let snapshot = store.read()
        currentQuota = snapshot.quota
        currentState = snapshot.aggregateState == .quit ? .idle : snapshot.aggregateState
        apply(state: currentState, playPrompt: false, source: .startup)
        floatingWindow.hide()

        Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(pollStateTimerFired), userInfo: nil, repeats: true)
        blinkTimer = Timer.scheduledTimer(timeInterval: 0.52, target: self, selector: #selector(blinkTimerFired), userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 1.5, target: self, selector: #selector(quotaTimerFired), userInfo: nil, repeats: false)
        quotaTimer = Timer.scheduledTimer(timeInterval: Defaults.appServerQuotaRefreshSeconds, target: self, selector: #selector(quotaTimerFired), userInfo: nil, repeats: true)
    }

    private enum StateSource {
        case startup
        case file
        case user
        case timer
    }

    @objc private func pollStateTimerFired() {
        pollState()
    }

    @objc private func quotaTimerFired() {
        refreshQuotaFromAppServer()
    }

    private func refreshQuotaFromAppServer() {
        guard quotaRefreshCoordinator.beginRefresh() else { return }
        let stateURL = store.stateURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let backgroundStore = StateStore(stateURL: stateURL)
            do {
                let transport = ProcessCodexAppServerTransport(initializeTimeout: 12, rateLimitsTimeout: 8)
                let collector = CodexAppServerQuotaCollector(
                    transport: transport,
                    retryPolicy: CodexAppServerRetryPolicy(retries: 0)
                )
                let snapshot = try collector.fetchAndUpdate(store: backgroundStore)
                DispatchQueue.main.async {
                    self?.handleQuotaSnapshot(snapshot)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.handleQuotaRefreshFailure(error)
                }
            }
        }
    }

    private func handleQuotaSnapshot(_ snapshot: StateSnapshot) {
        quotaRefreshCoordinator.endRefresh(success: true)
        currentQuota = snapshot.quota
        if snapshot.aggregateState != .quit {
            currentState = snapshot.aggregateState
        }
        updateStatusOnly()
    }

    private func handleQuotaRefreshFailure(_ error: Error) {
        if let line = quotaRefreshCoordinator.failureLogLine(error: error) {
            AppDelegate.appendQuotaLog(line)
        }
        quotaRefreshCoordinator.endRefresh(success: false)
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

    private func pollState() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: store.stateURL.path)
        let modified = attributes?[.modificationDate] as? Date ?? Date.distantPast
        guard modified != lastModified else { return }
        lastModified = modified

        let snapshot = store.read()
        let next = snapshot.aggregateState
        currentQuota = snapshot.quota
        if next == .quit {
            terminate()
            return
        }
        if next != currentState {
            apply(state: next, playPrompt: true, source: .file)
        } else {
            updateStatusOnly()
        }
    }

    private func apply(state: LightState, playPrompt: Bool, source: StateSource) {
        currentState = state
        statusBar.apply(state: state, muted: preferences.muted, quota: currentQuota)
        floatingWindow.hide()
        soundController.apply(state: state, playPrompt: playPrompt)

        if state == .waiting {
            startWaitingBlink()
        } else {
            stopWaitingBlink()
        }
        if state == .done {
            startIdleTimer()
        } else {
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    private func updateStatusOnly() {
        statusBar.apply(state: currentState, muted: preferences.muted, quota: currentQuota)
        floatingWindow.hide()
    }

    private func startWaitingBlink() {
        waitingBlinkStopTimer?.invalidate()
        waitingBlinkStopTimer = Timer.scheduledTimer(timeInterval: Defaults.waitingAlertSeconds, target: self, selector: #selector(waitingBlinkStopTimerFired), userInfo: nil, repeats: false)
    }

    private func stopWaitingBlink() {
        waitingBlinkStopTimer?.invalidate()
        waitingBlinkStopTimer = nil
    }

    @objc private func waitingBlinkStopTimerFired() {
    }

    @objc private func blinkTimerFired() {
        blink()
    }

    private func blink() {
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(timeInterval: Defaults.doneAutoIdleSeconds, target: self, selector: #selector(idleTimerFired), userInfo: nil, repeats: false)
    }

    @objc private func idleTimerFired() {
        guard currentState == .done else { return }
        let snapshot = try? store.clear()
        currentQuota = snapshot?.quota
        apply(state: .idle, playPrompt: false, source: .timer)
    }

    func statusBarDidRequestState(_ state: LightState) {
        let taskID = ContextResolver.taskID(explicitTaskID: "manual", workspace: FileManager.default.currentDirectoryPath)
        _ = try? store.updateTask(
            taskID: taskID,
            state: state,
            workspace: FileManager.default.currentDirectoryPath,
            source: "menu",
            hookEventName: nil,
            message: "Codex traffic light: \(state.rawValue)"
        )
        let snapshot = store.read()
        currentQuota = snapshot.quota
        apply(state: snapshot.aggregateState, playPrompt: true, source: .user)
    }

    func statusBarDidRequestClear() {
        let snapshot = try? store.clear()
        currentQuota = snapshot?.quota
        apply(state: .idle, playPrompt: false, source: .user)
    }

    func statusBarDidRequestToggleMute() {
        preferences.muted.toggle()
        preferences.updatedAt = Date()
        preferencesStore.write(preferences)
        soundController.setMuted(preferences.muted)
        updateStatusOnly()
    }

    func statusBarDidRequestQuit() {
        terminate()
    }

    private func terminate() {
        soundController.stopAll()
        quotaTimer?.invalidate()
        NSApp.terminate(nil)
    }
}
