<#
.SYNOPSIS
    Runs any dbt command with settings from .env loaded - for interactive development.
.EXAMPLE
    scripts\dbt.ps1 build --select stg_tpch__orders+
    scripts\dbt.ps1 docs generate; scripts\dbt.ps1 docs serve
#>
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            # Real environment variables win over .env, matching the Python runner.
            if (-not (Test-Path "env:$($Matches[1])")) {
                Set-Item "env:$($Matches[1])" $Matches[2].Trim('"')
            }
        }
    }
}
$env:DBT_PROFILES_DIR = $root

Push-Location $root
try {
    & (Join-Path $root ".venv\Scripts\dbt.exe") @args
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $code
