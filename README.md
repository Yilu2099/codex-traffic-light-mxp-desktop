# Codex Traffic Light MXP

Codex Traffic Light MXP 是一个 macOS 菜单栏和悬浮交通灯工具，用颜色提示 Codex 当前状态：正在执行、等待你处理、已完成或空闲。

## 功能概览

- 菜单栏状态灯：常驻 macOS 菜单栏，方便快速查看状态。
- 悬浮交通灯：在桌面上显示更醒目的状态提示。
- Codex Hooks 集成：根据 Codex 的 hook 事件自动更新任务状态。
- 命令行控制：可手动设置状态、查询状态、清空状态或退出应用。
- 多任务聚合：多个 Codex 任务同时存在时，按优先级显示最需要关注的状态。
- 剩余额度展示：浮窗底部可显示 Codex 5 小时和 1 周剩余额度百分比。

## 状态说明

| 颜色 | 状态 | 含义 | 提示行为 |
| --- | --- | --- | --- |
| 黄灯 | `working` | Codex 正在工作 | 静默显示 |
| 绿灯 | `done` | 任务已完成，可以验收 | 播放 `Glass` 3 秒，10 分钟后自动回到空闲 |
| 红灯 | `waiting` | 需要你回复、确认、授权或补充文件 | 闪烁并播放 `Basso` 10 秒，随后保持红灯静默 |
| 暗灯 | `idle` | 没有活跃任务 | 静默显示 |

多个任务同时存在时，聚合状态按以下优先级计算：

1. 只要有任一任务处于 `waiting`，显示红灯。
2. 否则只要有任一任务处于 `working`，显示黄灯。
3. 否则如果最近 10 分钟内有任务处于 `done`，显示绿灯。
4. 其他情况显示 `idle`。

## 环境要求

- macOS 13 或更高版本
- Swift 6 工具链
- Codex Hooks 可用的 Codex 配置环境

## 构建

在项目根目录运行：

```bash
./build.command
```

构建产物位于：

```text
.build/release/CodexTrafficLightApp
.build/release/codex-light-mxp
.build/release/codex-light-hook-mxp
```

## 快速启动

构建后可以直接启动菜单栏应用：

```bash
.build/release/CodexTrafficLightApp
```

启动后，macOS 菜单栏会出现 Codex 状态灯。红灯或绿灯时会自动显示悬浮交通灯；黄灯默认只在菜单栏显示，减少打扰。

## 安装命令行工具

运行：

```bash
./install-global-command.command
```

脚本会先执行 release 构建，然后把命令软链接安装到：

```text
~/.codex/bin/codex-light-mxp
~/.codex/bin/codex-light-hook-mxp
```

确保 `~/.codex/bin` 在你的 `PATH` 中：

```bash
export PATH="$HOME/.codex/bin:$PATH"
```

## 命令行用法

常用命令：

```bash
codex-light-mxp working
codex-light-mxp done
codex-light-mxp waiting
codex-light-mxp idle
codex-light-mxp status
codex-light-mxp clear
codex-light-mxp quit
codex-light-mxp quota --app-server
codex-light-mxp quota --five-hour 72 --weekly 48
printf '%s' '{"quota":{"five_hour_remaining_percent":72,"weekly_remaining_percent":48}}' | codex-light-mxp quota --stdin
```

可选参数：

```bash
codex-light-mxp --task <task-id> working
codex-light-mxp --workspace <path> done
codex-light-mxp --json status
codex-light-mxp quota --app-server --json
codex-light-mxp quota --five-hour 72 --weekly 48 --json
codex-light-mxp quota --stdin --json
```

参数说明：

- `--task <task-id>`：指定要更新的任务 ID。
- `--workspace <path>`：指定任务所在工作区。
- `--json`：以 JSON 格式输出状态快照。
- `quota --app-server`：通过本机 Codex app-server 的 `account/rateLimits/read` 读取 5 小时和 1 周额度，并写入状态文件。
- `quota --five-hour <0-100> --weekly <0-100>`：更新浮窗底部显示的 Codex 5 小时和 1 周剩余额度百分比。
- `quota --stdin`：从标准输入读取 JSON，提取 `five_hour_remaining_percent` / `weekly_remaining_percent` 或 `fiveHourRemainingPercent` / `weeklyRemainingPercent`。

App 启动后会自动尝试采集一次额度，之后每 5 分钟轮询一次。采集依赖 Codex CLI 的实验性 `app-server` 协议；如果 Codex 升级导致协议变化或网络波动，采集失败时会保留上一次额度，不会清空现有显示。

`quota --app-server` 会为 Codex app-server 冷启动留出更宽的时间：

- `initialize` 最多等待 50 秒。
- `account/rateLimits/read` 最多等待 20 秒。
- 失败后会重试 2 次，总共最多尝试 3 次。
- 每次尝试都会重新启动独立的 `codex app-server --stdio` 进程。

## 接入 Codex Hooks

把 `Docs/hooks.example.toml` 中的配置复制到 `~/.codex/config.toml`，然后在 Codex 中运行 `/hooks`，检查并信任这些 hook 命令。

本项目要求 hook 命令使用新名称：

```text
codex-light-hook-mxp
```

如果之前配置过旧版 `codex-light-hook`，需要删除旧 hooks 配置和旧 `[hooks.state]` 信任状态，然后重新运行 `/hooks` 生成新的信任记录。

Hook 行为：

- `UserPromptSubmit` / `PreToolUse`：任务进入 `working`。
- `PermissionRequest`：任务进入 `waiting`。
- `Stop` / `SubagentStop`：任务进入 `done`，但如果最后一条助手消息看起来仍在等待用户输入，则不会标记为完成。
- 如果 hook payload 同时包含额度字段，会同步更新 `quota`。
- 如果 Codex 版本提供 `account/rateLimits/updated`、`RateLimitsUpdated` 或 `AccountRateLimitsUpdated` 这类额度事件，`codex-light-hook-mxp` 会只更新 `quota`，不创建任务。

## 运行时文件

默认状态和偏好设置保存在：

```text
~/Library/Application Support/CodexTrafficLight/state.json
~/Library/Application Support/CodexTrafficLight/preferences.json
~/Library/Application Support/CodexTrafficLight/hook-mxp.log
~/Library/Application Support/CodexTrafficLight/quota-mxp.log
```

测试或隔离运行时，可以通过环境变量覆盖状态文件路径：

```bash
CODEX_TRAFFIC_LIGHT_STATE_PATH=/tmp/codex-light-state.json codex-light-mxp status
```

状态文件包含任务状态和可选的额度信息：

```json
{
  "aggregate_state": "waiting",
  "updated_at": 1781189000.123,
  "quota": {
    "five_hour_remaining_percent": 72,
    "weekly_remaining_percent": 48,
    "source": "cli",
    "updated_at": 1781189000.123
  },
  "tasks": {}
}
```

`quota` 是账号级信息，`codex-light-mxp clear` 只清空任务状态，默认保留已有额度百分比。

如果浮窗显示 `--`，通常说明当前状态文件还没有 `quota` 字段，或者本机 Codex app-server 暂时没有返回可识别的 5 小时/1 周额度。可以先手动触发采集：

```bash
codex-light-mxp quota --app-server --json
```

如果命令失败，查看采集日志：

```bash
tail -n 50 "$HOME/Library/Application Support/CodexTrafficLight/quota-mxp.log"
```

App 后台自动采集失败时只写日志，不会弹窗、不改灯色，也不会把旧额度改成 `--`。相同失败 10 分钟内最多记录一次；错误类型变化或下一次成功后再次失败，会重新记录。

本工具不会读取 Codex 私有数据库、私有日志或 auth token。app-server 不可用时，可以临时用 `codex-light-mxp quota --five-hour 72 --weekly 48` 手动写入。

排查 Codex 是否真的触发 hook 时，可以查看最近的 hook 日志：

```bash
tail -n 50 "$HOME/Library/Application Support/CodexTrafficLight/hook-mxp.log"
```

如果日志里没有 `event=Stop`，说明 Codex 这一轮没有调用结束 hook；如果有 `event=Stop state=done result=ok`，但灯仍然是黄灯，再检查是否还有其他任务处于 `working`。如果日志里一直是 `quota=none`，说明当前 hook payload 没有带额度字段。

## 接入 Codex Desktop 兜底监控

Codex Desktop / app-server 会话有时不经过 CLI hook dispatcher。可以安装一个本机 LaunchAgent，轮询 Codex 本地日志数据库：检测到正在运行的桌面 turn 时写入黄灯，日志停止一小段时间后写入绿灯。

```bash
./install-codex-desktop-monitor.command
```

监控脚本安装到：

```text
~/.codex/bin/codex-light-codex-monitor
```

LaunchAgent 安装到：

```text
~/Library/LaunchAgents/com.codex.traffic-light-codex-monitor.plist
```

## 接入 Claude Code

Claude Code hooks 也可以直接复用本工具的命令。把下面配置合并到 `~/.claude/settings.json` 的 `hooks` 字段即可：

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.codex/bin/codex-light-hook-mxp UserPromptSubmit", "timeout": 5 }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.codex/bin/codex-light-hook-mxp PreToolUse", "timeout": 5 }
        ]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.codex/bin/codex-light-hook-mxp PermissionRequest", "timeout": 5 }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.codex/bin/codex-light-hook-mxp Notification", "timeout": 5 }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.codex/bin/codex-light-hook-mxp Stop", "timeout": 5 }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.codex/bin/codex-light-hook-mxp SubagentStop", "timeout": 5 }
        ]
      }
    ]
  }
}
```

## 端到端验证

项目内置一个轻量测试 runner：

```bash
swift run codex-light-mxp-tests
```

已经覆盖：

- 多任务聚合优先级：`waiting` > `working` > 最近 `done` > `idle`
- `done` 10 分钟过期后不参与聚合
- hook 事件到状态的映射
- `codex-light-mxp` / `codex-light-hook-mxp` 命令名约束
- `clear` 清空任务
- `quit` 状态可被 App 正确读取并退出
- hook 日志行包含事件名、状态、任务、工作区、执行结果和 quota 摘要
- quota 百分比裁剪、JSON 提取、旧状态文件兼容、quota 更新不影响红绿灯聚合状态
- Codex app-server rate limit 响应解析、JSON-RPC framing、失败重试、采集失败时保留旧 quota、后台日志节流

也可以手工做一次隔离 smoke test：

```bash
STATE=/tmp/codex-light-mxp-smoke.json
CODEX_TRAFFIC_LIGHT_STATE_PATH="$STATE" codex-light-mxp clear
CODEX_TRAFFIC_LIGHT_STATE_PATH="$STATE" codex-light-mxp quota --app-server --json
CODEX_TRAFFIC_LIGHT_STATE_PATH="$STATE" codex-light-mxp quota --five-hour 72 --weekly 48
printf '%s' '{"quota":{"fiveHourRemainingPercent":71,"weeklyRemainingPercent":47}}' \
  | CODEX_TRAFFIC_LIGHT_STATE_PATH="$STATE" codex-light-mxp quota --stdin --json
CODEX_TRAFFIC_LIGHT_STATE_PATH="$STATE" codex-light-mxp --task demo-a working
CODEX_TRAFFIC_LIGHT_STATE_PATH="$STATE" codex-light-mxp status
printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"需要你确认授权后我才能继续。","cwd":"/tmp/demo","session_id":"demo-b"}' \
  | CODEX_TRAFFIC_LIGHT_STATE_PATH="$STATE" codex-light-hook-mxp Stop
CODEX_TRAFFIC_LIGHT_STATE_PATH="$STATE" codex-light-mxp status
```

预期最后一次 `status` 输出 `waiting`。

## 开机自启

安装开机自启：

```bash
./install-autostart.command
```

移除开机自启：

```bash
./uninstall-autostart.command
```

## 常见问题

### `/hooks` 后没有自动变灯

确认 `~/.codex/config.toml` 里使用的是：

```text
$HOME/.codex/bin/codex-light-hook-mxp
```

然后重新执行 `/hooks` 并信任新命令。

### 命令找不到

先运行：

```bash
./install-global-command.command
```

再确认：

```bash
which codex-light-mxp
which codex-light-hook-mxp
```

### 需要重置残留任务

运行：

```bash
codex-light-mxp clear
```

或从菜单栏选择“清空失联任务”。
