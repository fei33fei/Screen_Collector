# Screen Collector

给 agent 用的屏幕使用时长采集器 —— 让你的 AI 知道你这台电脑今天用了多久、连续坐了多久、几点还在熬夜。

不截图、不记键盘内容、不联网、不外发。数据只落在你自己的机器上。

## 为什么需要它

陪伴型 / 助理型 agent 想开口关心你「坐太久了」「该睡了」，得先有**真实数据**支撑，而不是凭感觉说两句。这个脚本负责产出那份数据：

- 每天在屏幕前多久、其中有多少是真的在动手
- 最长连续在屏幕前多久、有没有中途离开过
- 娱乐类应用累计多久
- 23:30 之后、凌晨 1–5 点还有没有活动
- 中午 / 晚饭时段最长离开了多久（判断你是不是根本没吃饭）
- 昨夜到今晨隔了多久（睡眠估计）

产出的 `usage-today.json` 里还自带一组 `alerts`，agent 直接读它就知道「今天有什么值得说」。

## 快速开始

### 1. 直接跑（调试用）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\track-usage.ps1
```

默认每 20 秒采样一次，日志写到脚本同级的 `state\` 目录。`Ctrl+C` 停止。

### 2. 注册成开机自启的常驻任务（推荐）

```powershell
# 需要管理员权限
.\install-task.ps1
```

脚本会注册一个名为 `ScreenCollector` 的 Windows 计划任务：登录时启动、每小时重复触发一次、异常自动重启、**电池供电也不停**。

> 这几条设置是有讲究的。默认的 `Register-ScheduledTask` 模板里有三个坑，踩中任意一个采集器就会悄悄停掉：
> 1. `StopIfGoingOnBatteries` —— 笔记本拔电瞬间任务就被系统停掉
> 2. `IdleSettings.StopOnIdleEnd` —— 空闲 10 分钟就停
> 3. 触发器只有 LogonTrigger —— 无人再登录就再也不自启
>
> 加上 `ExecutionTimeLimit = PT0S`（不设 72 小时超时）和 `RestartOnFailure`（1 分钟 × 999），长跑才稳。

手动控制：

```powershell
Get-ScheduledTask -TaskName 'ScreenCollector' | Select-Object TaskName,State
Get-ScheduledTaskInfo -TaskName 'ScreenCollector' | Format-List LastRunTime,LastTaskResult,NextRunTime

Start-ScheduledTask   -TaskName 'ScreenCollector'
Stop-ScheduledTask    -TaskName 'ScreenCollector'
Restart-ScheduledTask -TaskName 'ScreenCollector'

# 卸载
.\uninstall-task.ps1
```

> `LastTaskResult = 2147946720`（`0x800710E0`）意思是「已有实例在跑，拒绝重复启动」——**任务正在运行时这是正常值，不是故障**。

## 参数

| 参数 | 默认 | 说明 |
|:--|:--|:--|
| `-IntervalSec` | `20` | 采样间隔（秒）。越小越准，也越费电 |
| `-TrackTitle` | `$false` | 是否记录窗口标题。默认**关闭** |
| `-StateDir` | 脚本同级 `state\` | 日志与汇总的输出目录 |

## 隐私

这是这个项目最要紧的部分。

**默认什么都不记敏感的东西：**

- **窗口标题默认不记录**（`-TrackTitle $false`）。标题是唯一能区分「你在刷小红书还是在看论文」的字段，也是唯一可能泄露隐私的字段——它会包含你打开的网页标题、文件名、甚至聊天窗口标题。
- 不截图、不截屏、不读键盘输入内容、不读剪贴板
- 不联网、不上传、不写任何第三方服务
- 日志文件只在本机 `state\` 目录下

**确实需要标题时**显式开启，只记前 100 字符：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\track-usage.ps1 -TrackTitle $true
```

**日志别进版本库**：`.gitignore` 已经把 `state/` 排除了。自己用的时候也注意别把 `usage-*.jsonl` 发给别人——里面是逐条的应用使用记录。

## 输出的数据

### `state\usage-YYYY-MM-DD.jsonl` —— 逐条原始采样

```json
{"ts":"2026-11-10 11:30:01","app":"Code","title":"","idleSec":3,"bucket":"work"}
```

### `state\usage-today.json` —— 当日汇总

```json
{
  "date": "2026-11-10",
  "generatedAt": "2026-11-10T11:30:01",
  "samples": 351,
  "screenMin": 97,
  "handOnMin": 76,
  "byBucket": { "work": 51.7, "other": 43, "browser-unknown": 2.3 },
  "topApps": [ { "app": "Code", "min": 49.7 } ],
  "firstActive": "09:09:51",
  "lastActive": "11:30:01",
  "longestContinuousMin": 57,
  "longestAwayMin": 10,
  "breakCount": 4,
  "hourlyScreenMin": [ ... ],
  "nightActivityMin": 0,
  "lunchAwayMin": 0,
  "sleepHoursEstimate": 10.5,
  "alerts": [ { "type": "long_sit", "severity": "mid", "minutes": 57, "text": "已连续在屏幕前 57 分钟" } ]
}
```

### 两个时间口径，别混

| 口径 | 含义 | 什么时候用 |
|:--|:--|:--|
| `screenMin` | 在屏幕前（前台窗口存在且离开 < 5 分钟） | 刷手机、看视频时长用这个 |
| `handOnMin` | 在动手（键盘/鼠标有输入，空闲 < 2 分钟） | 判断是否真的在干活 |

**为什么拆成两层**：早期版本只按「键盘鼠标有输入」算活跃度，结果躺着刷手机时长反而是 0——因为刷手机本来就不碰键盘。所以拆成「在屏幕前」和「在动手」两层，刷手机用前者，不会漏。

### `alerts` 的触发条件

| type | severity | 条件 |
|:--|:--|:--|
| `long_sit` | high / mid | 连续在屏幕前 ≥ 90 分钟 / ≥ 50 分钟 |
| `entertainment_total` | mid | 娱乐类应用累计 ≥ 120 分钟 |
| `night_use` | mid | 23:30 之后仍有屏幕活动 ≥ 30 分钟 |
| `very_late` | high | 凌晨 1–5 点仍有 ≥ 30 分钟活动 |
| `skipped_lunch` | mid | 中午最长离开 < 5 分钟且全天屏幕 ≥ 120 分钟 |
| `heavy_day` | high | 全天屏幕前累计 ≥ 600 分钟 |
| `short_sleep` | high | 昨夜到今晨间隔 < 6 小时 |

## 怎么接给 AI agent

让 agent 每隔一段时间读一次 `state\usage-today.json` 就行。最小可用逻辑：

```
读 state\usage-today.json
  → 有 alerts 且非空 → 挑最该提的那一条说（一次只说一件）
  → 无 alerts → 拿 screenMin / longestContinuousMin 报个账
  → 收尾留一个真问题
```

`alerts` 的存在就是为了给 agent 一个**开口的由头**，而不是让它凭空关心你。

### 分类是怎么判的

按**进程名**和**窗口标题**两套正则，分成五类：

| 分类 | 含义 | 举例 |
|:--|:--|:--|
| `work` | 开发 / 办公 | VS Code、Word、终端、Obsidian、Blender |
| `study` | 学习 / 读文献 | Zotero、draw.io、arXiv、MDN |
| `entertainment` | 娱乐 | 抖音、小红书、B站、Steam |
| `browser-unknown` | 浏览器但标题认不出 | 认不出就归这里，**不硬猜** |
| `other` | 其余 | |

浏览器单独处理：先看标题判娱乐还是学习，判不出来就归 `browser-unknown` 而不是硬塞进某一类。标题匹配规则集中在脚本顶部的 `$FunTitlePattern` / `$StudyTitlePattern`，按自己的习惯改。

## 兼容性

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带）—— 也兼容 PowerShell 7
- 无第三方依赖

**⚠ 编码注意**：Windows PowerShell 5.1 会把**不带 BOM** 的 UTF-8 当 GBK 读，脚本里的中文会全部乱掉。改完请确认文件是 **UTF-8 with BOM**（VS Code 右下角选 `UTF-8 with BOM`，或记事本另存为选「UTF-8」）。校验语法：

```powershell
$errs = $null
$null = [System.Management.Automation.PSParser]::Tokenize(
  (Get-Content -Raw -Encoding UTF8 .\track-usage.ps1), [ref]$errs)
if ($errs.Count -eq 0) { "语法 OK" } else { $errs }
```

## 常见问题

**Q：采集器跑着，但 `usage-today.json` 不更新？**
先看 `samples` 是不是 0。为 0 说明一条采样都没进去——通常是机器锁屏或没有前台窗口（`GetForegroundWindow` 返回 0）。解锁后过 20 秒再看。

**Q：日志里全是 `(unknown)`？**
拿不到前台窗口进程名，多半是权限或会话隔离问题（服务/计划任务在 session 0 跑）。用「交互式登录」方式注册任务，别用 SYSTEM 账户。

**Q：为什么改了脚本，任务里跑的却还是旧的？**
计划任务执行的是注册时写死的绝对路径。改完执行一次：

```powershell
Restart-ScheduledTask -TaskName 'ScreenCollector'
```

**Q：想彻底不记录任何窗口信息？**
默认就是 `-TrackTitle $false`，什么都不记标题。要更彻底可以连 `app` 进程名也去掉——改 `Get-Foreground` 里的 `$procName`，直接置 `''`。

## License

MIT
