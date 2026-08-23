# 万合创新局 Codex 状态栏

当前内部版本：`v1.2.63`。版本号在 `VERSION` 与 `Sources/CodexTrafficLightCore/ClientUpdate.swift` 两处维护，发布前必须保持一致；状态栏面板会在排行榜列表下方居中显示当前版本和网页版使用说明入口。

这是万合创新局的 macOS 状态栏客户端，只保留当前在用的四条链路：

- Codex 周额度：读取明确标记为 `10080` 分钟的周窗口；忽略其他窗口。
- 团队同步：同步今日 Token、活跃时间、周额度、设备信息与项目审计结果；回溯老/新对话中的真实用户轮次。项目审计仅上传本机清洗后的一句话工作简介和时间摘要，不上传原始对话、代码、完整路径或密钥样式内容。
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

项目审计不会上传完整目录、文件名、prompt、代码、聊天正文或原始任务 ID。周额度本地采集只读取 Codex 会话事件中的 `token_count.rate_limits` 元数据。

## 发布更新

1. 同步修改 `VERSION` 和 `ClientVersion.current`。
2. 运行全量测试与 release 构建。
3. 使用本机私钥签名并先灰度发布：

```bash
WANHE_UPDATE_ROLLOUT=10 ./publish-update.command
```

4. 核对 GitHub、服务端更新清单、真实状态栏、网站和后台设备版本后，再调整到 100%。
