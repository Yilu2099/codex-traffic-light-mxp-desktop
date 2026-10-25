# Token 采集准确性调研与本地迭代（2026-10-26）

本次范围是本机 Codex 增量采集的准确性。保持官方日结、成员账号归属、Dot 单独采集和已有服务端契约；没有修改线上历史排行、安装客户端或发布更新。

## 一手证据与版本

| 来源 | 查询时最新正式版 | 审阅源码 |
| --- | --- | --- |
| OpenAI Codex | [0.164.0，2026-10-23](https://github.com/openai/codex/releases/tag/rust-v0.164.0) | `970111f6cb62cc02fe36a82ea7d71b37a2889c97` main；稳定版 `6aaac694803004a63c6f393d153c96d22521a6b9` |
| ccusage | [20.0.44，2026-10-24](https://github.com/ccusage/ccusage/releases/tag/v20.0.44) | `b40f51149d117e7c01b5f92466bae44e39c66a10` |
| CodexBar | [0.81.0，2026-10-24](https://github.com/steipete/CodexBar/releases/tag/v0.81.0) | `d34fbb47afe73f81dd591bae28a60f72c39a9fe4` |
| tokscale | [4.20.1，2026-10-23](https://github.com/junhoyeo/tokscale/releases/tag/v4.20.1) | `82e24b92a0eb9bba98955a1106dcc9f03464ac0c` |

版本日期按发布来源记录；main 的内容不等于每个用户已安装的版本。本机内置 CLI 实测为 `0.164.0-alpha.11.1`。项目迭代基线是客户端 `origin/main` 的 `7b72623`（VERSION `1.2.151`），网站 `3ded767`。

## 确认的变化和采用决策

### 1. 逐响应凭据可证明未完成请求的消费

OpenAI [10 月 13 日 #53670](https://github.com/openai/codex/commit/816fa702ec66a4c81b204701a03371a1ac3511e6) 将带合法 usage 的 `response.incomplete` 写入逐响应账本，并增加消费累计，但保留上下文的 `last_token_usage`。因此累计差分不等于 last，不一定是异常。

[官方实现](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/core/src/session/mod.rs#L5119) 先写 receipt，再更新 SpendingOnly；[回声可能等待工具或用户输入后才发送](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/core/src/session/turn.rs#L3430)。不能靠几秒时间差关联。

本次新增一个有界、可持久化的认证状态：只有 canonical 线程、明确当前 turn、单个有效 response、逐分量累计差分都一致，且与主计数器候选增量一致时，才允许 last 不匹配的增量通过。普通路径仍保留结构、上下文上限、时间与速率校验。凭据不单独加量；`thread_token_usage` 不替换旧累计值。重复、多凭据、缺失字段、跨任务边界均维持保守隔离。每 turn 的 response 去重集合有上限，超限停止额外认证，不删除普通累计用量。

### 2. Fork / 子任务需要自身归属边界

旧逻辑只按新文件时间向前容忍 5 秒，合成回归已复现：父 100，紧接着 fork 复制 100 再新增 50，旧结果 250，正确结果 150。

[官方 SessionMeta](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/protocol/src/protocol.rs#L3273) 定义 `subagent_history_start_ordinal` 为子任务自身历史的起点。第一条 `session_meta.id` 才是物理文件身份，嵌入祖先 metadata 不能替换它。`session_id` 表示 root，会与当前 thread 不同。

本次采用有界首行读取：明确 ordinal 前缀只建立基线，不计新消费；旧式显式 fork 若保留历史时间，则以 metadata 的毫秒创建时间排除继承事件。无需父文件，也不扫描父历史。压缩请求凭据若带另一线程 ID，不能用于补记本线程消费。

借鉴 [CodexBar 的请求归属检查](https://github.com/steipete/CodexBar/blob/d34fbb47afe73f81dd591bae28a60f72c39a9fe4/Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift#L4233) 和 [子任务结构判定](https://github.com/steipete/CodexBar/blob/d34fbb47afe73f81dd591bae28a60f72c39a9fe4/Sources/CodexBarCore/Vendored/CostUsage/CodexSubagentRolloutShape.swift#L9)，重新实现局部规则，没有引入第三方运行时或整套统计器。

不采用“Token 相同”“时间相同”“短时间密集写入”即重复的全局启发式。合法兄弟任务可以有相同数值，须分别计入。

### 3. 压缩请求要关联身份，不能两套累计相加

[ccusage #1821](https://github.com/ccusage/ccusage/commit/8f32f3c3351f615f0bac1bce6e11a780ab905b94) 与 [tokscale #1439](https://github.com/junhoyeo/tokscale/commit/df130defc3bfdac7f00f63644d7b93dbe94345e9) 针对压缩请求补漏和回声去重。

我们基线已经支持 pending 压缩请求跨轮询、累计不变时补记、请求去重和特定旧版漏计恢复。本次补充线程归属检查及显式 `compaction_response_id` 冲突拒绝。保留原时间窗口，没有把任意 EOF 或没有回声的请求直接转为消费。

### 4. Token 各项是包含关系

[官方解析测试](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/codex-api/src/sse/responses.rs#L869) 与 [tokscale Codex 转换](https://github.com/junhoyeo/tokscale/blob/82e24b92a0eb9bba98955a1106dcc9f03464ac0c/crates/tokscale-core/src/sessions/codex.rs#L272) 一致：缓存属于输入，reasoning 属于输出；总数是 input + output，细分项不能再加一次。

现有总量口径保持。本次数值读取拒绝 Bool、小数、非有限数、负数、超出 JSON 安全整数范围的数值；旧格式整数字符串保留兼容。新增 receipt 的认证更严格，不用缺失项猜 0（明确可选字段除外）。

### 5. 冷日志压缩适合独立历史审计

[ccusage #1890](https://github.com/ccusage/ccusage/commit/44a3aa84e84cbc1afa40dab3f2849e03e9a9b054) 与 [tokscale #1423](https://github.com/junhoyeo/tokscale/commit/bd62b8c4e07269e5314fac06c6d23262dc714633) 支持 `.jsonl.zst`，防止历史重建遗漏。

[官方压缩实现](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/rollout/src/compression.rs#L371) 针对 mtime 超过 7 天的冷文件，活跃 writer 有锁，恢复追加前会 materialize 成 `.jsonl`。本机确实已存在压缩文件，但它们不证明本日实时增量遗漏。

本次不把全量解压加入实时心跳；未来独立历史审计必须支持压缩流或明确标记覆盖缺口，并按逻辑线程去重 plain/compressed 两份。

## 验证方式

- 更新前全套测试暴露一项环境前置问题：只构建 tests product 时，隔离 helper 测试找不到相邻 CLI。完整构建所有 products 后再执行全套验证。
- 用独立 fixture 验证 sub-second fork、重新写入时间的 ordinal 前缀、父文件缺失、跨轮询持久化、嵌入祖先 metadata、相同数值的独立兄弟任务。
- 验证 malformed 数值、foreign compaction receipt、错误 response ID、正常匹配、普通累计回声去重。
- 验证 receipt 逐分量差分、延迟回声、缺失/错误身份、多候选、重复请求、任务边界、状态序列化和状态上限。
- 本机只读抽样 25 个最近日志，每个尾部最多 8 MiB；仅检查数值与身份元数据。共 1,042 条 receipt、1,057 条 legacy 用量事件，抽样 receipt 身份均匹配本文件，没有发现“正向累计差分不等于 last”的实例。此抽样不代表全账户或所有历史完整性。
- 最终 `swift build -c release` 全产品构建成功；8 项新增定向测试全部通过；完整测试共 169 项全部通过；`git diff --check` 通过。测试使用隔离临时状态，不修改实际用户计数器。
- 验收日志保存在 `/tmp/wanhe-token-accuracy-final-build-20261026.log`、`/tmp/wanhe-token-accuracy-targeted-20261026.log`、`/tmp/wanhe-token-accuracy-full-20261026.log`。本机抽样脚本和汇总在项目根目录 `audits/token-accuracy-20261026/`。
- 服务端契约核对使用网站 `origin/main`：上报结构、协议版本及审计 reason 未增加字段或枚举；新增 receipt 状态只保存在客户端本地状态文件中，已有状态文件缺失该可选字段时仍可读取。

## 明确保留的局限

- legacy fork 重新持久化时可能重写历史时间戳。没有 ordinal 或明确请求归属时，时间边界不能证明整个前缀；本次不宣称穷尽所有旧格式 fork。
- metadata 首行分块读取、最多 4 MiB；首行过大、不完整或身份不匹配时，不启用新的身份认证与精确继承边界，保留原有保守路径。
- 累计计数独立重置、多个未配对请求等不确定情形仍隔离。不能为了让数字变大而放宽成“累计倒退就加 last”。
- 压缩补计仍有原有时间窗口；取消窗口需同时处理延迟跨日归属及旧恢复凭据语义。
- 本地 receipt 是 best-effort observed usage，不是官方全账户账单。官方 [App Server 文档](https://learn.chatgpt.com/docs/app-server) 没有保证所有 Dot/云端用量完整落入本机 JSONL；额度百分比也不能换算成原始 Token。
- 10/21 的 [reasoning 上下文修复 #55991](https://github.com/openai/codex/commit/07cc649c658be7018b6913299f12f843b24679f8) 影响上下文占用与压缩，不是从消费总量扣除 reasoning 的依据。

本次更新限定本地源码及测试。正式发布仍需新版本、签名包、现有两台验证设备的真实采集回读，以及发布锁与回滚流程。

## Windows 与官方接口专项复核

复核日期：2026-10-26。Windows 源码基线为网站 `origin/main` 的 `3ded767804d984bb65d1107576aac6f9ce1c2f5b`，入口 `scripts/windows-codex-client.mjs`。本节只读审计并运行合成日志，不修改 Windows 业务代码、线上数据或成员设备。

### 已确认的本项目差距

- Windows 使用独立 Node 实现，以上 Swift 改动不会自动覆盖 Windows。
- 已支持原生 `CODEX_HOME`、手工多根、WSL 发行版发现、sessions 与 archived_sessions、按 session 去重及字节偏移；不是完全缺少 Windows 支持。
- `createUploadPayload` 当前明确上传 `officialUsage: null` 和 `quota: null`。Mac 的 `OfficialCodexUsageCollector` 已通过 app-server 使用 `account/usage/read`，Windows 尚未接入。
- 合成回归实测：父 100 + child 继承 100 + 新增 50，Windows 现行结果 250，期望 150；压缩请求 40 + 旧累计不变 100，现行结果 100，期望 140。这是测试夹具复现，不是宣称成员真实账单已经出现同等偏差。
- 按 session 选较新文件后，token offset 复用只比较大小与修改时间，未验证所选文件的内容身份；原生、WSL、同步副本切换需要增加文件身份/已消费前缀验证，不能把每个路径当成独立消费。
- WSL 当前发现固定 `$HOME/.codex`；自定义 WSL `CODEX_HOME`、后加发行版及失败路径的覆盖状态需要独立检查。读取失败不应显示为完整且零用量。

### 哪些开源实践值得采用

| 项目 | 可采用的实践 | 边界 |
| --- | --- | --- |
| tokscale | 原生 Windows x64/ARM64 构建及测试、原生绝对 HOME 检查、增量前缀验证 | 未找到自动覆盖所有 WSL 发行版的实现 |
| ccusage | 多根目录、sessions/archived_sessions、plain/zst 逻辑归一避免重复 | 历史扫描不能直接变成高频实时采集 |
| CodexBar | 请求身份、分叉继承、完整行提交偏移 | 主仓 Windows 指向独立社区移植，不能当作主仓原生 Windows 验收 |

证据：[tokscale Windows 构建](https://github.com/junhoyeo/tokscale/blob/82e24b92a0eb9bba98955a1106dcc9f03464ac0c/.github/workflows/build-native.yml#L103)、[路径规则](https://github.com/junhoyeo/tokscale/blob/82e24b92a0eb9bba98955a1106dcc9f03464ac0c/crates/tokscale-core/src/paths.rs#L17)、[缓存验证](https://github.com/junhoyeo/tokscale/blob/82e24b92a0eb9bba98955a1106dcc9f03464ac0c/crates/tokscale-core/src/message_cache.rs#L4638)、[ccusage 多根](https://github.com/ccusage/ccusage/blob/b40f51149d117e7c01b5f92466bae44e39c66a10/rust/adapters/codex/src/paths.rs#L236)、[CodexBar Windows 边界](https://github.com/steipete/CodexBar/blob/d34fbb47afe73f81dd591bae28a60f72c39a9fe4/README.md#L301)。

### 官方接口的职责

| 来源 | 可提供 | 不可推断 |
| --- | --- | --- |
| `account/usage/read` | 账号 token 摘要与可选每日 buckets | 当前文档未声明日界时区、完整覆盖水位、revision 或 finalized；不能把我们的日结策略当作官方不可修订承诺 |
| `account/rateLimits/read` | 额度窗口、使用百分比及重置 | 不能换算为原始 token |
| `thread/tokenUsage/updated` | 活跃线程用量通知 | 不是全账户历史订阅；不能假定另启 app-server 就能收到桌面所有线程 |
| 本机 JSONL / receipt | 已落盘的请求、累计值与可追溯实时明细 | 不保证全部 Dot、云端或其他设备的消费 |

来源：[App Server 文档](https://learn.chatgpt.com/docs/app-server)。Windows 可以通过本机 `codex.exe app-server` 的 stdio JSON-RPC 调用；须检测实际二进制支持的方法，完成 initialize/initialized，使用匹配 CODEX_HOME 的已登录身份，设置超时并失败降级。app-server 本身仍有实验性/生产支持限制，不能去掉本地 fallback。

`account/usage/read` 的字段可以为 null，不能转为零或覆盖最近有效快照。服务日期原串、抓取时间、账号来源应保留；同一账号多设备取得的官方快照按账号对账，不能按设备求和。今日本地增量与官方同日 bucket 同样不能直接相加。

当前 main 还支持该方法的可选 `threadId` 分支，返回线程估计用量而非账号日桶；查询账号历史时不传此参数，线程能力则按实际安装版本单独探测。[协议](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/app-server-protocol/src/protocol/v2/account.rs)、[处理实现](https://github.com/openai/codex/blob/970111f6cb62cc02fe36a82ea7d71b37a2889c97/codex-rs/app-server/src/request_processors/account_processor.rs)。完整后端 profile 的 `stats_as_of` 和 `stats_error` 未通过账号日桶响应暴露，因此本地 `updatedAt` 只能表示抓取时间。

[官方 Windows 文档](https://learn.chatgpt.com/docs/windows/windows-app) 明确原生默认 `%USERPROFILE%\.codex`，WSL 默认 Linux home，默认不共享配置、身份或会话。对每个根目录明确其来源和身份，不为了采集而替用户改登录或同步 auth。

CodexBar 与 tokscale 也直接请求 `/backend-api/wham/usage`，但其用途主要是额度。第三方调用官方服务不意味着该内部 HTTP 路径是公开稳定的 token 总账 API。优先复用有文档的 app-server 方法，不复制 OAuth 刷新/写 auth 的副作用。

### 推荐落地顺序

1. 先把 Mac/Windows 的计数口径用同一组合成 JSONL 夹具锁定，补 Windows 分叉归属、压缩消费、严格数值及 receipt 认证。无需为了共享逻辑立刻重写 Swift 或引入整套 Rust 运行时。
2. 增加 Windows 官方只读适配层：账号用量与额度独立采集、独立缓存、独立超时；确保接口失败不阻塞 token 与在线上报。先能力探测再启用。
3. 完善原生/WSL 多根发现、文件替换验证和覆盖状态。WSL 探测低频、有超时，避免高频唤醒全部发行版。
4. 压缩历史放独立低频核验；重复副本按逻辑身份去重。服务端保留差异来源，以官方账号快照对账，而非盲目加总。
5. 验收覆盖 Windows 原生、WSL2、自定义 HOME、中文/空格路径、共享副本、半行、截断/替换、重启、账号切换和接口不可用；通过真实测试设备持续增量与更新回读后，再扩大范围。本轮未做 Windows 真机验收。

补充：Windows 已有 `Number.isSafeInteger`，数值规则应补类型回归而非机械重写。`pendingFiles` 与输入历史覆盖不能代替 token 来源覆盖，须明确未读完、未扫描、读取失败和未知格式。修正历史只能基于原始证据，不能单靠提升计数版本强行覆盖旧账。

结论：最适合本项目的是“官方账号数据对账 + 本机实时增量 + 独立额度 + 明确覆盖状态”，保留现有轻量客户端，吸收有证据的规则与测试，不替换成任何一个第三方统计器的整套架构。
