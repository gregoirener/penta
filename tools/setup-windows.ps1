# PENTA one-shot Windows prep.
#
#   Run in an ADMIN PowerShell:
#     irm http://192.168.68.100:8000/setup.ps1 | iex
#
# What it does, in order:
#   1. Downloads the Arch ISO and the PENTA image to C:\
#   2. Extracts the Arch kernel + initramfs out of the ISO
#   3. Copies them and systemd-boot onto the EFI partition
#   4. Adds a boot entry that loads Arch entirely into RAM
#
# It is ADDITIVE ONLY. It never edits or deletes an existing boot entry, backs
# up your boot configuration first, and refuses to continue if the Windows
# bootloader is not where it expects. Nothing here erases anything; the actual
# install happens later, from Linux.
#
# To undo everything: bcdedit /delete {the-guid-printed-at-the-end}
#                     and delete S:\EFI\arch  (mountvol S: /S first)

$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "!!  $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# --- Preflight ----------------------------------------------------------------

if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "Run this in an Administrator PowerShell (right-click > Run as administrator)."
}

$serverIp   = '192.168.68.100'
$isoUrl     = 'https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso'
$isoPath    = 'C:\archlinux.iso'
$imgUrl     = "http://$serverIp`:8000/penta.img.zst"
$imgPath    = 'C:\penta.img.zst'

Say "PENTA setup — nothing is erased by this script"
Write-Host ""

# Free space: ISO ~1.3G + image ~0.5G, plus headroom.
$freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
Say "C: has $freeGB GB free"
if ($freeGB -lt 4) { Die "Need at least 4 GB free on C:. Free some space and re-run." }

# --- 1. Downloads -------------------------------------------------------------

# -C - resumes a partial file instead of starting over, and --retry rides out
# a flaky link. Re-running this script after a drop picks up where it stopped.
$curlArgs = @(
    '-L', '--fail', '--continue-at', '-',
    '--retry', '10', '--retry-delay', '3', '--retry-all-errors',
    '--connect-timeout', '20'
)

Say "Downloading Arch ISO (~1.3 GB — the long one; resumes if it drops)"
curl.exe @curlArgs -o $isoPath $isoUrl
if ($LASTEXITCODE -ne 0) { Die "Arch ISO download failed. Just re-run this script — it resumes." }

Say "Downloading the PENTA image (~0.5 GB; resumes if it drops)"
curl.exe @curlArgs -o $imgPath $imgUrl
if ($LASTEXITCODE -ne 0) {
    Die "Could not fetch the PENTA image. Re-run to resume, or check the URL is reachable."
}

$imgSize = [math]::Round((Get-Item $imgPath).Length / 1MB)
Say "Image downloaded: $imgSize MB"
if ($imgSize -lt 300) { Die "Image looks truncated ($imgSize MB). Re-run." }

# --- 2. Which partition holds C:? ---------------------------------------------
# The live system needs to be told where to find the ISO. Rather than guess, we
# generate an entry per plausible partition and you pick at the boot menu.

$cPart = (Get-Partition -DriveLetter C)
$cNum  = $cPart.PartitionNumber
Say "C: is partition $cNum on disk $($cPart.DiskNumber)"

# --- 3. Pull kernel + initramfs out of the ISO --------------------------------

Say "Mounting the ISO"
$mounted = Mount-DiskImage -ImagePath $isoPath -PassThru
Start-Sleep -Seconds 2
$isoDrive = ($mounted | Get-Volume).DriveLetter
if (-not $isoDrive) { Die "Could not mount the ISO." }
Say "ISO mounted at ${isoDrive}:"

try {
    $kernel = "${isoDrive}:\arch\boot\x86_64\vmlinuz-linux"
    $initrd = "${isoDrive}:\arch\boot\x86_64\initramfs-linux.img"
    $sdboot = "${isoDrive}:\EFI\BOOT\BOOTx64.EFI"
    foreach ($f in @($kernel, $initrd, $sdboot)) {
        if (-not (Test-Path $f)) { Die "Not found in the ISO: $f" }
    }

    # --- 4. EFI partition -----------------------------------------------------

    Say "Mounting the EFI partition as S:"
    if (Test-Path 'S:\') { mountvol S: /D 2>$null }
    mountvol S: /S
    Start-Sleep -Seconds 1
    if (-not (Test-Path 'S:\EFI\Microsoft\Boot\bootmgfw.efi')) {
        mountvol S: /D 2>$null
        Die "That does not look like your EFI partition (no Windows bootloader). Stopping before touching anything."
    }
    Say "Windows bootloader present — safe to add alongside it"

    # A Windows ESP is typically 100 MB with ~30 MB free. The Arch initramfs
    # alone is ~130 MB, so systemd-boot (which can only read the ESP) is simply
    # not an option here. Check before copying rather than failing halfway and
    # leaving a half-written boot directory behind.
    $espFreeMB = [math]::Round((Get-PSDrive S).Free / 1MB)
    $needMB    = [math]::Round(((Get-Item $kernel).Length + (Get-Item $initrd).Length) / 1MB) + 10
    Say "EFI partition: $espFreeMB MB free, need $needMB MB"
    if ($espFreeMB -lt $needMB) {
        mountvol S: /D 2>$null
        Warn "Your EFI partition is too small for this method."
        Warn ""
        Warn "Use GRUB2Win instead: GRUB reads NTFS, so the kernel and initrd"
        Warn "stay on C:\ and only a few MB of bootloader goes on the ESP."
        Warn "  1. Install from sourceforge.net/projects/grub2win"
        Warn "  2. Manage Boot Menu > Add entry > Custom code, name it 'Arch RAM'"
        Warn "  3. Paste the grub stanza (ask for it, or see docs/INSTALL-NO-USB.md)"
        Warn ""
        Say  "Your downloads are done and still valid:"
        Say  "  C:\archlinux.iso  and  C:\penta.img.zst"
        exit 0
    }

    New-Item -ItemType Directory -Force -Path 'S:\EFI\arch' | Out-Null
    New-Item -ItemType Directory -Force -Path 'S:\loader\entries' | Out-Null

    Say "Copying kernel, initramfs and systemd-boot to the EFI partition"
    Copy-Item $kernel 'S:\EFI\arch\vmlinuz-linux'        -Force
    Copy-Item $initrd 'S:\EFI\arch\initramfs-linux.img'  -Force
    Copy-Item $sdboot 'S:\EFI\arch\systemd-bootx64.efi'  -Force

    # copytoram=y is the load-bearing part: it pulls the whole live system into
    # memory so the disk it came from can later be overwritten out from under it.
    Say "Writing boot entries"
    foreach ($p in @($cNum, 3, 4, 2)) {
        $name = "arch-p$p"
        if (Test-Path "S:\loader\entries\$name.conf") { continue }
        @(
            "title   Arch RAM (ISO on partition $p)"
            "linux   /EFI/arch/vmlinuz-linux"
            "initrd  /EFI/arch/initramfs-linux.img"
            "options img_dev=/dev/nvme0n1p$p img_loop=/archlinux.iso copytoram=y earlymodules=loop"
        ) -join "`n" | Out-File -Encoding ascii -NoNewline "S:\loader\entries\$name.conf"
    }
    @(
        "default arch-p$cNum"
        "timeout 10"
        "console-mode max"
    ) -join "`n" | Out-File -Encoding ascii -NoNewline 'S:\loader\loader.conf'

    # --- 5. Firmware boot entry ----------------------------------------------

    Say "Backing up boot configuration to C:\bcd-backup"
    bcdedit /export C:\bcd-backup | Out-Null

    Say "Adding a firmware boot entry (existing entries untouched)"
    $out  = bcdedit /copy '{bootmgr}' /d 'PENTA installer (Arch RAM)'
    $guid = [regex]::Match($out, '\{[0-9a-fA-F-]+\}').Value
    if (-not $guid) { Die "Could not create the boot entry. Your existing setup is unchanged." }

    bcdedit /set $guid path \EFI\arch\systemd-bootx64.efi | Out-Null
    bcdedit /set '{fwbootmgr}' displayorder $guid /addlast  | Out-Null

    Write-Host ""
    Say "Done. Nothing has been erased."
    Write-Host ""
    Write-Host "  Boot entry : PENTA installer (Arch RAM)"
    Write-Host "  GUID       : $guid"
    Write-Host "  Files      : C:\archlinux.iso, C:\penta.img.zst"
    Write-Host ""
    Write-Host "  NEXT:" -ForegroundColor Green
    Write-Host "   1. BIOS (F2): Supervisor Password, Secure Boot OFF, F12 menu ON"
    Write-Host "   2. Reboot, tap F12, choose 'PENTA installer'"
    Write-Host "   3. At the Arch prompt, follow the flash steps"
    Write-Host ""
    Write-Host "  To undo: bcdedit /delete $guid" -ForegroundColor DarkGray
    Write-Host ""
}
finally {
    if (Test-Path 'S:\') { mountvol S: /D 2>$null }
    Dismount-DiskImage -ImagePath $isoPath | Out-Null
}
