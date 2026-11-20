# 2026-11-20 · 状态栏余额入口

- 分支 `codex/status-balance-20261120`，开发基线 `origin/main` 的 `3b1808a`。
- 面板每次打开时优先显示排行榜。「查看余额」展开原有的 Codex 和 Claude 额度卡，「收起余额」恢复榜单空间。已核对网站主线保留历史排行入口与页面。
- 左上角文案为「用 AI 手搓世界，人人都是造物主」。
- Release 构建、201 项 Swift 测试和 `git diff --check` 通过。使用示例数据核对 456 × 640 的原生 SwiftUI 排行榜、余额展开及无 Claude 配置的截图。
- 界面已确认。发布版本为 `1.2.185`，仅授权定向更新张璐的 MacBook 与 Studio。发布和设备回执以本页后续验证记录为准。

---

# Design QA — Mac 状态栏与网页版使用说明版本同步 v1.2.53

- source visual truth: installed status popover card layout
- visual baseline: `/Users/lu/Desktop/开发/创新局/状态栏开工文案-client-v1.2.52-20260823/artifacts/status-popover-v1.2.52.png`
- client UI: no visible layout or copy change; this release keeps the Mac client version aligned with the website guide release
- viewport: native SwiftUI popover at 456 × 640 points, Aqua light appearance, 2x capture
- implementation pixels: 912 × 1280
- state: current local team data, four joined members visible

## Findings

- No actionable P0, P1, or P2 mismatch remains.
- Missing start values are formatted as `待开工` with no redundant prefix.
- Known start values are formatted as `开工 HH:mm`; the capture visibly shows `开工 09:33`, `开工 10:16`, `开工 09:59`, and `开工 10:05`.
- The existing diagonal amber/blue work band, quota geometry, avatar layout, Token alignment, and interactions are unchanged.
- The formatter test covers nil, empty, and known-time states.
- All 66 executable tests and the release build passed.

final result: passed
