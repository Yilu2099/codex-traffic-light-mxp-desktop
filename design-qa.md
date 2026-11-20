# 2026-11-20 · 加高状态栏顶部和余额入口

- 分支 `codex/balance-glow-continuous-20261120`，基线 `origin/main` 的 `3fcff7d`。发布客户端版本 `1.2.187`。
- 页头 66 点、品牌标志 38 点、「查看余额」按钮 36 点。浅绿描边以约 2 秒一圈的速度持续转动，展开余额时继续，关闭面板时停止。尊重系统的减少动态效果设置。
- 已确认原生面板预览。AppKit 验证了连续转动、余额展开、关闭和重新打开。Release 构建、201 项 Swift 回归测试和 `git diff --check` 通过。
- 正式更新包编译并核对 Apple 芯片及 Intel 两种架构。Intel 切片通过 Rosetta 的原生面板渲染与签名校验用例。正式更新开放给全部 Mac 客户端，非强制。Windows 走独立更新通道。
- 源码 `727d7da` 已推送 GitHub `main`。线上 Mac 清单为 100%、非强制、无设备白名单。公开安装包的哈希、Ed25519 签名及四个程序的双架构均已回读验证。
- 发布核查时，14 条可用 Mac 更新通道的注册记录中，11 台已安装并以新版完成采集上报，包括 MacBook 与 Studio。其余 3 条无近期上报。4 条 Windows 注册记录没有收到 Mac 包，Windows 线上清单仍为 `1.2.172`。
- 网站后台更新记录已推送网站仓库 `main` 的 `228a836`。186 项网站测试通过。网站服务未重新部署，线上排行榜 API 已读到 `1.2.187`。

---

# 2026-11-20 · 状态栏「查看余额」流光

- 分支 `codex/balance-glow-preview-20261120`，基线 `origin/main` 的 `ae21e1f`。客户端版本 `1.2.186`。
- 浅绿高光沿原生胶囊描边约 2 秒绕行一圈。系统开启减少动态效果时停用流光。
- 在 Mac Studio 打开实际 AppKit 弹出面板，并用进程内 AppKit 鼠标进入事件检查真实按钮的跟踪区域。开场结束后静止，进入触发一次，停留保持静止，移开后再次进入可重播。开场未结束时进入不重启。
- Release 构建、201 项 Swift 回归测试及 `git diff --check` 通过。
- 已发布源码 `7d5ffa4` 已推送 GitHub `main`。线上签名版本 `1.2.186` 沿用上一版的 MacBook、Mac Studio 两台设备范围，非强制。安装包 SHA-256 和 Ed25519 签名回读通过，其余 16 台已注册设备均不符合更新条件。
- Mac Studio 与 MacBook 均返回安装回执，并以 `1.2.186` 完成采集上报。Studio 已核对当前安装及两个 LaunchAgent。MacBook 的直接界面验收待核实。
- 网站后台更新记录已提交到网站仓库 `main` 的 `5984ef3`，186 项网站测试通过。网站服务未重新部署，线上排行榜 API 已读到客户端发布版本 `1.2.186`。

---

# 2026-11-20 · 状态栏余额入口

- 分支 `codex/status-balance-20261120`，开发基线 `origin/main` 的 `3b1808a`。
- 面板每次打开时优先显示排行榜。「查看余额」展开原有的 Codex 和 Claude 额度卡，「收起余额」恢复榜单空间。已核对网站主线保留历史排行入口与页面。
- 左上角文案为「用 AI 手搓世界，人人都是造物主」。
- Release 构建、201 项 Swift 测试和 `git diff --check` 通过。使用示例数据核对 456 × 640 的原生 SwiftUI 排行榜、余额展开及无 Claude 配置的截图。
- 界面已确认。发布源码 `12f2c2b` 已推送至 GitHub `main`，签名版本 `1.2.185` 仅向张璐的 MacBook 与 Studio 开放，未启用强制更新。
- 线上安装包的 SHA-256 与 Ed25519 签名核验通过。两台设备均返回安装回执，并以 `1.2.185` 完成采集上报。其余 16 台已注册设备不符合本次清单的更新条件，未发现新版本回执。
- 网站后台更新记录已提交到网站仓库 `main` 的 `4414d68`，网站服务未随本次客户端更新重新部署。设备实机界面未重新目测。

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
