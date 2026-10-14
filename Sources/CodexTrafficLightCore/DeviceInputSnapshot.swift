import Foundation
import IOKit
import CoreGraphics

/// Coarse local diagnostic only. No key contents, mouse path, screenshots or productivity claim.
public struct DeviceInputSnapshot: Codable, Equatable, Sendable {
    public var observedAt: String
    public var inputIdleSeconds: Int?
    public var sessionOnConsole: Bool?
    public var sessionLoggedIn: Bool?
    public var state: String
    public var interpretation = "device_signal_only_not_human_message_or_work_quality"

    public init(idleSeconds: Double?, onConsole: Bool?, loggedIn: Bool?, now: Date = Date()) {
        observedAt = ISO8601DateFormatter().string(from: now)
        inputIdleSeconds = idleSeconds.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? Int($0) : nil }
        sessionOnConsole = onConsole; sessionLoggedIn = loggedIn
        if onConsole == false || loggedIn == false { state = "session_inactive" }
        else if let seconds = inputIdleSeconds { state = seconds < 300 ? "recent_input" : "input_idle" }
        else { state = "unknown" }
    }

    public static func read(now: Date = Date()) -> DeviceInputSnapshot {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        var idle: Double?
        if service != 0 {
            defer { IOObjectRelease(service) }
            if let property = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                idle = property.doubleValue / 1_000_000_000
            }
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return DeviceInputSnapshot(idleSeconds: idle,
            onConsole: session?[kCGSessionOnConsoleKey as String] as? Bool,
            loggedIn: session?[kCGSessionLoginDoneKey as String] as? Bool, now: now)
    }
}
