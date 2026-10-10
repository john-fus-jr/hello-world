<#
.SYNOPSIS
    Registers the pipeline as a Windows Scheduled Task (run as Administrator).
.DESCRIPTION
    Runs daily under a dedicated service account, whether or not anyone is logged on.
    Overlapping runs are prevented and runs are killed after -TimeoutHours.
    Run history: Task Scheduler > Task Scheduler Library > <TaskName> > History,
    and logs\pipeline.jsonl in the project folder.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\register-task.ps1 -At 05:00 -User CORP\svc_dbt
#>
[CmdletBinding()]
param(
    [string]$TaskName = "dbt-pipeline",
    [string]$At = "05:00",
    [ValidateSet("dev", "prod")][string]$Target = "prod",
    [string]$User = "$env:USERDOMAIN\$env:USERNAME",
    [int]$TimeoutHours = 4,
    [string]$ExtraArgs = ""  # passed to dbt build, e.g. "--select tag:hourly"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$python = Join-Path $root ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) { throw "Run scripts\setup.ps1 first." }

$arguments = "orchestration\run.py --target $Target $ExtraArgs".Trim()
$action = New-ScheduledTaskAction -Execute $python -Argument $arguments -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours $TimeoutHours) `
    -StartWhenAvailable

$cred = Get-Credential -UserName $User -Message "Account that will run the pipeline"
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password -RunLevel Limited -Force | Out-Null

Write-Host "Registered '$TaskName' (daily at $At, target=$Target). Test it with: Start-ScheduledTask -TaskName $TaskName" -ForegroundColor Green
