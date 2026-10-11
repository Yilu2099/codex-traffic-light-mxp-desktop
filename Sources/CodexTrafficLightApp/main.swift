import Cocoa
import CodexTrafficLightCore

let app = NSApplication.shared
if let inputPath = ProcessInfo.processInfo.environment["CODEX_LIGHT_PREVIEW_EXTERNAL_ALERT_JSON"] {
    app.setActivationPolicy(.accessory)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let alert = try decoder.decode(ExternalAlert.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
    let panel = ExternalAlertDialog.make(alert, target: app, confirmAction: #selector(NSApplication.terminate(_:)))
    panel.center()
    app.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    print("EXTERNAL_ALERT_PREVIEW_VISIBLE")
    fflush(stdout)
    app.run()
    exit(0)
}
if let capturePath = ProcessInfo.processInfo.environment["CODEX_LIGHT_CAPTURE_EXTERNAL_ALERT"],
   let inputPath = ProcessInfo.processInfo.environment["CODEX_LIGHT_CAPTURE_EXTERNAL_ALERT_JSON"] {
    app.setActivationPolicy(.accessory)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let alert = try decoder.decode(ExternalAlert.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
    exit(ExternalAlertDialog.writePreview(alert, to: URL(fileURLWithPath: capturePath)) ? 0 : 1)
}
if let capturePath = ProcessInfo.processInfo.environment["CODEX_LIGHT_CAPTURE_STATUS_POPOVER"] {
    app.setActivationPolicy(.prohibited)
    let succeeded = StatusPopoverCapture.writePreview(to: URL(fileURLWithPath: capturePath))
    exit(succeeded ? 0 : 1)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
