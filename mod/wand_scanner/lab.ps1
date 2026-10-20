# Lab session: back up your saves, run Noita with lab settings, then put everything back.
# Started by lab.bat (`lab.bat calibrate` also runs the calibration lab; no argument = plain dry run). If a session is cut short (crash, closed window), the next start restores first.
param([string]$Mode = "")
$ErrorActionPreference = "Stop"
$Noita   = (Resolve-Path "$PSScriptRoot\..\..").Path
$Saves   = "$env:USERPROFILE\AppData\LocalLow\Nolla_Games_Noita"
$Backups = "D:\NoitaBackups"
$Marker  = "$Backups\LAB_ACTIVE.txt" # holds the backup's path while a session runs
$Log     = "$Backups\lab_launcher.log"
New-Item -ItemType Directory -Force $Backups | Out-Null
function Log($m) { "$(Get-Date -Format s)  $m" | Tee-Object -FilePath $Log -Append }

function Restore($zip) {
  Log "restoring saves from $zip"
  Remove-Item -Recurse -Force "$Saves\save00", "$Saves\save_shared" -ErrorAction SilentlyContinue
  Expand-Archive $zip $Saves -Force
  Remove-Item $Marker # only after a successful restore, so a failure retries next time
  Log "restored"
}

if (Get-Process noita, noita_dev -ErrorAction SilentlyContinue) { Log "Noita is running: close it first"; exit 1 }
if (Test-Path $Marker) { Log "previous lab session did not finish"; Restore (Get-Content $Marker) }

$zip = "$Backups\saves_$(Get-Date -Format yyyyMMdd_HHmmss).zip"
Compress-Archive -Path "$Saves\save00", "$Saves\save_shared" -DestinationPath $zip
Set-Content $Marker $zip
Log "backed up save00 and save_shared to $zip"
Get-ChildItem "$Backups\saves_*.zip" | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item

try {
  # Lab settings: keep running when unfocused, and only this mod enabled so others can't skew results.
  $cfg = "$Saves\save_shared\config.xml"
  (Get-Content $cfg -Raw) -replace 'application_pause_when_unfocused="1"', 'application_pause_when_unfocused="0"' |
    Set-Content $cfg -NoNewline
  $mods = "$Saves\save00\mod_config.xml"
  (Get-Content $mods -Raw) -replace '(?<=<Mod enabled=")1(?=" name="(?!wand_scanner"))', '0' |
    Set-Content $mods -NoNewline
  if ($Mode) {
    New-Item -ItemType Directory -Force "$Noita\wand_scanner_data" | Out-Null
    Set-Content "$PSScriptRoot\lab_mode.txt" $Mode # tells the mod to run the lab instead of the panel
  }
  Log "lab settings applied, starting Noita ($(if ($Mode) { $Mode } else { 'dry run' }))"
  Start-Process "$Noita\noita.exe" -WorkingDirectory $Noita -Wait
  Log "Noita closed"
} finally {
  Remove-Item "$PSScriptRoot\lab_mode.txt" -ErrorAction SilentlyContinue
  Restore $zip
}
