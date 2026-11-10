<#
    install-task.ps1 —— 把采集器注册成开机自启的 Windows 计划任务

    用法（需要管理员权限的 PowerShell）：
        .\install-task.ps1
        .\install-task.ps1 -TaskName 'MyCollector' -IntervalSec 30

    做三件事：
      1. 生成任务 XML（关键：电池不停止、空闲不停止、无超时、失败自动重启）
      2. 注册计划任务（交互式登录账户，随开机自启）
      3. 立即启动并验证
#>

param(
    [string]$TaskName = 'ScreenCollector',
    [int]$IntervalSec = 20,
    [switch]$TrackTitle,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $scriptDir 'track-usage.ps1'

if (-not (Test-Path $scriptPath)) {
    throw "找不到采集器脚本：$scriptPath"
}

# ---- 1. 任务执行的命令行 ----
$argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
if ($IntervalSec -ne 20) { $argLine += " -IntervalSec $IntervalSec" }
if ($TrackTitle) { $argLine += " -TrackTitle `$true" }

$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$exe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# ---- 2. 生成任务 XML ----
# 这几条设置是重点，缺一个采集器就会悄悄停掉：
#   StopIfGoingOnBatteries = false   拔电不停
#   DisallowStartIfOnBatteries=false  电池供电也允许启动
#   StopOnIdleEnd = false            空闲不停
#   ExecutionTimeLimit = PT0S        不设 72 小时超时
#   RestartOnFailure                 崩了 1 分钟后自动重试，最多 999 次
#   触发器 = 登录触发 + 每小时重复     无人登录也能自启
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Screen Collector - 屏幕使用时长采集器（20 秒采样前台窗口）</Description>
    <URI>\$TaskName</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$user</UserId>
      <Delay>PT30S</Delay>
    </LogonTrigger>
    <TimeTrigger>
      <Repetition>
        <Interval>PT1H</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2026-01-01T00:05:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>true</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$exe</Command>
      <Arguments>$argLine</Arguments>
      <WorkingDirectory>$scriptDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

# XML 声明要求 UTF-16 编码
$xmlBytes = [System.Text.Encoding]::Unicode.GetBytes($xml)
$xmlPath = Join-Path $env:TEMP "ScreenCollector-$TaskName.xml"
[System.IO.File]::WriteAllBytes($xmlPath, $xmlBytes)

# ---- 3. 注册（同名任务先删掉再重建，避免旧设置残留）----
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Output "[安装] 已存在同名任务，先移除旧的..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -Xml $xmlPath -Force | Out-Null
Write-Output "[安装] 计划任务 '$TaskName' 已注册。"
Write-Output "[安装] 采样间隔 ${IntervalSec}s，标题记录 $(if ($TrackTitle) {'开'} else {'关'})。"

# ---- 4. 启动 + 验证 ----
if (-not $NoStart) {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    $state = (Get-ScheduledTask -TaskName $TaskName).State
    Write-Output "[安装] 任务状态：$state"
    Write-Output "[安装] LastTaskResult = $($info.LastTaskResult)"
    Write-Output "[安装] NextRunTime = $($info.NextRunTime)"
    if ($info.LastTaskResult -eq 2147946720) {
        Write-Output "[安装] 2147946720 = 0x800710E0「已有实例在跑，拒绝重复启动」—— 正常。"
    }
}

Write-Output "[安装] 完成。日志与汇总会出现在 $scriptDir\state\"
