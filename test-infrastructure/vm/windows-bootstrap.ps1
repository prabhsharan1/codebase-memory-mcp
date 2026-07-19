# windows-bootstrap.ps1 — ONE-TIME setup inside the Windows test VM.
#
# Everything else (msys2, toolchains, repo, builds) is provisioned FROM THE
# HOST over ssh by provision-windows.sh — this script only opens that door.
#
# Getting this file into a fresh VM (clipboard/shared folders are unreliable
# on Windows-ARM guests — the SPICE agent services do not exist there): build
# a small ISO on the host and mount it via UTM's CD drive:
#   mkdir /tmp/cbmiso && cp windows-bootstrap.ps1 /tmp/cbmiso/
#   printf '@echo off\r\npowershell -NoProfile -ExecutionPolicy Bypass -File "%%~dp0windows-bootstrap.ps1"\r\n' > /tmp/cbmiso/RUN-ME.bat
#   hdiutil makehybrid -iso -joliet -default-volume-name CBMSETUP -o ~/cbm-setup.iso /tmp/cbmiso
# Then in the VM: open the CD drive in Explorer and double-click RUN-ME.bat.
#
# Requires: SPICE guest tools already installed (network driver working).

# Self-elevate so double-clicking RUN-ME.bat just works.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}
$ErrorActionPreference = "Stop"

Write-Host "=== 1/4: OpenSSH server ===" -ForegroundColor Cyan
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
New-NetFirewallRule -Name cbm-sshd -DisplayName "OpenSSH (cbm test VM)" `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
    -ErrorAction SilentlyContinue | Out-Null

Write-Host "=== 2/4: authorize the driving host's key ===" -ForegroundColor Cyan
# Public key of the driving host (~/.claude/cbm-vm/id_ed25519.pub there).
# If the host key pair is ever lost, regenerate and replace this line:
#   ssh-keygen -t ed25519 -N "" -C claude-cbm-vm -f ~/.claude/cbm-vm/id_ed25519
$k = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHTM/DHf7YldxSfSH5/WengKm/k1mYkPry9mBjZ8SRzG claude-cbm-vm'
$f = 'C:\ProgramData\ssh\administrators_authorized_keys'
if (-not (Test-Path $f)) { New-Item -ItemType File -Path $f -Force | Out-Null }
if (-not (Select-String -Path $f -Pattern 'claude-cbm-vm' -Quiet)) { Add-Content -Path $f -Value $k }
icacls $f /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

Write-Host "=== 3/4: mirror the GitHub-runner default-owner policy ===" -ForegroundColor Cyan
# 'System objects: Default owner for objects created by members of the
# Administrators group' = Administrators. Windows CLIENT editions default new
# objects to the user SID; GitHub's SERVER runners default them to BUILTIN\
# Administrators — the class every exact-owner validation must survive.
# Mirroring it here makes CI-only ownership refusals reproduce in this VM.
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
    -Name NoDefaultAdminOwner -Value 0 -Type DWord

Write-Host "=== 4/4: report ===" -ForegroundColor Cyan
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object -First 1).IPAddress
Write-Host ""
Write-Host "==================== SSH READY ====================" -ForegroundColor Green
Write-Host ("  user: " + $env:USERNAME) -ForegroundColor Yellow
Write-Host ("  ip:   " + $ip) -ForegroundColor Yellow
Write-Host "===================================================" -ForegroundColor Green
Write-Host "On the host, write ~/.claude/cbm-vm/config with:"
Write-Host "  CBM_VM_HOST=$ip"
Write-Host ("  CBM_VM_USER=" + $env:USERNAME)
Write-Host "Then run: test-infrastructure/vm/provision-windows.sh"
Write-Host "NOTE: reboot once so the default-owner policy applies."
Read-Host 'Press Enter to close'
