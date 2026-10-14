import Foundation

public struct HumanWorkdayShadow: Encodable, Sendable {
    public var mode = "read_only_shadow_no_upload"
    public var timeZone = "Asia/Hong_Kong"
    public var workday: String
    public var firstObservedMessageAt: String?
    public var lastMessageAt: String?
    public var lastMessageLocalTime: String?
    public var sources: [String]
    public var coverageIncomplete: Bool
    public var unknownNativeSources: Int
    public var automaticInputsExcluded: Int
    public var dotOutputsExcluded: Int
    public var device: DeviceInputSnapshot

    public init(dot: DotInputReport, native: NativeInputAuditReport, device: DeviceInputSnapshot, now: Date = Date()) {
        self.device = device
        let zone = TimeZone(identifier: "Asia/Hong_Kong")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let startOfDay = calendar.startOfDay(for: now)
        let currentStart = calendar.date(byAdding: .hour, value: 5, to: startOfDay)!
        let start = now < currentStart ? calendar.date(byAdding: .day, value: -1, to: currentStart)! : currentStart
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let dayFormat = DateFormatter(); dayFormat.timeZone = zone; dayFormat.calendar = calendar; dayFormat.locale = Locale(identifier: "en_US_POSIX"); dayFormat.dateFormat = "yyyy-MM-dd"
        workday = dayFormat.string(from: start)
        let candidates = dot.ownerMessages + native.inputs.filter { $0.classification == "user_submission" }
        let eligible = candidates.compactMap { event -> (HumanInputEvent, Date)? in
            guard let date = DotInputCollector.parse(event.sourceAt), date >= start, date < end, date <= now else { return nil }
            return (event, date)
        }.sorted { $0.1 < $1.1 }
        firstObservedMessageAt = eligible.first?.0.sourceAt
        lastMessageAt = eligible.last?.0.sourceAt
        if let date = eligible.last?.1 {
            let format = DateFormatter(); format.timeZone = zone; format.calendar = calendar; format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd HH:mm:ss"
            lastMessageLocalTime = format.string(from: date)
        }
        sources = Array(Set(eligible.map { $0.0.source })).sorted()
        coverageIncomplete = dot.windowLimited || native.coverageIncomplete || native.sourceUnknown > 0
        unknownNativeSources = native.sourceUnknown
        automaticInputsExcluded = dot.excludedAutomaticMessages + native.automaticInputsExcluded
        dotOutputsExcluded = dot.excludedDotMessages
    }
}
