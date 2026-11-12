<#
    track-usage.ps1 —— 屏幕使用时长 / 作息采集器（Screen Collector）

    做什么：每 20 秒采样一次前台窗口（应用名 + 可选的窗口标题），同时读取系统空闲时间。
    产出：
      state\usage-YYYY-MM-DD.jsonl   逐条原始采样（换行 JSON）
      state\usage-today.json         当日汇总（含 alerts，agent 直接读这个）

    两个时间口径，别混：
      screenMin —— 在屏幕前（前台窗口存在且离开 < 5 分钟）。看视频不碰键盘也算在内。
      handOnMin —— 在动手（键盘/鼠标有输入）。
    刷手机时长用 screenMin 口径，否则「躺着看视频」会被漏掉。

    隐私（默认就是安全的）：
      - 默认 -TrackTitle $false —— 完全不记录窗口标题。
      - 标题是唯一能识别「你在刷小红书还是在看论文」的字段，也是最敏感的字段；
        确实需要时显式传 -TrackTitle $true，只记前 100 字符。
      - 不截图、不记键盘输入内容、不联网、不外发。
      - 日志只写在本机 StateDir 下，请自行管理，不要提交进版本库（见 .gitignore）。

    依赖：Windows PowerShell 5.1+（系统自带）。无第三方模块。
#>

param(
    [int]$IntervalSec = 20,
    [bool]$TrackTitle = $false,
    [string]$StateDir = (Join-Path $PSScriptRoot 'state')
)

$ErrorActionPreference = 'Stop'
$StateDir = [System.IO.Path]::GetFullPath($StateDir)
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

# 单实例：计划任务与手动启动可能同时存在，靠命名互斥量挡住重复写入
$mutex = New-Object System.Threading.Mutex($false, 'Local\ScreenCollectorTracker')
if (-not $mutex.WaitOne(0, $false)) {
    Write-Output '[采集器] 已有实例在运行，本次退出。'
    exit 0
}

$IdleAwaySec = 300   # 超过这个空闲时长算「离开屏幕」
$IdleHandSec = 120   # 小于这个空闲时长算「在动手」

# ---------- Win32 API ----------
if (-not ('ScreenCollector.Win32' -as [type])) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace ScreenCollector {
    public class Win32 {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        [StructLayout(LayoutKind.Sequential)]
        public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    }
}
"@
}

# ---------- 分类规则 ----------
$WorkPattern  = 'WINWORD|EXCEL|POWERPNT|OUTLOOK|ONENOTE|ms-teams|code|Code|devenv|idea64|pycharm64|webstorm|goland|rider|cmd\.exe|powershell|pwsh|WindowsTerminal|wt\.exe|bash|git|docker|docker-compose|kubectl|helm|k9s|minikube|python|node|mavis|obsidian|postman|apifox|navicat|dbeaver|redis|cloudflared|nginx|wireshark|figma|blender'
$StudyPattern = 'acrobat|Acrobat|Sumatra|Foxit|zotero|mendeley|pdfsam|drawio|visio|matlab|mathematica'
$FunPattern   = 'douyin|kuaishou|xiaohongshu|bilibili|steam|steamwebhelper|QQMusic|NetEaseMusic|cloudmusic|wyy|wegame|riot|game|Tencent|League|Huya|Douyu|zhihu|weibo|tieba|taobao|jd\.exe|youdao|zhihuishu|Perfect365|wps'

$FunTitlePattern = '抖音|小红书|bilibili|哔哩|B站|知乎|微博|淘宝|京东|拼多多|游戏|起点|番茄|网易云|什么值得买|虎牙|斗鱼|贴吧|快手'
$StudyTitlePattern = 'arxiv|MDN|GitHub|github|知网|CNKI|论文|Paper|paper|PyTorch|pytorch|numpy|stackoverflow|LeetCode|kubernetes|kserve|docker|Docker|nvidia|Hugging|developer\.mozilla|教程|课程|学习'

function Get-Bucket {
    param([string]$App, [string]$Title)

    $app = if ($App) { $App } else { '' }
    $title = if ($Title) { $Title } else { '' }

    if ($app -match 'chrome|msedge|firefox|brave|360se|QQBrowser|sogou|iexplore|Edge') {
        if ($title -match $FunTitlePattern) { return 'entertainment' }
        if ($title -match $StudyTitlePattern) { return 'study' }
        return 'browser-unknown'
    }
    if ($app -match $FunPattern)   { return 'entertainment' }
    if ($app -match $StudyPattern) { return 'study' }
    if ($app -match $WorkPattern)  { return 'work' }
    if ($title -match $FunTitlePattern)   { return 'entertainment' }
    if ($title -match $StudyTitlePattern) { return 'study' }
    return 'other'
}

# ---------- 采样 ----------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-Foreground {
    $h = [ScreenCollector.Win32]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return $null }

    $procId = 0
    [void][ScreenCollector.Win32]::GetWindowThreadProcessId($h, [ref]$procId)

    $procName = ''
    try {
        $p = Get-Process -Id $procId -ErrorAction Stop
        $procName = $p.ProcessName
    } catch { $procName = '' }

    $title = ''
    if ($TrackTitle) {
        try {
            $sb = New-Object System.Text.StringBuilder 512
            [void][ScreenCollector.Win32]::GetWindowText($h, $sb, 512)
            $title = $sb.ToString()
            if ($title.Length -gt 100) { $title = $title.Substring(0,100) }
        } catch { $title = '' }
    }

    $li = New-Object ScreenCollector.Win32+LASTINPUTINFO
    $li.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($li)
    $idleMs = 0
    if ([ScreenCollector.Win32]::GetLastInputInfo([ref]$li)) {
        $delta = [uint32]([Environment]::TickCount) - [uint32]$li.dwTime
        $idleMs = [long]$delta
    }

    [pscustomobject]@{
        ts      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        app     = $procName
        title   = $title
        idleSec = [math]::Round($idleMs / 1000, 0)
        bucket  = (Get-Bucket -App $procName -Title $title)
    }
}

function Get-TodayLogPath { Join-Path $StateDir ("usage-{0}.jsonl" -f (Get-Date -Format 'yyyy-MM-dd')) }

# 读「今天」的全部采样：扫同目录所有 usage-*.jsonl，按 ts 的日期过滤。
# 为什么不能只读当前那个文件：进程跨零点不换文件时，今天的行会留在昨天那个文件里
# （只读当前文件会以为今天一条数据都没有，汇总也会把两天加在一起）。
function Read-TodaySamples {
    $todayStr = (Get-Date -Format 'yyyy-MM-dd')
    $rows = @()
    $files = @(Get-ChildItem -Path $StateDir -Filter 'usage-*.jsonl' -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        foreach ($line in (Get-Content $f.FullName -Encoding UTF8)) {
            if ($line.Trim() -and $line -like "*$todayStr *") {
                try { $rows += ($line | ConvertFrom-Json) } catch { }
            }
        }
    }
    return $rows
}

# ---------- 汇总 ----------
function Write-Summary {
    param([object[]]$Samples)

    $summaryPath = Join-Path $StateDir 'usage-today.json'

    # 只统计「今天」的样本：进程跨零点仍在跑时，$Samples 里会混着昨天的行，
    # 不过滤的话 screenMin 会变成两天的和、firstActive 落在昨天。
    $todayStr = (Get-Date -Format 'yyyy-MM-dd')
    $Samples = @($Samples | Where-Object { $_.ts -like "$todayStr*" })

    if (-not $Samples -or $Samples.Count -eq 0) {
        $empty = [ordered]@{
            date = (Get-Date -Format 'yyyy-MM-dd'); generatedAt = (Get-Date).ToString('s'); samples = 0
            screenMin = 0; handOnMin = 0; byBucket = @{}; topApps = @()
            firstActive = $null; lastActive = $null
            longestContinuousMin = 0; longestAwayMin = 0; breakCount = 0
            hourlyScreenMin = @(); nightActivityMin = 0; lateNightMin = 0
            lunchAwayMin = 0; dinnerAwayMin = 0; sleepHoursEstimate = $null; alerts = @()
        }
        [System.IO.File]::WriteAllText($summaryPath, ($empty | ConvertTo-Json -Depth 6), $utf8NoBom)
        return
    }

    $buckets = @{}
    $apps = @{}
    $hourly = New-Object double[] 24
    $first = $null; $last = $null
    $screenMin = 0.0; $handOnMin = 0.0
    $stepMin = $IntervalSec / 60.0

    foreach ($s in $Samples) {
        if ($null -eq $first) { $first = $s.ts }
        $last = $s.ts

        if ($s.idleSec -lt $IdleAwaySec) {
            $screenMin += $stepMin
            $t = [datetime]::ParseExact($s.ts, 'yyyy-MM-dd HH:mm:ss', $null)
            $hourly[$t.Hour] += $stepMin

            $b = $s.bucket
            if (-not $buckets.ContainsKey($b)) { $buckets[$b] = 0.0 }
            $buckets[$b] += $stepMin

            $a = if ($s.app) { $s.app } else { '(unknown)' }
            if (-not $apps.ContainsKey($a)) { $apps[$a] = 0.0 }
            $apps[$a] += $stepMin

            if ($s.idleSec -lt $IdleHandSec) { $handOnMin += $stepMin }
        }
    }

    # 连续在屏幕前的最长段 / 离开的最长段 / 离开次数
    $run = 0; $best = 0; $awayRun = 0; $bestAway = 0; $breaks = 0
    foreach ($s in $Samples) {
        if ($s.idleSec -lt $IdleAwaySec) {
            $run++; $awayRun = 0
            if ($run -gt $best) { $best = $run }
        } else {
            $run = 0; $awayRun++
            if ($awayRun -eq 1) { $breaks++ }
            if ($awayRun -gt $bestAway) { $bestAway = $awayRun }
        }
    }

    # 夜间（23:30 后）与深夜（01:00-05:00）
    $nightMin = 0.0; $lateMin = 0.0
    foreach ($s in $Samples) {
        if ($s.idleSec -ge $IdleAwaySec) { continue }
        $t = [datetime]::ParseExact($s.ts, 'yyyy-MM-dd HH:mm:ss', $null)
        $mins = $t.Hour * 60 + $t.Minute
        if ($mins -ge 1410 -or $mins -lt 30) { $nightMin += $stepMin }
        if ($t.Hour -ge 1 -and $t.Hour -lt 5) { $lateMin += $stepMin }
    }

    # 午/晚餐时段最长离开（用最大空闲秒数近似「去吃饭了」）
    $lunchAway = 0.0; $dinnerAway = 0.0
    foreach ($s in $Samples) {
        $t = [datetime]::ParseExact($s.ts, 'yyyy-MM-dd HH:mm:ss', $null)
        $mins = $t.Hour * 60 + $t.Minute
        if ($mins -ge 11*60+30 -and $mins -lt 13*60+30) { if ($s.idleSec -gt $lunchAway) { $lunchAway = $s.idleSec } }
        if ($mins -ge 17*60+30 -and $mins -lt 20*60) { if ($s.idleSec -gt $dinnerAway) { $dinnerAway = $s.idleSec } }
    }

    $topApps = @($apps.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 8 | ForEach-Object {
        [ordered]@{ app = $_.Key; min = [math]::Round($_.Value, 1) }
    })

    $byBucket = @{}
    foreach ($k in $buckets.Keys) { $byBucket[$k] = [math]::Round($buckets[$k], 1) }
    $hourlyOut = @($hourly | ForEach-Object { [math]::Round($_, 1) })

    # 睡眠时长估计：昨夜最后活动 -> 今早第一次活动
    $sleepHours = $null
    if ($Samples.Count -gt 1) {
        $firstT = [datetime]::ParseExact($first, 'yyyy-MM-dd HH:mm:ss', $null)
        if ($firstT.Hour -ge 5 -and $firstT.Hour -le 11) {
            $yesterdayLog = Join-Path $StateDir ("usage-{0}.jsonl" -f (Get-Date).AddDays(-1).ToString('yyyy-MM-dd'))
            if (Test-Path $yesterdayLog) {
                $ylast = (Get-Content $yesterdayLog -Encoding UTF8 | Select-Object -Last 1)
                if ($ylast) {
                    $y = $ylast | ConvertFrom-Json
                    $yT = [datetime]::ParseExact($y.ts, 'yyyy-MM-dd HH:mm:ss', $null)
                    $gap = ($firstT - $yT).TotalHours
                    if ($gap -gt 2 -and $gap -lt 16) { $sleepHours = [math]::Round($gap, 1) }
                }
            }
        }
    }

    # ---- 告警：给 agent 的开口理由 ----
    $alerts = @()
    $contMin = [math]::Round($best * $stepMin, 0)
    $screenMinR = [math]::Round($screenMin, 0)
    $fun = if ($byBucket.ContainsKey('entertainment')) { $byBucket['entertainment'] } else { 0 }

    if ($contMin -ge 90) {
        $alerts += [ordered]@{ type='long_sit'; severity='high'; minutes=$contMin; text="已连续在屏幕前 $contMin 分钟没离开过" }
    } elseif ($contMin -ge 50) {
        $alerts += [ordered]@{ type='long_sit'; severity='mid'; minutes=$contMin; text="已连续在屏幕前 $contMin 分钟" }
    }
    if ($fun -ge 120) {
        $alerts += [ordered]@{ type='entertainment_total'; severity='mid'; minutes=$fun; text="娱乐类应用今天累计 $fun 分钟" }
    }
    if ($nightMin -ge 30) {
        $alerts += [ordered]@{ type='night_use'; severity='mid'; minutes=[math]::Round($nightMin,0); text="23:30 之后仍有 $([math]::Round($nightMin,0)) 分钟屏幕活动" }
    }
    if ($lateMin -ge 30) {
        $alerts += [ordered]@{ type='very_late'; severity='high'; minutes=[math]::Round($lateMin,0); text="凌晨 1–5 点还在用屏幕 $([math]::Round($lateMin,0)) 分钟" }
    }
    if ($lunchAway -lt $IdleAwaySec -and $screenMin -ge 120) {
        $alerts += [ordered]@{ type='skipped_lunch'; severity='mid'; minutes=[math]::Round($lunchAway/60,1); text="中午几乎没有离开过屏幕（最长离开 $([math]::Round($lunchAway/60,1)) 小时）" }
    }
    if ($screenMin -ge 600) {
        $alerts += [ordered]@{ type='heavy_day'; severity='high'; minutes=$screenMinR; text="今天屏幕前累计 $screenMinR 分钟" }
    }
    if ($null -ne $sleepHours -and $sleepHours -lt 6) {
        $alerts += [ordered]@{ type='short_sleep'; severity='high'; hours=$sleepHours; text="昨夜到今早只隔了 $sleepHours 小时" }
    }

    $out = [ordered]@{
        date                 = (Get-Date -Format 'yyyy-MM-dd')
        generatedAt          = (Get-Date).ToString('s')
        samples              = $Samples.Count
        screenMin            = $screenMinR
        handOnMin            = [math]::Round($handOnMin, 0)
        byBucket             = $byBucket
        topApps              = $topApps
        firstActive          = $first
        lastActive           = $last
        longestContinuousMin = $contMin
        longestAwayMin       = [math]::Round($bestAway * $stepMin, 0)
        breakCount           = $breaks
        hourlyScreenMin      = $hourlyOut
        nightActivityMin     = [math]::Round($nightMin, 0)
        lateNightMin         = [math]::Round($lateMin, 0)
        lunchAwayMin         = [math]::Round($lunchAway / 60, 1)
        dinnerAwayMin        = [math]::Round($dinnerAway / 60, 1)
        sleepHoursEstimate   = $sleepHours
        alerts               = $alerts
    }
    [System.IO.File]::WriteAllText($summaryPath, ($out | ConvertTo-Json -Depth 6), $utf8NoBom)
}

# ---------- 主循环 ----------
Write-Output "[采集器] 启动，采样间隔 ${IntervalSec}s，离开阈值 ${IdleAwaySec}s，标题记录 $(if ($TrackTitle) {'开'} else {'关'})，状态目录 $StateDir"

$logPath = Get-TodayLogPath
$logDate = (Get-Date -Format 'yyyy-MM-dd')
$existing = @(Read-TodaySamples)
$all = [System.Collections.ArrayList]@($existing)

while ($true) {
    # 跨零点：换当天的日志文件，并把当天的样本重新读回来。
    # 不换的话日志文件会一直追加下去（文件名停在启动那天），usage-YYYY-MM-DD.jsonl
    # 也就对不上日期。
    $nowDate = (Get-Date -Format 'yyyy-MM-dd')
    if ($nowDate -ne $logDate) {
        $logDate = $nowDate
        $logPath = Get-TodayLogPath
        $existing = @(Read-TodaySamples)
        $all = [System.Collections.ArrayList]@($existing)
        Write-Output "[采集器] 日期切换 -> $logDate，日志 $logPath"
    }

    try {
        $s = Get-Foreground
        if ($s) {
            $line = $s | ConvertTo-Json -Compress
            [System.IO.File]::AppendAllText($logPath, $line + "`n", $utf8NoBom)
            [void]$all.Add($s)
        }
    } catch {
        Write-Output "[采集器] 采样异常: $($_.Exception.Message)"
    }

    try { Write-Summary -Samples $all } catch { Write-Output "[采集器] 汇总异常: $($_.Exception.Message)" }

    Start-Sleep -Seconds $IntervalSec
}
