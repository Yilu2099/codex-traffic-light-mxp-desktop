import Foundation
import CodexTrafficLightCore

func testToolMembershipUsesAllowlistedOfficialFields() throws {
    let now = ISO8601DateFormatter().date(from: "2026-11-18T10:30:00Z")!
    let claude = Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"MAX","email":"private@example.invalid","orgId":"private-org"}"#.utf8)
    let claudeReport = ToolMembershipSource.claudeAccount(claude, now: now)
    try expectEqual(claudeReport?.plan, "max", "known subscription plan")
    try expect(claudeReport?.windows == nil, "statusline windows do not identify the account")
    let api = Data(#"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","subscriptionType":"max"}"#.utf8)
    try expect(ToolMembershipSource.claudeAccount(api, now: now) == nil, "API keys do not prove a subscription")

    let profile = Data(#"{"code":0,"data":{"kind":"ok","userInfo":{"userLevelName":"Pro","userId":42,"email":"private@example.invalid"}}}"#.utf8)
    let usage = Data(#"{"code":0,"data":{"kind":"ok","quota":{"usages":{"limit5h":{"usedRatio":0},"limit7d":{"usedRatio":true},"monthTotal":{"usedRatio":0.42,"resetAt":"2026-11-22T10:30:00.125Z"},"monthCode":{"usedRatio":1.3}},"extraUsage":{"balanceCents":500}}}}"#.utf8)
    let report = ToolMembershipSource.kimi(usage: usage, profile: profile, now: now)
    try expectEqual(report?.plan, "pro", "returned plan name")
    try expectEqual(report?.windows?.map(\.key), ["five_hour", "month_total"], "accept only present, valid quota windows")
    try expectEqual(report?.windows?.map(\.usedPercent), [0, 42], "ratios become percentages without counting Tokens")
    let uploaded = String(decoding: try JSONEncoder().encode(["claude": claudeReport, "kimi": report]), as: UTF8.self)
    try expect(!uploaded.contains("@") && !uploaded.contains("balance") && !uploaded.contains("private"), "source account data stays on-device")

    let failed = Data(#"{"code":0,"data":{"kind":"error","message":"member unavailable"}}"#.utf8)
    let unknown = Data(#"{"code":0,"data":{"kind":"ok","userInfo":{"userLevelName":"private@example.invalid"}}}"#.utf8)
    try expect(ToolMembershipSource.kimi(usage: failed, profile: unknown, now: now) == nil, "unknown values never become a plan or a zero window")
}
