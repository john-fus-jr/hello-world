<#
.SYNOPSIS
    Installs (or updates) the pipeline on a Windows host. Safe to re-run.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup.ps1
    powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Dev
#>
[CmdletBinding()]
param(
    [string]$PythonVersion = "3.12",
    [switch]$Dev  # also install lint/test tooling
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$python = Join-Path $root ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    Write-Host "Creating virtual environment (Python $PythonVersion)..."
    py "-$PythonVersion" -m venv .venv
    if ($LASTEXITCODE) { throw "Python $PythonVersion not found. Install it from python.org (includes the 'py' launcher)." }
}

$requirements = if ($Dev) { "requirements-dev.txt" } else { "requirements.txt" }
& $python -m pip install --quiet --upgrade pip
& $python -m pip install --quiet -r $requirements
if ($LASTEXITCODE) { throw "pip install failed" }

if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Warning "Created .env from .env.example. Fill in your Snowflake settings, then re-run this script."
    exit 0
}

Write-Host "Checking Snowflake connection..."
& (Join-Path $PSScriptRoot "dbt.ps1") debug
if ($LASTEXITCODE) { throw "dbt debug failed - check .env" }
Write-Host "Setup complete." -ForegroundColor Green
