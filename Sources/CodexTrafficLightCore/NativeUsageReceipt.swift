import Foundation
import CoreFoundation

/// A receipt only authenticates a later cumulative delta; it never adds usage itself.
public struct NativeUsageReceipt: Codable, Sendable {
    private struct Vector: Codable, Sendable, Equatable {
        // Input, cached input, output, reasoning output, total, cache write; cache/reasoning are subsets.
        let values: [Int]
        var isValid: Bool {
            values.count == 6 && values.allSatisfy { (0...9_007_199_254_740_991).contains($0) }
                && values[0] + values[2] == values[4]
                && values[1] <= values[0] && values[3] <= values[2] && values[5] <= values[0]
        }
        init?(_ raw: [String: Any]?) {
            guard let raw else { return nil }
            let fields = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens", "cache_write_input_tokens"]
            var values: [Int] = []
            for field in fields {
                let value: Any? = raw[field] ?? (field == "cache_write_input_tokens" ? NSNumber(value: 0) : nil)
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue >= 0,
                      number.doubleValue <= 9_007_199_254_740_991,
                      number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
                values.append(number.intValue)
            }
            self.values = values
            guard isValid else { return nil }
        }
    }
    private var turnID: String?
    private var activeTurn = false
    private var previous: Vector?
    private var pending: Vector?
    private var pendingResponseID: String?
    private var seenResponseIDs: Set<String> = []
    private var ambiguous = false
    private var identityLimitReached = false

    public init() {}

    public func matchesDelta(current raw: [String: Any]?, usage: [String: Int]?) -> Bool {
        guard let usage, let expected = Vector(usage.mapValues { $0 as Any }),
              let previous, previous.isValid, let current = Vector(raw) else { return false }
        return zip(zip(current.values, previous.values), expected.values).allSatisfy {
            $0.0.0 >= $0.0.1 && $0.0.0 - $0.0.1 == $0.1
        }
    }

    /// Call only for task_started. A repeated start is also a boundary, never a receipt replay.
    public mutating func startTurn(_ id: String?) {
        let next = id.flatMap { $0.isEmpty ? nil : $0 }
        if next != turnID { seenResponseIDs = []; identityLimitReached = false }
        turnID = next
        activeTurn = next != nil
        clearCandidate()
    }

    /// Compaction or task completion/abort closes certification until a new task_started.
    public mutating func invalidate() {
        activeTurn = false
        clearCandidate()
    }

    public mutating func observe(_ payload: [String: Any], canonicalThreadID: String) {
        guard activeTurn, let turnID, !canonicalThreadID.isEmpty,
              payload["turn_id"] as? String == turnID,
              payload["thread_id"] as? String == canonicalThreadID,
              let responseID = payload["response_id"] as? String, !responseID.isEmpty,
              let usage = Vector(payload["usage"] as? [String: Any]), usage.values[4] > 0 else {
            ambiguous = true
            return
        }
        // Bound persisted state. Once full, leave the rest of this turn to normal pending rules.
        guard !identityLimitReached, !seenResponseIDs.contains(responseID) else {
            ambiguous = true
            return
        }
        guard seenResponseIDs.count < 256 else {
            identityLimitReached = true
            ambiguous = true
            return
        }
        seenResponseIDs.insert(responseID)
        guard pending == nil else { ambiguous = true; return }
        pending = usage
        pendingResponseID = responseID
    }

    /// Call for every token_count, including those with no valid cumulative counters.
    /// The baseline and single-use receipt survive polling/restarts through Codable.
    public mutating func consume(current raw: [String: Any]?, expectedDelta: Int? = nil) -> Bool {
        let current = Vector(raw)
        defer { previous = current; clearCandidate() }
        guard activeTurn, turnID != nil, !ambiguous, !identityLimitReached,
              pendingResponseID != nil, let pending, pending.isValid,
              let previous, previous.isValid, let current,
              expectedDelta == nil || expectedDelta == pending.values[4] else { return false }
        return zip(zip(current.values, previous.values), pending.values).allSatisfy {
            $0.0.0 >= $0.0.1 && $0.0.0 - $0.0.1 == $0.1
        }
    }

    private mutating func clearCandidate() {
        pending = nil
        pendingResponseID = nil
        ambiguous = false
    }
}
