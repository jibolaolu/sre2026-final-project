# startup-windows.ps1 — Auto-start Techbleat Global Bank on Windows login.
#
# Registered as a Task Scheduler task (see SETUP below).
# Runs as the current user (for WSL2) + elevated sub-process (for netsh portproxy).
#
# ── SETUP (run once in an elevated PowerShell) ───────────────────────────────
#
#   $scriptPath = "C:\Users\EAGLESOLUTIONS\Documents\AI_BANKING_APP\sre2026-final-project\k8s\scripts\startup-windows.ps1"
#
#   Register-ScheduledTask -TaskName "TechbleatBankStartup" `
#     -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
#     -Action (New-ScheduledTaskAction `
#       -Execute "powershell.exe" `
#       -Argument "-NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"") `
#     -RunLevel Highest `
#     -Force
#
# ── UNREGISTER ───────────────────────────────────────────────────────────────
#   Unregister-ScheduledTask -TaskName "TechbleatBankStartup" -Confirm:$false
#
# ─────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = "Continue"

$REPO = "C:\Users\EAGLESOLUTIONS\Documents\AI_BANKING_APP\sre2026-final-project"
$LOG  = "C:\Users\EAGLESOLUTIONS\AppData\Local\Temp\techbleat-startup.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $msg" | Tee-Object -FilePath $LOG -Append | Write-Host
}

Log "=== Techbleat Bank startup ==="

# ── 1. netsh portproxy (needs elevation, already running elevated via Task Scheduler) ──
Log "Setting up netsh portproxy rules..."
& "$REPO\k8s\scripts\portproxy.ps1" 2>&1 | ForEach-Object { Log $_ }

# ── 2. Wait a moment for Docker Desktop / WSL2 to be ready ───────────────────
Log "Waiting 30 s for Docker Desktop and WSL2 to finish initialising..."
Start-Sleep -Seconds 30

# ── 3. Launch recovery.sh in WSL2 ────────────────────────────────────────────
Log "Launching recovery.sh in WSL2..."
$wsl = "C:\Windows\System32\wsl.exe"
if (Test-Path $wsl) {
    $startupPath = "/mnt/c/Users/EAGLESOLUTIONS/Documents/AI_BANKING_APP/sre2026-final-project/k8s/scripts/startup.sh"
    Start-Process -FilePath $wsl `
        -ArgumentList "-d", "Ubuntu", "--", "bash", $startupPath, "--skip-build" `
        -NoNewWindow `
        -Wait
    Log "recovery.sh completed."
} else {
    Log "ERROR: wsl.exe not found at $wsl"
}

Log "=== Startup complete. Log: $LOG ==="
