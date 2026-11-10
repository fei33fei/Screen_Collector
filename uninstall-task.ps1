<#
    uninstall-task.ps1 —— 移除 Screen Collector 计划任务

    用法（需要管理员权限）：
        .\uninstall-task.ps1
        .\uninstall-task.ps1 -TaskName 'MyCollector' -RemoveLogs
#>

param(
    [string]$TaskName = 'ScreenCollector',
    [switch]$RemoveLogs
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "[卸载] 计划任务 '$TaskName' 已移除。"
} else {
    Write-Output "[卸载] 没找到计划任务 '$TaskName'，跳过。"
}

if ($RemoveLogs) {
    $stateDir = Join-Path $scriptDir 'state'
    if (Test-Path $stateDir) {
        Remove-Item $stateDir -Recurse -Force
        Write-Output "[卸载] 日志目录已删除：$stateDir"
    }
} else {
    Write-Output "[卸载] 日志保留在 $(Join-Path $scriptDir 'state')（要一起删就加 -RemoveLogs）。"
}
