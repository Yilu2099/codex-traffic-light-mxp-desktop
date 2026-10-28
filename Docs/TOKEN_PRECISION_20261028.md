# Token 精度与 UTC 诊断日账 · 2026-10-28

本文为客户端工程摘要；实现、发布、安装与真实成员验收分别记录。文末未填写的项目不代表已经完成。
已有 10/26 修复见 [TOKEN_ACCURACY_20261026.md](TOKEN_ACCURACY_20261026.md)；本次不重复宣称为新修复。

## 现场结论

张海强 2026-10-27 的设备旧日账重建始终为 **56,464,292**。
10/28 08:53（北京时间）捕获官方桶 **24,881,123**，暂差 **+126.94%**；13:32 捕获官方回补至 **57,310,429**，暂差变为 **-1.48%**。
这证明“次日观察即最终结算”不成立，不能凭早间差额认定设备重复计数，也不能把下午暂差当最终误差。
本次不按官方差额补本机累计，不把账户用量按比例摊给设备。

## 原始 receipt 已计核验

只读普通 JSONL，以 canonical thread + response ID 去重，排除可识别继承、foreign 与外部导入；与现有 native 审计按事件时间对照。

| UTC 窗口 | 文件数 | 独立 receipt 数 | receipt 总量 | 已计审计总量 | 差额 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 10/27—10/28 | 44 | 505 | 91,821,476 | 91,821,476 | 0 |
| 10/21—10/28 | 86 | 4,648 | 780,112,238 | 780,112,238 | 0 |

这是已有采集在本机样本中的精确对照，不是此次升级才补出的量；不支持再加一遍全部 receipt。
周窗口累计差分对照为 774,555,719，pending 诊断为 19,754,678；两者都不能直接当新增漏计补回。
范围不包含全部 Dot、云端、其他设备或 `.jsonl.zst` 冷日志，也不证明所有源文件均存在。

## 官方语义边界

官方源码固定为 `727283cea5ba30e8cf8bbac6b68a03a4d91cf1b7`，与本机所装 `0.164.0-alpha.11.1` 区分。
[账户响应](https://github.com/openai/codex/blob/727283cea5ba30e8cf8bbac6b68a03a4d91cf1b7/codex-rs/app-server-protocol/src/protocol/v2/account.rs#L466-L485) 无 finalized、revision、watermark 或 timezone；UTC 是本项目对账约定，不是已证实的官方承诺。
[token_count/receipt 定义](https://github.com/openai/codex/blob/727283cea5ba30e8cf8bbac6b68a03a4d91cf1b7/codex-rs/protocol/src/protocol.rs#L2492-L2568) 区分单请求 usage 与累计；缓存包含于 input，reasoning 包含于 output，不能额外相加。
累计可能重发、重算或回退；不能每条加 last，也不能遇 reset 就重新计全部历史。
[回声发送路径](https://github.com/openai/codex/blob/727283cea5ba30e8cf8bbac6b68a03a4d91cf1b7/codex-rs/core/src/session/turn.rs#L3454-L3469) 可等待工具完成；receipt 与累计回声可能跨日，几秒相邻不是通用身份依据。

## 新增诊断协议与覆盖

`TodayLiveUsageReport.utcDailyUsage` 最多携带含当天在内的 14 个 UTC 日；每项包含：

```json
{"day":"2026-10-27","tokens":102,"updatedAt":"2026-10-28T03:00:00Z","coverageFrom":"2026-10-27T00:00:00Z","throughAt":"2026-10-28T00:00:00Z"}
```

- `UTCDailyUsage.swift` 按现有被接受的用量事件时间归日，不等同请求开始时间或官方计费归日；不由官方差额或会话目录日期生成。
- 首次启用只从启用时证明覆盖；迁移旧计数不认证之前小时。读取失败、截断、保留期断档不允许伪造连续覆盖。
- native 与本机 Dot 合并沿用来源排重；Dot 只有观察时间，该日有正数或相关 pending 就将 coverageFrom/throughAt 置 null，保留数值但不认证全天。
- 服务器验证日期、整数与时间关系，合并诊断历史；字段缺失兼容旧客户端，无效覆盖保持未知。
- 诊断日账不授予排行榜历史校正权；大数、新版本或扫描完成本身都不是回填凭证。

相关代码：`Sources/CodexTrafficLightCore/{UTCDailyUsage,TodayCodexUsage,DotTokenUsage}.swift`。
对账要求 coverageFrom 不晚于 UTC 日初、throughAt 不早于日末；不足时仍显示记录量，但不进入严格可比汇总。
旧“当天 UTC 增量＋次日凌晨增量”保留为 `legacy_reconstruction`，不能证明整日覆盖。
仍注册设备持续列为应有来源，离线不当退役；只有已不在注册表的历史设备可结束活动跨度。跨度中双日缺失也列缺报。
账户当前指纹不能倒认旧日；有日期证据的账户区间、设备日账和官方桶身份必须匹配，多账号/缺身份只显示记录暂差。
昨日官方桶为 `provisional`；桶结束满 24 小时且官方此后再观察，覆盖也完整，才进入“延后复核”，仍不称最终结算。

## 开源借鉴与反例

| 固定版本 | 说明与实际代码 | 采用原则 / 限制 |
| --- | --- | --- |
| ccusage `b8ad727170fc0dabe35cbf7b940f0a3f9fba475b` | [文档](https://github.com/ccusage/ccusage/blob/b8ad727170fc0dabe35cbf7b940f0a3f9fba475b/docs/guide/codex/index.md)、[压缩 reader](https://github.com/ccusage/ccusage/blob/b8ad727170fc0dabe35cbf7b940f0a3f9fba475b/rust/adapters/codex/src/reader.rs#L9) | plain/zst 逻辑去重和事件时间有价值；全局同值 key、时间 burst 不能作为强身份。 |
| CodexBar `5f93dc3068b3bee3f8753f3772614cc2949c335d` | [文档](https://github.com/steipete/CodexBar/blob/5f93dc3068b3bee3f8753f3772614cc2949c335d/docs/codex.md#L354)、[请求流水](https://github.com/steipete/CodexBar/blob/5f93dc3068b3bee3f8753f3772614cc2949c335d/Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift#L4231) | canonical thread + response ID 可识别 reset 后新请求；短时间镜像启发式不直接照搬。 |
| tokscale `39ecb83ab045a300c6f502f9c9319acf5c80e764` | [README](https://github.com/junhoyeo/tokscale/blob/39ecb83ab045a300c6f502f9c9319acf5c80e764/README.md)、[pending 实现](https://github.com/junhoyeo/tokscale/blob/39ecb83ab045a300c6f502f9c9319acf5c80e764/crates/tokscale-core/src/sessions/codex.rs#L1122) | 持久 pending、明确读取失败值得借鉴；同 usage 向量也可能来自不同合法请求。 |

已只读说明、实现与相关测试，没有安装或执行这些统计器；不复制大块第三方许可代码。
这些实现都不能从本地文件保证全账户/全云端精准，也不能证明 README 的每项描述均已在当前 adapter 实现。

## 尚未证实与验证要求

[官方后台压缩路径](https://github.com/openai/codex/blob/727283cea5ba30e8cf8bbac6b68a03a4d91cf1b7/codex-rs/core/src/compact_remote_v2.rs#L395-L451) 有不发布前台 receipt 的分支；这只说明可见性边界，未证明我们的差额来源。
本机保留日志中 1,326 条反馈为 `async_compaction=false`，未见 true；不能据官方 main 把本机差额归因于后台压缩。
桌面短期生成样本 10 条、1,534,250 token 无完整账户归属证据，不能加入正式排行或解释数亿差额。

10/27 三项大暂差的只读摘要（10/28 13:44 捕获），均无完整显式 UTC 覆盖：
- 仇博上报与末尾 checkpoint 均为零、无当天来源 task；只能确认零记录，不能证明真实零或归因升级/首次基线。
- 李国庆 14,088,687 与新端 native 审计相符；另端 349,645、注册版本 1.2.109 且无详细审计，整体覆盖未知，未证实公式丢掉已审计量。
- 黄宁 50,847,203 与 native 审计相符；有用量未知的 cloud_other 和仍注册的缺报设备，不能把官方余差全部归给云端或升级。

未来请求流水变更需真实缺口证据，并覆盖 reset、receipt/echo 顺序、跨日迟到、fork、冲突身份、compaction、压缩损坏与重启迁移。
本轮不重写 receipt/echo 配对计数；跨日 receipt 先写、echo 晚到仍需逐条原始证据对照，新 UTC 字段不自动等同官方计费归日。
纯扫描成功、测试通过、签名包发布、设备安装和真实完整日上报必须分别验收。

## 证据与交付状态

本机研究目录 `/tmp/wanhe-token-research-20261028/` 含 `oss-findings.md`、`official-token-semantics.md` 和两份 `local-receipt-audit*.json`；该目录不是持久仓库归档。
服务端仓库对应说明为 `docs/token-precision-20261028.md`；原始请求身份仅保存摘要，文档不包含正文或凭证。

| 交付项目 | 状态 / 待主线负责人填写 |
| --- | --- |
| 全量 Swift 测试与构建 | 186 项完整测试通过；最终缓存时刻修正后 10 项相关回归通过；全产品构建与 diff-check 通过 |
| 发布版本、签名包、服务器 manifest | 目标 1.2.160；以发布时签名/哈希回读为准 |
| 实际设备版本、LaunchAgent、上报验证 | 先验证两台 Mac，再扩围；实际回执见独立验收文件 |
| 首个完整 UTC 日与延后官方复核 | 本轮尚无新协议完整日；旧历史不能追认为完整 |

实际发布与设备回读保存为本机 `创新局/audits/token-precision-20261028/release-receipt.json`；计划、签名包已发布和设备已安装分别记录。
