import Foundation

public enum QuotaCreditPresentation {
    public static func text(local: QuotaSnapshot?, synced: TeamQuotaReport?, now: Date = Date()) -> String? {
        if let remaining = synced?.weeklyRemainingPercent, remaining > 0 { return nil }
        let server = synced.flatMap { report -> QuotaSnapshot? in
            guard let updatedAt = SharedDateFormatters.shared.iso8601Date(from: report.creditUpdatedAt ?? report.updatedAt) else { return nil }
            return QuotaSnapshot(weeklyRemainingPercent: report.weeklyRemainingPercent,
                weeklyResetsAt: report.weeklyResetsAtDate, creditBalance: report.creditBalance,
                source: report.source ?? "team-ranking", limitID: report.limitID, updatedAt: updatedAt)
        }
        let candidates = [local, server].compactMap { $0 }.filter { quota in
            guard quota.freshCreditBalance(now: now) != nil else { return false }
            guard let synced else { return true }
            guard let reset = quota.weeklyResetsAt, let syncedReset = synced.weeklyResetsAtDate else { return false }
            return abs(reset.timeIntervalSince(syncedReset)) < 1
        }
        return candidates.max(by: { left, right in
            left.updatedAt == right.updatedAt
                ? (left.creditBalance ?? 0) > (right.creditBalance ?? 0)
                : left.updatedAt < right.updatedAt
        })?.remainingCreditText(now: now)
    }
}
