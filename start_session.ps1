<#
.SYNOPSIS
    Start a Vast.ai GPU session for CartoonAutomation video generation and LoRA training.

.DESCRIPTION
    Searches for the cheapest available RTX 4090 on Vast.ai, rents it,
    uploads the server files, and prints connection instructions.

    Prerequisites:
        pip install vastai
        vastai set api-key <your-api-key>   (run once)
        SSH key configured in Vast.ai dashboard

.PARAMETER UploadFiles
    Upload server files (hunyuan_server.py, wan22_server.py, setup_pod.sh) to the pod.
    Requires the pod to be running.

.EXAMPLE
    .\start_session.ps1
    .\start_session.ps1 -UploadFiles
#>

param(
    [switch]$UploadFiles
)

$ErrorActionPreference = "Stop"

# ── Config ────────────────────────────────────────────────────────────────────
$DISK_GB     = 80        # Minimum disk space (GB) - FLUX + HunyuanVideo need ~60 GB
$GPU_NAME    = "RTX_4090"
$MIN_DOWN    = 500       # Minimum download speed (Mbps) - for model downloads
$DOCKER_IMG  = "pytorch/pytorch:2.4.0-cuda12.4-cudnn9-devel"
$SCRIPT_DIR  = Split-Path $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  CartoonAutomation - Vast.ai Session  " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── Check vastai CLI ──────────────────────────────────────────────────────────
if (-not (Get-Command vastai -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: vastai CLI not found. Install it:" -ForegroundColor Red
    Write-Host "  pip install vastai" -ForegroundColor Yellow
    Write-Host "  vastai set api-key <your-api-key>" -ForegroundColor Yellow
    exit 1
}

# ── Search for cheapest RTX 4090 ─────────────────────────────────────────────
Write-Host "Searching for cheapest $GPU_NAME on Vast.ai..." -ForegroundColor Yellow
Write-Host "(Filters: $DISK_GB GB disk, ${MIN_DOWN} Mbps down, verified=True)"
Write-Host ""

$searchQuery = "num_gpus=1 gpu_name=$GPU_NAME disk_space>=$DISK_GB inet_down>=$MIN_DOWN verified=True"
$offers = vastai search offers $searchQuery -o "dph_total asc" --raw 2>&1 | ConvertFrom-Json

if (-not $offers -or $offers.Count -eq 0) {
    Write-Host "No offers found. Try relaxing filters (lower MIN_DOWN or DISK_GB)." -ForegroundColor Red
    exit 1
}

Write-Host "Top 5 cheapest offers:" -ForegroundColor Green
Write-Host ("{0,-12} {1,-10} {2,-8} {3,-10} {4,-8}" -f "ID", "$/hr", "VRAM", "Disk(GB)", "Speed")
Write-Host ("-" * 55)
$offers | Select-Object -First 5 | ForEach-Object {
    $dph = [math]::Round($_.dph_total, 4)
    $inrHr = [math]::Round($dph * 85, 1)
    Write-Host ("{0,-12} `${1,-9} {2,-8} {3,-10} {4} Mbps (Rs.{5}/hr)" -f `
        $_.id, $dph, "$($_.gpu_ram)GB", [int]$_.disk_space, [int]$_.inet_down, $inrHr)
}

Write-Host ""
$selectedId = Read-Host "Enter offer ID to rent (or press Enter to use cheapest)"
if ([string]::IsNullOrWhiteSpace($selectedId)) {
    $selectedId = $offers[0].id
    Write-Host "Using cheapest offer: $selectedId" -ForegroundColor Green
}

# ── Rent the instance ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Renting instance $selectedId ..." -ForegroundColor Yellow

$createResult = vastai create instance $selectedId `
    --image $DOCKER_IMG `
    --disk $DISK_GB `
    --onstart-cmd "bash /workspace/setup_pod.sh" `
    --raw 2>&1 | ConvertFrom-Json

if (-not $createResult.success) {
    Write-Host "Failed to create instance: $($createResult | ConvertTo-Json)" -ForegroundColor Red
    exit 1
}

$INSTANCE_ID = $createResult.new_contract
Write-Host "Instance created! ID: $INSTANCE_ID" -ForegroundColor Green

# ── Wait for instance to be running ──────────────────────────────────────────
Write-Host ""
Write-Host "Waiting for instance to start (usually 1-3 minutes)..." -ForegroundColor Yellow
$attempts = 0
do {
    Start-Sleep -Seconds 15
    $attempts++
    $info = vastai show instances --raw 2>&1 | ConvertFrom-Json
    $instance = $info | Where-Object { $_.id -eq $INSTANCE_ID }
    $status = if ($instance) { $instance.actual_status } else { "unknown" }
    Write-Host "  Attempt $attempts - Status: $status"
} while ($status -ne "running" -and $attempts -lt 20)

if ($status -ne "running") {
    Write-Host "Instance did not start in time. Check Vast.ai dashboard." -ForegroundColor Red
    exit 1
}

Write-Host "Instance is RUNNING!" -ForegroundColor Green

# ── Get connection info ───────────────────────────────────────────────────────
$sshHost = $instance.ssh_host
$sshPort = $instance.ssh_port
$pubIp   = $instance.public_ipaddr

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  INSTANCE READY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Instance ID : $INSTANCE_ID"
Write-Host "  Public IP   : $pubIp"
Write-Host "  SSH command : ssh -p $sshPort root@$sshHost"
Write-Host "  Cost        : `$$([math]::Round($offers[0].dph_total,4))/hr (Rs.$([math]::Round($offers[0].dph_total*85,1))/hr)"
Write-Host ""

# ── Upload server files ───────────────────────────────────────────────────────
if ($UploadFiles) {
    Write-Host "Uploading server files via rsync..." -ForegroundColor Yellow
    $vastaiDir = Join-Path $SCRIPT_DIR "."
    & rsync -avz -e "ssh -p $sshPort" `
        "$vastaiDir/hunyuan_server.py" `
        "$vastaiDir/wan22_server.py" `
        "$vastaiDir/setup_pod.sh" `
        "$vastaiDir/requirements_pod.txt" `
        "root@${sshHost}:/workspace/"
    Write-Host "Files uploaded." -ForegroundColor Green
}

# ── Print .env instructions ───────────────────────────────────────────────────
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. SSH into the pod:"
Write-Host "     ssh -p $sshPort root@$sshHost" -ForegroundColor Cyan
Write-Host ""
Write-Host "  2. If files not uploaded yet, run in a separate PowerShell window:"
Write-Host "     .\start_session.ps1 -UploadFiles" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. On the pod, run setup (first time only):"
Write-Host "     bash /workspace/setup_pod.sh" -ForegroundColor Cyan
Write-Host ""
Write-Host "  4. Start the video server:"
Write-Host "     bash /workspace/start_hunyuan.sh" -ForegroundColor Cyan
Write-Host ""
Write-Host "  5. Add to your .env on this machine:"
Write-Host "     ANIMATION_BACKEND=hunyuan" -ForegroundColor Cyan
Write-Host "     HUNYUAN_API_URL=http://${pubIp}:8000/generate" -ForegroundColor Cyan
Write-Host ""
Write-Host "  6. When done, stop the instance:"
Write-Host "     .\stop_session.ps1 -InstanceId $INSTANCE_ID" -ForegroundColor Cyan
Write-Host ""

# Save instance ID for easy stop later
$INSTANCE_ID | Out-File -FilePath (Join-Path $SCRIPT_DIR ".current_instance_id") -Encoding utf8
Write-Host "Instance ID saved to .current_instance_id" -ForegroundColor Gray
