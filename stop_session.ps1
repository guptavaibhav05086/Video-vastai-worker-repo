<#
.SYNOPSIS
    Stop and destroy a Vast.ai GPU session.

.PARAMETER InstanceId
    The Vast.ai instance ID to destroy. If not provided, reads from .current_instance_id file.

.EXAMPLE
    .\stop_session.ps1
    .\stop_session.ps1 -InstanceId 12345678
#>

param(
    [string]$InstanceId
)

$SCRIPT_DIR  = Split-Path $MyInvocation.MyCommand.Path
$ID_FILE     = Join-Path $SCRIPT_DIR ".current_instance_id"

if ([string]::IsNullOrWhiteSpace($InstanceId)) {
    if (Test-Path $ID_FILE) {
        $InstanceId = (Get-Content $ID_FILE).Trim()
        Write-Host "Using saved instance ID: $InstanceId" -ForegroundColor Yellow
    } else {
        Write-Host "No instance ID provided and .current_instance_id not found." -ForegroundColor Red
        Write-Host "Usage: .\stop_session.ps1 -InstanceId <id>" -ForegroundColor Yellow
        Write-Host "Or:    vastai show instances   (to list all running instances)" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ""
Write-Host "Destroying Vast.ai instance $InstanceId ..." -ForegroundColor Yellow
$result = vastai destroy instance $InstanceId 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "Instance $InstanceId destroyed successfully." -ForegroundColor Green
    if (Test-Path $ID_FILE) {
        Remove-Item $ID_FILE
    }
} else {
    Write-Host "Failed to destroy instance: $result" -ForegroundColor Red
    Write-Host "You can also destroy it manually at: https://cloud.vast.ai/instances/" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Remember to remove HUNYUAN_API_URL / WAN22_API_URL from .env" -ForegroundColor Yellow
Write-Host "(or the pipeline will fail with a connection error on next run)" -ForegroundColor Yellow
