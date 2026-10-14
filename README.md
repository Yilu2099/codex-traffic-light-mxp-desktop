# 万合创新局 Codex 状态栏

当前内部版本：`v1.2.106`。版本号在 `VERSION` 与 `Sources/CodexTrafficLightCore/ClientUpdate.swift` 两处维护，发布前必须保持一致；状态栏面板会在排行榜列表下方居中显示当前版本和网页版使用说明入口。

这是万合创新局的 macOS 状态栏客户端，只保留当前在用的四条链路：

- Codex 周额度：读取明确标记为 `10080` 分钟的周窗口；忽略其他窗口。
- 团队同步：同步今日 Token、活跃时间、周额度、设备信息与项目审计结果；经成员知情授权，增量上传成员本人输入的文字和真实时间戳，排除 Codex 回复、代码、附件、系统上下文及子智能体内容。
- 状态栏面板：显示个人周余额、刷新时间和团队排行榜；可切换实时、本周、本月 Token 用量，并可打开网站详情。
- 签名自动更新：开机立即检查，此后每 5 分钟检查；发现新版本会校验 SHA-256 与 Ed25519 签名并自动安装，支持灰度、强制更新和失败回滚。

客户端不会显示桌面悬浮红绿灯，不采集 5 小时额度，也不采集 Claude 额度。

## 安装

```bash
./install-team.command --server https://c.wanhe.cn --invite wanhe-xxxxxxxxxxxx
```

完成后确认 macOS 状态栏已经显示 Codex 周余额，并能在菜单里看到今日团队全部成员和“打开团队排行榜网站”。不要再询问我的昵称，服务端已经通过邀请码预设好了。

安装程序会注册当前设备、停用旧采集器、安装状态栏客户端、项目审计监控和独立自动更新助手。安装完成后，状态栏显示个人周余额；点击可查看今日团队成员并打开排行榜。

## 构建与测试

```bash
./build.command
swift run codex-light-mxp-tests
```

整月官方数据的只读诊断（重新查询，不读写用量缓存或上传数据）：

```bash
.build/release/codex-light-mxp official-usage --month 2026-09 --json
```

自动尝试已安装的官方 Codex 程序；可用 `CODEX_TRAFFIC_LIGHT_CODEX_BIN` 指定单一程序复核。JSON 保留官方日记录，`completeAccountResponse` 仅表示账户日记录与累计总量一致，不代表换账号前后的成员月度记录已补齐。

主要产物：

```text
.build/release/CodexTrafficLightApp
.build/release/codex-light-mxp
.build/release/codex-light-hook-mxp
.build/release/wanhe-status-updater
```

保留 `codex-light-*` 文件名是为了兼容已经安装的 LaunchAgent、软链接和更新包路径；它们不再包含红绿灯界面逻辑。

## 命令行

```bash
codex-light-mxp status --json
codex-light-mxp quota --app-server --json
codex-light-mxp quota --weekly 28 --json
printf '%s' '{"weekly_remaining_percent":28}' | codex-light-mxp quota --stdin --json
codex-light-mxp audit --task <task-id> --workspace <path>
```

- `status`：读取本机周额度快照。
- `quota`：从 Codex app-server、标准输入或明确参数更新周额度。
- `audit`：只记录脱敏后的项目简称、哈希会话标识、次数与时间。

## 数据边界

本机状态文件：

```text
~/Library/Application Support/CodexTrafficLight/state.json
```

新版本只写入周额度快照：

```json
{
  "updated_at": 1787382000,
  "quota": {
    "weekly_remaining_percent": 28,
    "weekly_resets_at": 1787561781,
    "source": "codex-session-rate-limits",
    "updated_at": 1787382000
  }
}
```

输入事件使用哈希后的会话标识和可靠待发送队列；成功接收后才从队列移除。凭据样式内容会隐藏，Codex 回复、代码、附件、系统上下文、子智能体内容和原始任务 ID 不会上传。周额度本地采集只读取 Codex 会话事件中的 `token_count.rate_limits` 元数据。

## 发布更新

1. 同步修改 `VERSION` 和 `ClientVersion.current`。
2. 运行全量测试与 release 构建。
3. 使用本机私钥签名并先灰度发布：

```bash
WANHE_UPDATE_ROLLOUT=10 ./publish-update.command
```

4. 核对 GitHub、服务端更新清单、真实状态栏、网站和后台设备版本后，再调整到 100%。

## 真人消息时间只读试验

以下命令只在当前电脑读取本人已登录账号及本机会话元数据，不发送消息、不刷新登录、不上传、不改开工收工记录，也不安装或更新状态栏。Dot 只访问当前账号选定的主 Dot，依次核对账号、房间和本人/Dot 成员身份。凭据只在内存使用；输出不包含账号、房间、原始消息 ID、正文或附件。

```sh
swift run codex-light-mxp dot-input-audit --json
swift run codex-light-mxp native-input-audit --json
swift run codex-light-mxp device-input-audit --json
swift run codex-light-mxp human-input-shadow --json
```

- Dot 取本人原始消息的 `created_at`，保留原始精度；Dot 输出、更新、重复、未来时间及明确自动触发不延后消息时间。最多读取 3 页/60 条，`windowLimited` 为真时不能把样本首条宣称为全天开工。
- 本地诊断最多读取 16 个近期会话的有限头部和尾部。明确自动触发单独分类；来源缺失保留未知，子代理排除。`composer` 仅证明输入框来源，不能证明物理真人；自动轮次后续追加消息也不继承自动来源。
- 影子结果使用 `Asia/Hong_Kong` 和 05:00 工作日边界。只合并本人 Dot 消息和明确用户提交；`firstObservedMessageAt` 仅为已观察样本首条，覆盖不足始终标注，不覆盖正式开工记录。
- 设备诊断只读系统键鼠空闲时长及会话状态。它不能证明工作质量或人在操作 Codex，也不作为真人消息的替代或否决条件；不记录按键内容、鼠标轨迹或屏幕。

正式采集用于持有有效设备凭证的已注册成员，服务端据设备凭证绑定身份，后台每分钟通过同目录的 `codex-light-mxp` 辅助进程只读采样，最多 5 页；持久缓存保存散列事件、时间及恢复游标，权限 0600。账号变化、过期或日期变化时不复用旧缓存。`dot-input-sample --json` 可手动执行一轮断点补收；`human-input-preview --json` 输出本机正式上传结构而不上传。

团队协议使用独立 `humanInputMetadata`。Dot 最新原始 owner 发言可随不完整窗口更新，开工只接受已补齐工作日的证据。Native `interaction_v8` 仅将明确用户提交计入真人统计；未知历史独立分类，明确自动、系统上下文、子代理排除。完整重放及范围保存在待确认队列，服务器持久化确认后才清除；不完整窗口不能清空旧历史。失败不能回退为 Token、心跳或轮次启动时间。

已认证 owner 和输入框来源仍无法识别所有脚本模拟发送；没有来源标记的消息不得声称已证明物理真人。设备信号不参与首末时间，当前不向服务器上传。签名更新先在两台本人设备验证安装、运行及同步，再按发布清单扩大范围；旧客户端未确认来源的历史不冒认真人。
