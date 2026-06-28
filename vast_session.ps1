<#
.SYNOPSIS
    Manages Vast.ai GPU sessions for CartoonAutomation video generation and LoRA training.

.DESCRIPTION
    Vast.ai pods are NOT always-on. You rent one, do your work, then destroy it.
    This script automates the full lifecycle so you never need to manually SSH,
    upload files, or edit .env.

    ACTIONS:
      start  - Find cheapest RTX 4090, rent it, upload files, install deps,
               start HunyuanVideo server, and auto-update .env with the pod IP.
      stop   - Destroy the running instance and clear HUNYUAN_API_URL from .env.
      status - Show whether a pod is running and whether the server is responding.

    TYPICAL SESSION WORKFLOW:
      1. Before generating videos or training LoRAs:
           .\vast_session.ps1 -Action start
         (takes ~15-20 min first time; ~8-10 min after first setup is cached)

      2. Run CartoonAutomation pipeline normally - it calls the pod automatically.

      3. After all video/LoRA work for the day is done:
           .\vast_session.ps1 -Action stop

    COST:
      A typical 60-min session at Rs.40/hr = Rs.40 total.
      The script prints elapsed time and estimated cost on stop.

.PARAMETER Action
    One of: start, stop, status

.PARAMETER SshKeyPath
    Path to the SSH private key that matches the public key added to Vast.ai.
    Default: $HOME\.ssh\id_rsa

.PARAMETER DiskGB
    Minimum disk space on the rented instance. Default: 80 GB.

.PARAMETER MinDownMbps
    Minimum internet download speed. Default: 200 Mbps.

.PARAMETER VideoBackend
    Which video server to start: hunyuan (default) or wan22.

.EXAMPLE
    .\vast_session.ps1 -Action start
    .\vast_session.ps1 -Action start -SshKeyPath "C:\Users\Vaibhav\vastKeys"
    .\vast_session.ps1 -Action stop
    .\vast_session.ps1 -Action status
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("start", "stop", "status")]
    [string]$Action,

    [string]$SshKeyPath  = "$env:USERPROFILE\.ssh\id_rsa",
    [int]$DiskGB         = 80,
    [int]$MinDownMbps    = 200,
    [ValidateSet("hunyuan","wan22")]
    [string]$VideoBackend = "hunyuan"
)

$ErrorActionPreference = "Stop"

# ── Paths ─────────────────────────────────────────────────────────────────────
$SCRIPT_DIR   = Split-Path $MyInvocation.MyCommand.Path
$PROJECT_ROOT = (Resolve-Path (Join-Path $SCRIPT_DIR "../../..")).Path
$ENV_FILE     = Join-Path $PROJECT_ROOT ".env"
$ID_FILE      = Join-Path $SCRIPT_DIR ".current_instance_id"
$META_FILE    = Join-Path $SCRIPT_DIR ".current_session_meta.json"

# Server files to upload from this directory
$SERVER_FILES = @(
    (Join-Path $SCRIPT_DIR "setup_pod.sh"),
    (Join-Path $SCRIPT_DIR "hunyuan_server.py"),
    (Join-Path $SCRIPT_DIR "wan22_server.py"),
    (Join-Path $SCRIPT_DIR "requirements_pod.txt")
)

# ── Helpers ───────────────────────────────────────────────────────────────────

function Assert-Command($name, $installHint) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: '$name' not found. $installHint" -ForegroundColor Red
        exit 1
    }
}

function Update-EnvVar($key, $value) {
    # Add or replace a key=value line in .env
    if (-not (Test-Path $ENV_FILE)) {
        Write-Host "  WARNING: .env not found at $ENV_FILE" -ForegroundColor Yellow
        return
    }
    $content = Get-Content $ENV_FILE -Raw
    $pattern = "(?m)^($key\s*=.*)$"
    $replacement = "$key=$value"
    if ($content -match $pattern) {
        $content = $content -replace $pattern, $replacement
    } else {
        $content = $content.TrimEnd() + "`n$replacement`n"
    }
    Set-Content $ENV_FILE $content -NoNewline
    Write-Host "  .env updated: $key=$value" -ForegroundColor Green
}

function Get-EnvVar($key) {
    if (-not (Test-Path $ENV_FILE)) { return "" }
    $line = Get-Content $ENV_FILE | Where-Object { $_ -match "^$key\s*=" } | Select-Object -First 1
    if ($line) { return ($line -split "=", 2)[1].Trim() }
    return ""
}

function Invoke-SshCommand($sshPort, $sshHost, $keyPath, $command) {
    # Run a command on the pod and return stdout. Suppress host key warning.
    $result = & ssh -p $sshPort `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=/dev/null `
        -o BatchMode=yes `
        -o ConnectTimeout=30 `
        -i $keyPath `
        "root@$sshHost" $command 2>&1
    return $result
}

function Copy-FileToHost($sshPort, $sshHost, $keyPath, $localPath, $remotePath) {
    & scp -P $sshPort `
        -o StrictHostKeyChecking=no `
        -o UserKnownHostsFile=/dev/null `
        -i $keyPath `
        $localPath "root@${sshHost}:${remotePath}" 2>&1 | Out-Null
}


# ==============================================================================
#  ACTION: status
# ==============================================================================
if ($Action -eq "status") {
    Write-Host ""
    Write-Host "=== Vast.ai Session Status ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path $ID_FILE)) {
        Write-Host "  No active session (no .current_instance_id file)" -ForegroundColor Gray
    } else {
        $instanceId = (Get-Content $ID_FILE).Trim()
        Write-Host "  Saved instance ID : $instanceId"

        try {
            $info = vastai show instances --raw 2>&1 | ConvertFrom-Json
            $inst = $info | Where-Object { $_.id -eq [int]$instanceId }
            if ($inst) {
                Write-Host "  Vast.ai status    : $($inst.actual_status)" -ForegroundColor Green
                Write-Host "  Public IP         : $($inst.public_ipaddr)"
                Write-Host "  SSH               : ssh -p $($inst.ssh_port) root@$($inst.ssh_host)"
                $hrs = [math]::Round(((Get-Date) - [datetime]($inst.start_date)).TotalHours, 2)
                $cost = [math]::Round($hrs * $inst.dph_total * 85, 1)
                Write-Host "  Running for       : $hrs hrs  (~Rs.$cost so far)"
            } else {
                Write-Host "  Instance $instanceId not found in Vast.ai (may have been destroyed)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Could not query Vast.ai: $_" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "  .env settings:" -ForegroundColor Gray
    $backend = Get-EnvVar "ANIMATION_BACKEND"
    $apiUrl  = Get-EnvVar "HUNYUAN_API_URL"
    $wan22   = Get-EnvVar "WAN22_API_URL"
    Write-Host "    ANIMATION_BACKEND  = $backend"
    Write-Host "    HUNYUAN_API_URL    = $apiUrl"
    Write-Host "    WAN22_API_URL      = $wan22"

    if ($apiUrl) {
        Write-Host ""
        Write-Host "  Checking server health at $apiUrl ..." -ForegroundColor Gray
        $healthUrl = $apiUrl -replace "/generate", "/health"
        try {
            $resp = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 5 -UseBasicParsing
            Write-Host "  Server health     : OK - $($resp.Content)" -ForegroundColor Green
        } catch {
            Write-Host "  Server health     : UNREACHABLE (pod stopped or server not started)" -ForegroundColor Red
        }
    }
    Write-Host ""
    exit 0
}


# ==============================================================================
#  ACTION: stop
# ==============================================================================
if ($Action -eq "stop") {
    Write-Host ""
    Write-Host "=== Stopping Vast.ai Session ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path $ID_FILE)) {
        Write-Host "  No saved instance ID found. Nothing to stop." -ForegroundColor Yellow
        Write-Host "  Check cloud.vast.ai/instances/ to verify manually." -ForegroundColor Gray
        exit 0
    }

    $instanceId = (Get-Content $ID_FILE).Trim()
    Write-Host "  Instance ID: $instanceId"

    # Calculate session cost before destroying
    if (Test-Path $META_FILE) {
        $meta = Get-Content $META_FILE -Raw | ConvertFrom-Json
        $startTime = [datetime]$meta.start_time
        $dph = $meta.dph_total
        $hrs = [math]::Round(((Get-Date) - $startTime).TotalHours, 2)
        $costUsd = [math]::Round($hrs * $dph, 4)
        $costInr = [math]::Round($costUsd * 85, 1)
        Write-Host "  Session duration  : $hrs hours"
        Write-Host "  Estimated cost    : `$$costUsd USD  (~Rs.$costInr)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Destroying instance $instanceId ..." -ForegroundColor Yellow
    vastai destroy instance $instanceId 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Instance destroyed." -ForegroundColor Green
    } else {
        Write-Host "  vastai destroy returned non-zero. Check cloud.vast.ai/instances/" -ForegroundColor Red
    }

    # Clear session files
    Remove-Item $ID_FILE -ErrorAction SilentlyContinue
    Remove-Item $META_FILE -ErrorAction SilentlyContinue

    # Clear API URLs from .env so the pipeline does not error on next run
    Write-Host ""
    Write-Host "  Clearing API URLs from .env ..."
    Update-EnvVar "HUNYUAN_API_URL" ""
    Update-EnvVar "WAN22_API_URL" ""
    Update-EnvVar "ANIMATION_BACKEND" "kling"

    Write-Host ""
    Write-Host "  ANIMATION_BACKEND reset to 'kling' (fal.ai fallback)" -ForegroundColor Green
    Write-Host "  Session stopped. GPU is no longer billed." -ForegroundColor Green
    Write-Host ""
    exit 0
}


# ==============================================================================
#  ACTION: start
# ==============================================================================
Assert-Command "vastai" "Run: pip install vastai  then: vastai set api-key <your-key>"
Assert-Command "ssh"    "OpenSSH not found. Install via: Settings -> Optional features -> OpenSSH Client"
Assert-Command "scp"    "scp not found. Install OpenSSH Client from Windows Optional Features."

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CartoonAutomation - Start Vast.ai Session" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Validate SSH key exists
if (-not (Test-Path $SshKeyPath)) {
    Write-Host "ERROR: SSH private key not found at: $SshKeyPath" -ForegroundColor Red
    Write-Host "Pass the correct path with: -SshKeyPath `"C:\path\to\your\key`"" -ForegroundColor Yellow
    Write-Host "Example (if you used vastKeys name): -SshKeyPath `"$env:USERPROFILE\vastKeys`"" -ForegroundColor Yellow
    exit 1
}
Write-Host "  SSH key    : $SshKeyPath"
Write-Host "  .env file  : $ENV_FILE"
Write-Host "  Backend    : $VideoBackend"
Write-Host ""

# ── Step 1: Search for cheapest RTX 4090 ──────────────────────────────────────
Write-Host "Step 1/6: Finding cheapest available RTX 4090 ..." -ForegroundColor Yellow
$query = "num_gpus=1 gpu_name=RTX_4090 disk_space>=$DiskGB inet_down>=$MinDownMbps verified=True"
$offers = vastai search offers $query -o "dph_total asc" --raw 2>&1 | ConvertFrom-Json

if (-not $offers -or $offers.Count -eq 0) {
    Write-Host "No RTX 4090 offers found. Trying with relaxed filters ..." -ForegroundColor Yellow
    $query = "num_gpus=1 gpu_name=RTX_4090 disk_space>=60 verified=True"
    $offers = vastai search offers $query -o "dph_total asc" --raw 2>&1 | ConvertFrom-Json
}

if (-not $offers -or $offers.Count -eq 0) {
    Write-Host "ERROR: No RTX 4090 available right now. Try again in a few minutes or use Vast.ai UI." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  Top 5 cheapest RTX 4090 options:" -ForegroundColor Green
Write-Host ("{0,-12} {1,-10} {2,-8} {3,-10} {4}" -f "Offer ID", "USD/hr", "Disk", "Speed", "INR/hr")
Write-Host ("-" * 58)
$offers | Select-Object -First 5 | ForEach-Object {
    $dph  = [math]::Round($_.dph_total, 4)
    $inr  = [math]::Round($dph * 85, 1)
    $disk = [int]$_.disk_space
    $down = [int]$_.inet_down
    Write-Host ("{0,-12} `${1,-9} {2,-8} {3,-10} Rs.{4}/hr" -f $_.id, $dph, "${disk}GB", "${down}Mbps", $inr)
}

Write-Host ""
$selectedId = Read-Host "Enter offer ID to rent (press Enter to use cheapest: $($offers[0].id))"
if ([string]::IsNullOrWhiteSpace($selectedId)) {
    $selectedId = $offers[0].id
}
$selectedOffer = $offers | Where-Object { $_.id -eq $selectedId } | Select-Object -First 1
if (-not $selectedOffer) { $selectedOffer = $offers[0] }

$dphSelected = $selectedOffer.dph_total
Write-Host ""
Write-Host "  Selected offer $selectedId at `$$([math]::Round($dphSelected,4))/hr (Rs.$([math]::Round($dphSelected*85,1))/hr)" -ForegroundColor Green

# ── Step 2: Rent the instance ──────────────────────────────────────────────────
Write-Host ""
Write-Host "Step 2/6: Renting instance ..." -ForegroundColor Yellow

$createResult = vastai create instance $selectedId `
    --image "pytorch/pytorch:2.4.0-cuda12.4-cudnn9-devel" `
    --disk $DiskGB `
    --raw 2>&1 | ConvertFrom-Json

if (-not $createResult -or -not $createResult.success) {
    Write-Host "ERROR: Failed to create instance." -ForegroundColor Red
    Write-Host ($createResult | ConvertTo-Json)
    exit 1
}
$INSTANCE_ID = $createResult.new_contract
Write-Host "  Instance created: $INSTANCE_ID" -ForegroundColor Green

# Save session metadata immediately
$meta = @{
    instance_id = $INSTANCE_ID
    start_time  = (Get-Date -Format "o")
    dph_total   = $dphSelected
    offer_id    = $selectedId
    backend     = $VideoBackend
}
$meta | ConvertTo-Json | Set-Content $META_FILE
$INSTANCE_ID | Set-Content $ID_FILE

# ── Step 3: Wait for instance to be running ────────────────────────────────────
Write-Host ""
Write-Host "Step 3/6: Waiting for instance to start (usually 1-3 min) ..." -ForegroundColor Yellow

$attempts = 0
$instance = $null
do {
    Start-Sleep -Seconds 15
    $attempts++
    $allInstances = vastai show instances --raw 2>&1 | ConvertFrom-Json
    $instance = $allInstances | Where-Object { $_.id -eq $INSTANCE_ID }
    $status = if ($instance) { $instance.actual_status } else { "pending" }
    Write-Host "  [$attempts] status: $status"
} while ($status -ne "running" -and $attempts -lt 24)

if ($status -ne "running") {
    Write-Host "ERROR: Instance did not reach 'running' state after 6 min." -ForegroundColor Red
    Write-Host "Check cloud.vast.ai/instances/ — instance ID: $INSTANCE_ID" -ForegroundColor Yellow
    exit 1
}

$sshHost = $instance.ssh_host
$sshPort = $instance.ssh_port
$pubIp   = $instance.public_ipaddr

Write-Host "  Instance is running!" -ForegroundColor Green
Write-Host "  SSH: ssh -p $sshPort root@$sshHost"
Write-Host "  Public IP: $pubIp"

# Give SSH daemon a moment to be fully ready
Start-Sleep -Seconds 10

# ── Step 4: Upload server files ───────────────────────────────────────────────
Write-Host ""
Write-Host "Step 4/6: Uploading server files ..." -ForegroundColor Yellow

foreach ($file in $SERVER_FILES) {
    if (Test-Path $file) {
        $fname = Split-Path $file -Leaf
        Write-Host "  Uploading $fname ..."
        Copy-FileToHost $sshPort $sshHost $SshKeyPath $file "/workspace/$fname"
    } else {
        Write-Host "  WARNING: $file not found, skipping." -ForegroundColor Yellow
    }
}
Write-Host "  Files uploaded." -ForegroundColor Green

# ── Step 5: Run setup on the pod (non-interactive) ────────────────────────────
Write-Host ""
Write-Host "Step 5/6: Running pod setup (10-15 min — installing packages) ..." -ForegroundColor Yellow
Write-Host "  This runs once per new pod. Coffee time." -ForegroundColor Gray

# NONINTERACTIVE=1 tells setup_pod.sh to skip the Y/N model download prompts
# and answer 'n' automatically (model downloads on first request instead).
Invoke-SshCommand $sshPort $sshHost $SshKeyPath `
    "chmod +x /workspace/setup_pod.sh && NONINTERACTIVE=1 bash /workspace/setup_pod.sh"

Write-Host "  Setup complete." -ForegroundColor Green

# ── Start the video server ────────────────────────────────────────────────────
Write-Host ""
Write-Host "Step 6/6: Starting $VideoBackend server on the pod ..." -ForegroundColor Yellow

$serverScript = if ($VideoBackend -eq "hunyuan") { "start_hunyuan.sh" } else { "start_wan22.sh" }
$serverPort   = if ($VideoBackend -eq "hunyuan") { 8000 } else { 8001 }

# Start server in background via nohup
Invoke-SshCommand $sshPort $sshHost $SshKeyPath `
    "nohup bash /workspace/$serverScript > /workspace/server_start.log 2>&1 &"

Write-Host "  Server starting (model loads on first request, not at startup) ..." -ForegroundColor Gray
Start-Sleep -Seconds 5

# Verify process is running
$psCheck = Invoke-SshCommand $sshPort $sshHost $SshKeyPath "pgrep -f uvicorn && echo RUNNING || echo NOT_RUNNING"
if ($psCheck -match "RUNNING") {
    Write-Host "  Server process running on pod." -ForegroundColor Green
} else {
    Write-Host "  WARNING: Server process not detected. Check pod logs:" -ForegroundColor Yellow
    Write-Host "    ssh -p $sshPort root@$sshHost 'cat /workspace/server_start.log'" -ForegroundColor Gray
}

# ── Update .env ───────────────────────────────────────────────────────────────
$apiUrl = "http://${pubIp}:${serverPort}/generate"

Write-Host ""
Write-Host "Updating .env ..." -ForegroundColor Yellow
Update-EnvVar "ANIMATION_BACKEND" $VideoBackend
Update-EnvVar "HUNYUAN_API_URL"  $(if ($VideoBackend -eq "hunyuan") { $apiUrl } else { "" })
Update-EnvVar "WAN22_API_URL"    $(if ($VideoBackend -eq "wan22") { $apiUrl } else { "" })

# Save public IP to meta
$meta.public_ip = $pubIp
$meta.api_url   = $apiUrl
$meta.ssh_host  = $sshHost
$meta.ssh_port  = $sshPort
$meta | ConvertTo-Json | Set-Content $META_FILE

# ── Print summary ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  SESSION READY" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Instance ID    : $INSTANCE_ID"
Write-Host "  Public IP      : $pubIp"
Write-Host "  Video server   : $apiUrl"
Write-Host "  SSH access     : ssh -p $sshPort -i $SshKeyPath root@$sshHost"
Write-Host "  Cost rate      : `$$([math]::Round($dphSelected,4))/hr (Rs.$([math]::Round($dphSelected*85,1))/hr)"
Write-Host ""
Write-Host "  .env has been updated automatically." -ForegroundColor Green
Write-Host "  You can now run: cartoon_automation" -ForegroundColor Green
Write-Host ""
Write-Host "  IMPORTANT: When done, stop the session to avoid ongoing charges:" -ForegroundColor Yellow
Write-Host "    .\vast_session.ps1 -Action stop" -ForegroundColor Cyan
Write-Host ""
Write-Host "  For LoRA training on this pod, SSH in and run:" -ForegroundColor Gray
Write-Host "    ssh -p $sshPort -i $SshKeyPath root@$sshHost" -ForegroundColor Gray
Write-Host "    pkill uvicorn  # stop video server first to free VRAM" -ForegroundColor Gray
Write-Host "    # pipeline will call kohya_ss automatically if LORA_TRAINING_BACKEND=local_kohya" -ForegroundColor Gray
