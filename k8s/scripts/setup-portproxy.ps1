# setup-portproxy.ps1 — Restore Windows port proxy after a system reboot.
# Run in PowerShell as Administrator.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File k8s\scripts\setup-portproxy.ps1
#
# What this does:
#   Routes Windows ports 80/443 → minikube node ports 8080/8443
#   so that https://banking-app.eaglesoncloude.com and https://auth.eaglesoncloude.com
#   reach the nginx ingress controller inside the minikube cluster.

param(
    [string]$Profile = "techbleat-bank"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=========================================="
Write-Host "  Techbleat Bank — Windows Port Proxy"
Write-Host "=========================================="
Write-Host ""

# Check for Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell and choose 'Run as administrator'." -ForegroundColor Yellow
    exit 1
}

# Get minikube IP from WSL2
Write-Host "[1/3] Getting minikube IP (profile: $Profile)..."
try {
    $minikubeIp = (wsl minikube ip --profile $Profile 2>$null).Trim()
    if ([string]::IsNullOrEmpty($minikubeIp)) {
        throw "Empty IP returned"
    }
    Write-Host "      Minikube IP: $minikubeIp" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Could not get minikube IP. Is minikube running?" -ForegroundColor Red
    Write-Host "Run this first in WSL2: bash k8s/scripts/start-cluster.sh" -ForegroundColor Yellow
    exit 1
}

# Remove existing port proxy entries (clean slate)
Write-Host ""
Write-Host "[2/3] Removing old port proxy entries..."
$null = netsh interface portproxy delete v4tov4 listenport=80  listenaddress=0.0.0.0 2>$null
$null = netsh interface portproxy delete v4tov4 listenport=443 listenaddress=0.0.0.0 2>$null
Write-Host "      Old entries removed."

# Add new entries pointing to current minikube IP
Write-Host ""
Write-Host "[3/3] Adding port proxy entries..."
netsh interface portproxy add v4tov4 listenport=80  listenaddress=0.0.0.0 connectport=8080 connectaddress=$minikubeIp
netsh interface portproxy add v4tov4 listenport=443 listenaddress=0.0.0.0 connectport=8443 connectaddress=$minikubeIp
Write-Host "      Port proxy configured." -ForegroundColor Green

# Show current state
Write-Host ""
Write-Host "Current port proxy rules:"
netsh interface portproxy show v4tov4

Write-Host ""
Write-Host "=========================================="
Write-Host "  Done!" -ForegroundColor Green
Write-Host "=========================================="
Write-Host ""
Write-Host "Port 80  → $minikubeIp`:8080  (HTTP ingress)"
Write-Host "Port 443 → $minikubeIp`:8443  (HTTPS ingress)"
Write-Host ""
Write-Host "Test:"
Write-Host "  https://banking-app.eaglesoncloude.com"
Write-Host "  https://auth.eaglesoncloude.com"
Write-Host ""
