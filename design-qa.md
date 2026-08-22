# 日搓夜搓状态栏设计验收

## Source visual truth

- 选定方案：`/Users/lu/.codex/generated_images/01a02722-77db-79d0-af46-8e9267c19584/exec-9b1e95f5-5680-4625-8d62-82cad4c535cd.png`
- 概念稿尺寸：987 × 1593 px。
- 设计重点：克制的单绿色语义色、弱化卡片层级、周余额下方统一呈现日搓与夜搓。

## Rendered implementation

- 实际 SwiftUI 截图：`/Users/lu/.codex/generated_images/01a02722-77db-79d0-af46-8e9267c19584/grind-status-popover-v1.2.6-local-final.png`
- 对照图：`/Users/lu/.codex/generated_images/01a02722-77db-79d0-af46-8e9267c19584/grind-status-design-comparison.png`
- 实现尺寸：912 × 1280 px，对应 456 × 640 pt、2× 密度的真实状态栏弹窗。
- 状态：浅色外观；张璐、乔月、陈佳欣三种成员状态；含周余额、Token、日搓和夜搓。
- 归一化：对照图将概念稿与真实弹窗等高排列。概念稿不是固定 456 × 640 pt 的像素规范，因此真实实现按可用弹窗高度压缩密度，不将合理尺寸差异视为缺陷。

## Full-view and focused evidence

- 完整视图保留周余额总览、成员排序、头像、Token 列和最近动态。
- 日搓/夜搓已移到每位成员周余额下方，形成稳定的三行信息层级。
- 张璐真实数据为日搓 09:42、夜搓 02:04；乔月为日搓 07:42、夜搓 03:12。
- 状态栏仅使用绿色强调与中性灰，取消多色竞争；字号和行距适合 456 pt 宽度。

## Findings and comparison history

- 初版问题：颜色较多、日搓夜搓位置分散、长文案影响行间节奏。
- 修正：统一语义色；将时间胶囊置于周余额下；最近动态缩为 `12次 · 活跃 10:36`；Token 使用紧凑中文单位。
- 数据修正：日搓只认 05:00–10:59 首次本机开启对话；夜搓只认 23:00–04:59 人类发起或互动事件，后台完成不计入。
- 未发现 P0、P1、P2 视觉问题。

## Verification

- [x] 真实 456 × 640 pt SwiftUI 渲染截图。
- [x] 68 项 Mac 客户端测试全部通过。
- [x] `git diff --check` 通过。
- [x] 版本号 1.2.7。

final result: passed
