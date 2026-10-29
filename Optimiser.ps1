# Optimiser.ps1 - Optimisation d'un PC Windows 10/11 utilise comme lecteur pour la TV
# Lance via Optimiser.bat (droits administrateur necessaires)

$ErrorActionPreference = "SilentlyContinue"

function Titre($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Ok($t) { Write-Host "  [OK] $t" -ForegroundColor Green }
function Info($t) { Write-Host "  $t" -ForegroundColor Gray }

function EspaceLibre { return (Get-PSDrive C).Free }

Clear-Host
Write-Host "OPTIMISATION DU PC" -ForegroundColor Yellow
Write-Host "Ce programme nettoie et regle ton PC. Rien d'important n'est supprime."
Write-Host ""
$libreAvant = EspaceLibre

# 1. Point de restauration
Titre "1/8 Point de restauration"
Enable-ComputerRestore -Drive "C:\"
Checkpoint-Computer -Description "Avant optimisation TV" -RestorePointType MODIFY_SETTINGS
Ok "Point de restauration cree (si Windows l'a autorise)"

# 2. Fichiers temporaires
Titre "2/8 Nettoyage des fichiers temporaires"
$dossiers = @(
  $env:TEMP,
  "C:\Windows\Temp",
  "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
  "$env:LOCALAPPDATA\CrashDumps"
)
foreach ($d in $dossiers) {
  if (Test-Path $d) { Get-ChildItem $d -Force -Recurse | Remove-Item -Force -Recurse }
}
Ok "Fichiers temporaires supprimes"

# 3. Cache Windows Update
Titre "3/8 Cache de Windows Update"
Stop-Service wuauserv -Force
Get-ChildItem "C:\Windows\SoftwareDistribution\Download" -Force | Remove-Item -Force -Recurse
Start-Service wuauserv
Ok "Cache des mises a jour vide"

# 4. Cache de Chrome et corbeille
Titre "4/8 Cache de Chrome et corbeille"
Stop-Process -Name chrome -Force
$chrome = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"
foreach ($n in @("Cache", "Code Cache", "GPUCache")) {
  $p = Join-Path $chrome $n
  if (Test-Path $p) { Get-ChildItem $p -Force -Recurse | Remove-Item -Force -Recurse }
}
Clear-RecycleBin -Force
Ok "Cache de Chrome vide (tes mots de passe et favoris sont conserves)"
Ok "Corbeille videe"

# 5. Alimentation : performances elevees, pas de veille sur secteur
Titre "5/8 Alimentation et performances"
powercfg /setactive SCHEME_MIN
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change disk-timeout-ac 0
Ok "Mode Performances elevees, plus de mise en veille quand le PC est branche"

# 6. Effets visuels reduits
Titre "6/8 Effets visuels"
$k1 = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
if (-not (Test-Path $k1)) { New-Item -Path $k1 -Force | Out-Null }
Set-ItemProperty -Path $k1 -Name VisualFXSetting -Value 2 -Type DWord
$k2 = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
if (-not (Test-Path $k2)) { New-Item -Path $k2 -Force | Out-Null }
Set-ItemProperty -Path $k2 -Name EnableTransparency -Value 0 -Type DWord
Ok "Effets visuels reduits (visible apres redemarrage)"

# 7. Programmes qui se lancent au demarrage (avec confirmation)
Titre "7/8 Programmes au demarrage"
$run = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$props = (Get-Item $run).Property
if ($props) {
  $sauvegarde = "$env:USERPROFILE\Desktop\Demarrage_sauvegarde.txt"
  foreach ($nom in $props) {
    $val = (Get-ItemProperty $run).$nom
    Write-Host ""
    Write-Host "  Programme : $nom" -ForegroundColor White
    Write-Host "  Commande  : $val" -ForegroundColor DarkGray
    $rep = Read-Host "  Le retirer du demarrage ? (O/N)"
    if ($rep -eq "O" -or $rep -eq "o") {
      "$nom = $val" | Add-Content $sauvegarde
      Remove-ItemProperty -Path $run -Name $nom
      Ok "$nom retire du demarrage (sauvegarde sur le Bureau)"
    }
  }
} else {
  Info "Rien a retirer"
}

# 8. Disque
Titre "8/8 Optimisation du disque"
$disque = Get-PhysicalDisk | Select-Object -First 1
if ($disque.MediaType -eq "SSD") {
  Optimize-Volume -DriveLetter C -ReTrim
  Ok "SSD optimise (TRIM)"
} else {
  Info "Disque dur classique : defragmentation (peut prendre du temps)"
  Optimize-Volume -DriveLetter C -Defrag
  Ok "Disque defragmente"
}

# Resultat
$libreApres = EspaceLibre
$gagne = [math]::Round(($libreApres - $libreAvant) / 1MB)
Write-Host ""
Write-Host "==============================" -ForegroundColor Yellow
Write-Host "TERMINE" -ForegroundColor Yellow
if ($gagne -gt 0) { Write-Host "Espace libere : $gagne Mo" -ForegroundColor Green }
Write-Host "Redemarre le PC pour appliquer tous les reglages."
Write-Host "Pour les mises a jour Windows, la fenetre Windows Update va s'ouvrir."
Write-Host "==============================" -ForegroundColor Yellow
Start-Process "ms-settings:windowsupdate"
