# portproxy.ps1 — Idempotent netsh portproxy setup for Techbleat Global Bank.
# Forwards Windows ports 80/443 to the WSL2 ingress port-forward (8080/8443).
# Must run as Administrator (Task Scheduler or right-click → Run as Administrator).
#
# To register as a startup task (run once as Admin):
#   Register-ScheduledTask -TaskName "TechbleatPortProxy" `
#     -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
#     -Action (New-ScheduledTaskAction -Execute "powershell.exe" `
#       -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"C:\Users\EAGLESOLUTIONS\Documents\AI_BANKING_APP\sre2026-final-project\k8s\scripts\portproxy.ps1`"") `
#     -RunLevel Highest `
#     -Force

$rules = @(
    @{ ListenPort = 80;  ConnectPort = 8080 },
    @{ ListenPort = 443; ConnectPort = 8443 }
)

foreach ($r in $rules) {
    $existing = netsh interface portproxy show v4tov4 |
        Select-String "127\.0\.0\.1\s+$($r.ListenPort)\s+127\.0\.0\.1\s+$($r.ConnectPort)"
    if ($existing) {
        Write-Host "[portproxy] Rule $($r.ListenPort)->$($r.ConnectPort) already exists — skipping."
    } else {
        netsh interface portproxy add v4tov4 `
            listenport=$($r.ListenPort) listenaddress=127.0.0.1 `
            connectport=$($r.ConnectPort) connectaddress=127.0.0.1
        Write-Host "[portproxy] Added rule: 127.0.0.1:$($r.ListenPort) -> 127.0.0.1:$($r.ConnectPort)"
    }
}

Write-Host "[portproxy] Done. Active rules:"
netsh interface portproxy show v4tov4
