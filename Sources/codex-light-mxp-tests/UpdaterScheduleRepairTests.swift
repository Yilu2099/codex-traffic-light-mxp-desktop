import Darwin
import Foundation
import CodexTrafficLightCore

func testUpdaterRepairTimerCreatedOnMainActorRunsInBackground() throws {
    let fired = DispatchSemaphore(value: 0)
    let timer = MainActor.assumeIsolated {
        UpdaterScheduleRepair.makeTimer(initialDelay: 0.01) { @Sendable in
            dispatchPrecondition(condition: .notOnQueue(.main))
            fired.signal()
        }
    }
    defer { timer.cancel() }
    try expectEqual(fired.wait(timeout: .now() + 3), .success, "a MainActor-created timer must execute its Sendable background callback without an actor assertion")
}

private final class UpdaterRepairFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("updater-repair-\(UUID().uuidString)")
    var app: URL { home.appendingPathComponent(".wanhe-codex-token/app") }
    var release: URL { app.appendingPathComponent("releases/\(ClientVersion.current)") }
    var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(UpdaterLaunchAgentInstaller.label).plist") }
    var registered = false, disabled = false, running = false, failBootstrap = false, failInspection = false, failBootout = false
    var bootstrapSawUnlocked = false
    var calls: [[String]] = []
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: release, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: app.appendingPathComponent("current").path, withDestinationPath: "releases/\(ClientVersion.current)")
        try ClientVersion.current.write(to: release.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        for name in ["CodexTrafficLightApp", "wanhe-status-updater"] {
            let file = release.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let source: [String: Any] = ["Label": UpdaterLaunchAgentInstaller.label, "ProgramArguments": ["__UPDATER_PATH__"],
            "StartInterval": 300, "RunAtLoad": true, "ProcessType": "Background"]
        try PropertyListSerialization.data(fromPropertyList: source, format: .xml, options: 0)
            .write(to: release.appendingPathComponent("\(UpdaterLaunchAgentInstaller.label).plist.template"))
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func runner(_ args: [String]) -> MainAppLaunchctlResult {
        calls.append(args)
        switch args[0] {
        case "print":
            if failInspection { return .init(status: 5, output: "permission denied") }
            return registered ? .init(status: 0, output: running ? "state = running\n pid = 123" : "state = not running") : .init(status: 113, output: "Could not find service")
        case "print-disabled": return .init(status: 0, output: "\"\(UpdaterLaunchAgentInstaller.label)\" => \(disabled)")
        case "enable": disabled = false; return .init(status: 0)
        case "bootout":
            if failBootout { return .init(status: 5, output: "permission denied") }
            registered = false; return .init(status: 0)
        case "bootstrap":
            let lock = try? UpdaterProcessLock(url: app.appendingPathComponent("update-process.lock"))
            bootstrapSawUnlocked = lock != nil
            withExtendedLifetime(lock) {}
            registered = !failBootstrap; return .init(status: failBootstrap ? 5 : 0)
        default: return .init(status: 99)
        }
    }
    func check() -> UpdaterScheduleRepair.Result {
        UpdaterScheduleRepair.check(runningExecutable: release.appendingPathComponent("CodexTrafficLightApp"), home: home, runLaunchctl: runner)
    }
    var mutations: [String] { calls.map { $0[0] }.filter { !["print", "print-disabled"].contains($0) } }
}

func testUpdaterRepairMissingAndUnloadedAndHealthy() throws {
    let f = try UpdaterRepairFixture()
    try expectEqual(f.check(), .repaired, "missing plist and registration must be rebuilt from installed template")
    try expectEqual(f.mutations, ["bootstrap"], "an absent job needs no bootout or kickstart")
    try expect(f.bootstrapSawUnlocked, "RunAtLoad can immediately acquire the released update lock")
    try expect(FileManager.default.fileExists(atPath: f.plist.path), "official template must be installed")
    f.calls = []; f.registered = false
    try expectEqual(f.check(), .repaired, "a correct plist does not prove its service is loaded")
    try expectEqual(f.mutations, ["bootstrap"], "an unloaded correct job is bootstrapped")
    f.calls = []
    try expectEqual(f.check(), .healthy, "a healthy job remains untouched")
    try expect(f.mutations.isEmpty, "health checks must not restart healthy services")
    let health = try String(contentsOf: f.home.appendingPathComponent(".wanhe-codex-token/updater-health.json"), encoding: .utf8)
    try expect(health.contains("healthy") && health.contains("checkedAt") && !health.contains(f.home.path), "health evidence contains only status and time")
}

func testUpdaterRepairWrongPathAndDisabledAndBusy() throws {
    let f = try UpdaterRepairFixture()
    _ = f.check(); f.calls = []
    var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: f.plist), format: nil) as! [String: Any]
    plist["ProgramArguments"] = ["/wrong/updater"]
    let bad = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try bad.write(to: f.plist)
    f.running = true
    try expectEqual(f.check(), .deferred, "a running updater is never interrupted")
    try expect(f.mutations.isEmpty, "deferred checks make no launchd mutations")
    try expectEqual(try Data(contentsOf: f.plist), bad, "running updater defers even plist replacement")
    f.running = false; f.failBootout = true; f.calls = []
    try expectEqual(f.check(), .bootoutFailed, "failed retirement remains a repair failure")
    try expectEqual(try Data(contentsOf: f.plist), bad, "failed retirement cannot hide stale registration behind a repaired plist")
    f.failBootout = false; f.disabled = true; f.calls = []
    try expectEqual(f.check(), .repaired, "wrong executable and disabled own service are repaired")
    try expectEqual(f.mutations, ["bootout", "enable", "bootstrap"], "only this app's idle registration changes")
    try bad.write(to: f.plist); f.calls = []
    let lock = try UpdaterProcessLock(url: f.app.appendingPathComponent("update-process.lock"))
    try expect(lock != nil, "fixture owns updater lock")
    try expectEqual(f.check(), .deferred, "an update transaction prevents repair")
    try expect(f.mutations.isEmpty, "update lock prevents service changes")
    withExtendedLifetime(lock) {}
}

func testUpdaterRepairFailsClosedWithoutPackageOrLaunchdProof() throws {
    let f = try UpdaterRepairFixture()
    f.failBootstrap = true
    try expectEqual(f.check(), .bootstrapFailed, "failed registration is not reported as repaired")
    f.calls = []; f.failInspection = true
    try expectEqual(f.check(), .inspectionFailed, "unknown service state is not treated as absence")
    try expect(f.mutations.isEmpty, "failed inspection does not remove a service")
    try FileManager.default.removeItem(at: f.release.appendingPathComponent("wanhe-status-updater"))
    f.calls = []
    try expectEqual(f.check(), .missingBinary, "missing updater requires explicit repair, never a clone")
    try expect(f.calls.isEmpty, "missing binary performs no launchctl calls")
    try expectEqual(UpdaterScheduleRepair.check(runningExecutable: URL(fileURLWithPath: "/tmp/development-app"), home: f.home, runLaunchctl: f.runner), .notInstalled, "development builds cannot repair production services")
}
