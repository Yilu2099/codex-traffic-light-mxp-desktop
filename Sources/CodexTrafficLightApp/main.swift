import Cocoa
import CodexTrafficLightCore

let app = NSApplication.shared
if let capturePath = ProcessInfo.processInfo.environment["CODEX_LIGHT_CAPTURE_STATUS_POPOVER"] {
    app.setActivationPolicy(.prohibited)
    let succeeded = StatusPopoverCapture.writePreview(to: URL(fileURLWithPath: capturePath))
    exit(succeeded ? 0 : 1)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
