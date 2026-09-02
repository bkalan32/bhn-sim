# ============================================================================
#  bhn-sim Day 1 — WINDOWS SIDE ONLY
#  Run this in PowerShell (as Administrator for the WSL install step).
#  Everything else in the lab runs inside Ubuntu, not here.
# ============================================================================

Write-Host "== 1. Install WSL2 + Ubuntu ==" -ForegroundColor Green
# Skip if `wsl -l -v` already lists an Ubuntu distro at version 2.
# Requires a REBOOT afterwards, and virtualization enabled in BIOS/UEFI.
#   wsl --install -d Ubuntu-24.04
#   wsl --set-default-version 2

Write-Host "== 2. Cap what WSL2 may consume ==" -ForegroundColor Green
# Docker Desktop's WSL2 backend has NO memory slider. This file is the equivalent.
$wslconfig = "$env:USERPROFILE\.wslconfig"
if (-not (Test-Path $wslconfig)) {
@"
[wsl2]
memory=10GB
processors=4
swap=2GB
"@ | Set-Content -Path $wslconfig -Encoding ASCII
    Write-Host "  wrote $wslconfig  (run 'wsl --shutdown' to apply)"
} else {
    Write-Host "  $wslconfig already exists - leaving it alone:"
    Get-Content $wslconfig | ForEach-Object { Write-Host "    $_" }
}

Write-Host "== 3. Install the Windows-side applications ==" -ForegroundColor Green
winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
winget install -e --id Anysphere.Cursor    --accept-source-agreements --accept-package-agreements
winget install -e --id Git.Git             --accept-source-agreements --accept-package-agreements

Write-Host ""
Write-Host "== 4. MANUAL STEP - do not skip ==" -ForegroundColor Yellow
Write-Host "  Open Docker Desktop"
Write-Host "  Settings > Resources > WSL Integration"
Write-Host "  Toggle ON your Ubuntu distro, then Apply & Restart."
Write-Host ""
Write-Host "  Without this, 'docker ps' inside Ubuntu fails with"
Write-Host "  'Cannot connect to the Docker daemon' even though Docker is running."
Write-Host ""
Write-Host "Then open Ubuntu and run:  cd ~/bhn-sim && ./scripts/00-preflight.sh" -ForegroundColor Green
