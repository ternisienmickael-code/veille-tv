# Tout_En_Un.ps1 - PC Tout-en-Un  |  BY MICKAEL
# Dashboard (vérification virus, mises à jour, nettoyage) + Optimisations à interrupteurs
# Lance via Tout_En_Un.bat (droits administrateur nécessaires)
# Chaque interrupteur est réversible. Le BIOS n'est JAMAIS modifié automatiquement.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------- Relance en administrateur si besoin ----------
$estAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $estAdmin) {
  Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
  exit
}

# =====================================================================
# TRAVAIL EN ARRIERE-PLAN (Dashboard) : tourne dans un autre thread
# =====================================================================
$Work = {
  param($mode)
  $ErrorActionPreference = 'SilentlyContinue'
  $bureau = [Environment]::GetFolderPath('Desktop')
  $script:rapport = @()
  $script:fait = 0
  $script:total = 1
  $script:restaure = $false

  function Ecrire($t, $x) { $sync.Queue.Enqueue([pscustomobject]@{ T = $t; X = $x }) }
  function Titre($x) {
    $sync.Progress = [math]::Min(100, [int](100 * $script:fait / $script:total))
    $script:fait++
    $sync.Statut = $x
    Ecrire 'titre' $x
    $script:rapport += ""; $script:rapport += "=== $x ==="
  }
  function Ligne($x)  { Ecrire 'ligne' "  $x";        $script:rapport += "  $x" }
  function Alerte($x) { Ecrire 'alerte' "  [!] $x";    $script:rapport += "  [!] $x" }
  function Ok($x)     { Ecrire 'ok' "  [OK] $x";       $script:rapport += "  [OK] $x" }
  function Info($x)   { Ecrire 'info' "  $x" }
  function Demander($q, $detail = "") {
    $sync.Event.Reset() | Out-Null
    $sync.Question = @{ Texte = $q; Detail = $detail }
    $sync.Event.WaitOne() | Out-Null
    return $sync.Answer
  }
  function EspaceLibre { return (Get-PSDrive C).Free }

  function PointRestauration($nom) {
    if ($script:restaure) { return }
    Titre "Point de restauration"
    Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description $nom -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue
    $script:restaure = $true
    Ok "Point de restauration créé (si Windows l'a autorisé)"
  }

  function VersJournal {
    process {
      foreach ($l in ($_ | Out-String -Stream)) {
        if ($l -match '[A-Za-z0-9]' -and $l -notmatch '[\u2588\u2592\u2593]') { Info $l.TrimEnd() }
      }
    }
  }

  # ------------------------------------------------------------------
  # VÉRIFICATION APRÈS VIRUS (lecture seule)
  # ------------------------------------------------------------------
  function Verifier {
    $ErrorActionPreference = 'SilentlyContinue'
    $limite = (Get-Date).AddDays(-7)
    $script:rapport = @()

    Titre "Microsoft Defender"
    $etat = Get-MpComputerStatus
    if ($etat) {
      if ($etat.RealTimeProtectionEnabled) { Ok "Protection en temps réel active" } else { Alerte "Protection en temps réel DÉSACTIVÉE (un virus l'a peut-être coupée)" }
      Ligne "Définitions : $($etat.AntivirusSignatureVersion) ($($etat.AntivirusSignatureAge) jour(s))"
    } else {
      Alerte "Impossible de lire l'état de Defender"
    }
    $menaces = Get-MpThreatDetection
    if ($menaces) {
      foreach ($d in $menaces) {
        $m = Get-MpThreat -ThreatID $d.ThreatID
        Alerte "$($m.ThreatName) | $($d.Resources -join ', ') | $($d.InitialDetectionTime)"
      }
    } else {
      Ligne "Aucune détection enregistrée par Defender"
    }

    Titre "Programmes lancés au démarrage"
    $cles = @(
      "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
      "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
      "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
      "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    )
    foreach ($c in $cles) {
      $p = Get-ItemProperty $c
      foreach ($n in ($p.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" })) {
        $v = "$($n.Value)"
        if ($v -match "AppData|Temp|Downloads|ProgramData|Public") { Alerte "$($n.Name) -> $v" } else { Ligne "$($n.Name) -> $v" }
      }
    }
    $dossiersDemarrage = @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp")
    foreach ($d in $dossiersDemarrage) {
      Get-ChildItem $d -Force -File | Where-Object { $_.Name -ne "desktop.ini" } | ForEach-Object { Alerte "Dossier démarrage : $($_.FullName)" }
    }

    Titre "Tâches planifiées (hors Microsoft)"
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike "\Microsoft\*" } | ForEach-Object {
      $actions = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " ; "
      if ($actions -match "AppData|Temp|Downloads|ProgramData|powershell|cmd") { Alerte "$($_.TaskName) -> $actions" } else { Ligne "$($_.TaskName) -> $actions" }
    }

    Titre "Services lancés depuis des dossiers inhabituels"
    $trouve = $false
    Get-CimInstance Win32_Service | Where-Object { $_.PathName -match "AppData|\\Temp\\|Downloads|ProgramData" } | ForEach-Object {
      Alerte "$($_.Name) -> $($_.PathName)"; $trouve = $true
    }
    if (-not $trouve) { Ok "Rien de suspect" }

    Titre "Programmes en cours depuis AppData, Temp ou Téléchargements"
    $trouve = $false
    Get-Process | Where-Object { $_.Path -match "\\AppData\\|\\Temp\\|\\Downloads\\" } | ForEach-Object {
      Alerte "$($_.Name) (PID $($_.Id)) -> $($_.Path)"; $trouve = $true
    }
    if (-not $trouve) { Ok "Rien de suspect" }
    Ligne "(Discord, Brave, Epic... peuvent apparaître normalement dans AppData.)"

    Titre "Programmes créés ces 7 derniers jours"
    $racines = @("$env:USERPROFILE\Downloads", "$env:LOCALAPPDATA", "$env:APPDATA", "$env:TEMP", "C:\ProgramData")
    $compte = 0
    foreach ($r in $racines) {
      Get-ChildItem $r -Recurse -Depth 3 -Force -File | Where-Object { $_.LastWriteTime -gt $limite -and $_.Extension -match "^\.(exe|dll|bat|cmd|ps1|vbs|scr|js)$" } | Select-Object -First 40 | ForEach-Object {
        Ligne "$($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) | $($_.FullName)"; $compte++
      }
    }
    if ($compte -eq 0) { Ok "Aucun" }

    Titre "Fichier hosts (redirections de sites)"
    $hosts = Get-Content "C:\Windows\System32\drivers\etc\hosts" | Where-Object { $_ -notmatch "^\s*#" -and $_.Trim() -ne "" }
    if ($hosts) { foreach ($h in $hosts) { Alerte $h } } else { Ok "Normal (rien d'ajouté)" }

    $chemin = "$bureau\Rapport_infection.txt"
    $script:rapport | Set-Content $chemin
    Ecrire 'fin' "Rapport enregistré sur le Bureau : Rapport_infection.txt"
    Ecrire 'rapport' $chemin
  }

  function ScanHorsLigne {
    if (Demander "Lancer l'analyse Defender HORS LIGNE ?" "Le PC va redémarrer et analyser en profondeur avant le démarrage de Windows. Enregistre ton travail avant.") {
      Update-MpSignature
      Ecrire 'fin' "Redémarrage dans quelques secondes pour l'analyse hors ligne..."
      Start-Sleep -Seconds 5
      Start-MpWDOScan
    }
  }

  # ------------------------------------------------------------------
  # MISES À JOUR
  # ------------------------------------------------------------------
  function MettreAJour {
    $ErrorActionPreference = 'Continue'
    PointRestauration "Avant mises à jour et optimisation"

    Titre "Windows et pilotes (via Windows Update)"
    Info "Installe les mises à jour de Windows et les pilotes proposés par Microsoft."
    if (Demander "Lancer la recherche et l'installation des mises à jour Windows ?" "Garde le PC branché et connecté à internet. Cela peut prendre un moment.") {
      try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
        Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        Import-Module PSWindowsUpdate -ErrorAction Stop
        Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -IgnoreReboot -ErrorAction Stop | VersJournal
        Ok "Mises à jour Windows terminées (un redémarrage peut être nécessaire)"
      } catch {
        Alerte "Échec de l'installation automatique : $($_.Exception.Message)"
        Info "Ouverture de Windows Update : clique sur Rechercher des mises à jour."
        Start-Process "ms-settings:windowsupdate"
      }
    } else {
      Info "Étape ignorée"
    }

    Titre "Applications"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      Info "Applis qui ont une mise à jour :"
      winget upgrade --accept-source-agreements 2>&1 | VersJournal
      if (Demander "Tout mettre à jour ?" "Certaines applis peuvent demander de fermer le programme.") {
        winget upgrade --all --silent --accept-package-agreements --accept-source-agreements 2>&1 | VersJournal
        Ok "Applis mises à jour"
      } else {
        Info "Étape ignorée"
      }
    } else {
      Info "winget n'est pas installé. Installe 'App Installer' depuis le Microsoft Store pour mettre à jour les applis automatiquement."
    }

    Titre "Carte mère et BIOS (relevé, rien n'est modifié)"
    $carte = Get-CimInstance Win32_BaseBoard
    $bios = Get-CimInstance Win32_BIOS
    $lignes = @()
    $lignes += "Carte mère : $($carte.Manufacturer) $($carte.Product)"
    $lignes += "BIOS : $($bios.Manufacturer) version $($bios.SMBIOSBIOSVersion) du $($bios.ReleaseDate)"
    foreach ($l in $lignes) { Info $l }
    $lignes | Set-Content "$bureau\Infos_Carte_Mere.txt"
    Ok "Infos enregistrées sur le Bureau (Infos_Carte_Mere.txt)"
    Info "Pour le BIOS, ne le fais que si tu as un vrai problème ou une version qui corrige ton souci."
    if (Demander "Ouvrir la page de recherche du BIOS de ta carte mère ?") {
      $recherche = [uri]::EscapeDataString("$($carte.Manufacturer) $($carte.Product) BIOS support")
      Start-Process "https://www.google.com/search?q=$recherche"
    }

    Titre "Carte graphique"
    $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch "Virtual|Spacedesk|Basic" }
    foreach ($g in $gpus) { Info "$($g.Name) | pilote $($g.DriverVersion) | date $($g.DriverDate)" }
    if (Demander "Ouvrir la page de téléchargement du pilote de ta carte graphique ?") {
      foreach ($g in $gpus) {
        if ($g.Name -match "NVIDIA") { Start-Process "https://www.nvidia.com/Download/index.aspx" }
        elseif ($g.Name -match "AMD|Radeon") { Start-Process "https://www.amd.com/en/support/download/drivers.html" }
        elseif ($g.Name -match "Intel") { Start-Process "https://www.intel.com/content/www/us/en/download-center/home.html" }
      }
    }
    Ecrire 'fin' "Mises à jour terminées : redémarre le PC pour finir."
  }

  # ------------------------------------------------------------------
  # NETTOYAGE (les réglages sont maintenant dans l'onglet Optimisations)
  # ------------------------------------------------------------------
  function Nettoyer($ouvrirWU) {
    $ErrorActionPreference = 'SilentlyContinue'
    $libreAvant = EspaceLibre
    PointRestauration "Avant nettoyage"

    Titre "Nettoyage des fichiers temporaires"
    $dossiers = @($env:TEMP, "C:\Windows\Temp", "$env:LOCALAPPDATA\Microsoft\Windows\INetCache", "$env:LOCALAPPDATA\CrashDumps")
    foreach ($d in $dossiers) {
      if (Test-Path $d) { Get-ChildItem $d -Force -Recurse | Remove-Item -Force -Recurse }
    }
    Ok "Fichiers temporaires supprimés"

    Titre "Cache de Windows Update"
    Stop-Service wuauserv -Force
    Get-ChildItem "C:\Windows\SoftwareDistribution\Download" -Force | Remove-Item -Force -Recurse
    Start-Service wuauserv
    Ok "Cache des mises à jour vidé"

    Titre "Cache de Chrome et corbeille"
    Stop-Process -Name chrome -Force
    $chrome = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"
    foreach ($n in @("Cache", "Code Cache", "GPUCache")) {
      $p = Join-Path $chrome $n
      if (Test-Path $p) { Get-ChildItem $p -Force -Recurse | Remove-Item -Force -Recurse }
    }
    Clear-RecycleBin -Force
    Ok "Cache de Chrome vidé (mots de passe et favoris conservés)"
    Ok "Corbeille vidée"

    Titre "Programmes au démarrage"
    $run = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $props = (Get-Item $run).Property
    if ($props) {
      $sauvegarde = "$bureau\Demarrage_sauvegarde.txt"
      foreach ($nom in $props) {
        $val = (Get-ItemProperty $run).$nom
        if (Demander "Retirer « $nom » du démarrage ?" $val) {
          "$nom = $val" | Add-Content $sauvegarde
          Remove-ItemProperty -Path $run -Name $nom
          Ok "$nom retiré du démarrage (sauvegardé sur le Bureau)"
        } else {
          Info "$nom conservé"
        }
      }
    } else {
      Info "Rien à retirer"
    }

    Titre "Optimisation du disque"
    $disque = Get-PhysicalDisk | Select-Object -First 1
    if ($disque.MediaType -eq "SSD") {
      Optimize-Volume -DriveLetter C -ReTrim
      Ok "SSD optimisé (TRIM)"
    } else {
      Info "Disque dur classique : défragmentation (peut prendre du temps)"
      Optimize-Volume -DriveLetter C -Defrag
      Ok "Disque défragmenté"
    }

    $gagne = [math]::Round(((EspaceLibre) - $libreAvant) / 1MB)
    if ($gagne -gt 0) { Ecrire 'fin' "Espace libéré : $gagne Mo" }
    Ecrire 'fin' "Nettoyage terminé."
    if ($ouvrirWU) { Start-Process "ms-settings:windowsupdate" }
  }

  try {
    switch ($mode) {
      'verif' { $script:total = 7;  Verifier; ScanHorsLigne }
      'maj'   { $script:total = 5;  MettreAJour }
      'opti'  { $script:total = 6;  Nettoyer $true }
      'tout'  {
        $script:total = 17
        Verifier        # d'abord, avant que le nettoyage n'efface des traces
        MettreAJour
        Nettoyer $false
        Ecrire 'fin' "TOUT EST TERMINÉ. Redémarre le PC pour finir les mises à jour."
        ScanHorsLigne   # en tout dernier : il redémarre le PC
      }
    }
  } catch {
    Ecrire 'alerte' "  [!] Erreur : $($_.Exception.Message)"
  } finally {
    $sync.Progress = 100
    $sync.Statut = "Terminé"
    $sync.Fini = $true
  }
}

# =====================================================================
# INTERFACE
# =====================================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Tout-en-Un" Width="1180" Height="780"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI, Segoe UI Emoji">
  <Window.Resources>
    <LinearGradientBrush x:Key="GradGreen" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#0FBF73" Offset="0"/><GradientStop Color="#1DF28F" Offset="1"/></LinearGradientBrush>

    <!-- Bouton -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.65"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Interrupteur -->
    <Style x:Key="Switch" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="track" Width="46" Height="26" CornerRadius="13" Background="#2B2B2B">
              <Ellipse x:Name="thumb" Width="20" Height="20" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#18E58A"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="track" Property="Opacity" Value="0.88"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Onglets du haut -->
    <Style x:Key="TabBtn" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#8F8F8F"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,24,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <StackPanel>
              <ContentPresenter Margin="0,0,0,9"/>
              <Border x:Name="u" Height="3" CornerRadius="2" Background="Transparent"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter Property="Foreground" Value="White"/>
                <Setter TargetName="u" Property="Background" Value="#18E58A"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="White"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Menu de gauche -->
    <Style x:Key="NavBtn" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#B5B5B5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="n" CornerRadius="12" BorderThickness="1" BorderBrush="Transparent" Background="Transparent" Padding="16,13">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="n" Property="Background" Value="#141414"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter Property="Foreground" Value="White"/>
                <Setter TargetName="n" Property="BorderBrush" Value="#18E58A"/>
                <Setter TargetName="n" Property="Background" Value="#0F0F0F"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Barre de progression -->
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border Background="#1B1B1B" CornerRadius="4"/>
              <Border x:Name="PART_Track"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="4" Background="{StaticResource GradGreen}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Barre de défilement fine -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb"><Border Background="#2E2E2E" CornerRadius="4" Margin="1"/></ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="16" Background="#070707" BorderBrush="#1A1A1A" BorderThickness="1">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="250"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- ===== Menu de gauche ===== -->
      <Border Grid.Column="0" Background="#0B0B0B" CornerRadius="16,0,0,16" BorderBrush="#161616" BorderThickness="0,0,1,0">
        <StackPanel Margin="18,24,18,18">
          <StackPanel Orientation="Horizontal" Margin="4,0,0,30">
            <Border Width="44" Height="44" CornerRadius="12" Background="{StaticResource GradGreen}">
              <TextBlock Text="🖥️" FontSize="22" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="PC Tout-en-Un" FontSize="17" FontWeight="Bold" Foreground="White"/>
              <TextBlock x:Name="SousTitre" FontSize="11" Foreground="#6E6E6E" Margin="0,2,0,0"/>
            </StackPanel>
          </StackPanel>
          <RadioButton x:Name="NavDash" GroupName="nav" IsChecked="True" Style="{StaticResource NavBtn}" Content="🏠   DASHBOARD"/>
          <RadioButton x:Name="NavOpti" GroupName="nav" Style="{StaticResource NavBtn}" Content="🚀   OPTIMISATIONS"/>
        </StackPanel>
      </Border>

      <!-- ===== Contenu ===== -->
      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Barre de titre -->
        <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent" Height="56">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,14,16,0">
            <Button x:Name="BtnMin" Content="—" Width="36" Height="30" Margin="0,0,6,0" Background="#161616" Style="{StaticResource Btn}"/>
            <Button x:Name="BtnClose" Content="✕" Width="36" Height="30" Background="#161616" Style="{StaticResource Btn}"/>
          </StackPanel>
        </Grid>

        <Grid Grid.Row="1">
          <!-- ===== PAGE DASHBOARD ===== -->
          <Grid x:Name="PageDash">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="20,0,20,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

              <Border Grid.Column="0" Margin="6" Padding="20" CornerRadius="14" Background="#0F0F0F" BorderBrush="#1C1C1C" BorderThickness="1">
                <StackPanel>
                  <Border Width="48" Height="48" CornerRadius="13" HorizontalAlignment="Left" Background="{StaticResource GradGreen}">
                    <TextBlock Text="🛡️" FontSize="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <TextBlock Text="Vérifier une infection" FontSize="16" FontWeight="Bold" Foreground="White" Margin="0,14,0,0"/>
                  <TextBlock Text="Lecture seule : Defender, démarrage, tâches, services et fichiers récents. Rien n'est supprimé." FontSize="12" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="64"/>
                  <Button x:Name="BtnVerif" Content="Lancer la vérification" Height="38" Foreground="#04130B" Background="{StaticResource GradGreen}" Style="{StaticResource Btn}"/>
                </StackPanel>
              </Border>

              <Border Grid.Column="1" Margin="6" Padding="20" CornerRadius="14" Background="#0F0F0F" BorderBrush="#1C1C1C" BorderThickness="1">
                <StackPanel>
                  <Border Width="48" Height="48" CornerRadius="13" HorizontalAlignment="Left" Background="{StaticResource GradGreen}">
                    <TextBlock Text="🔄" FontSize="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <TextBlock Text="Tout mettre à jour" FontSize="16" FontWeight="Bold" Foreground="White" Margin="0,14,0,0"/>
                  <TextBlock Text="Windows, pilotes, applications (winget), plus un relevé de la carte mère, du BIOS et de la carte graphique." FontSize="12" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="64"/>
                  <Button x:Name="BtnMaj" Content="Lancer les mises à jour" Height="38" Foreground="#04130B" Background="{StaticResource GradGreen}" Style="{StaticResource Btn}"/>
                </StackPanel>
              </Border>

              <Border Grid.Column="2" Margin="6" Padding="20" CornerRadius="14" Background="#0F0F0F" BorderBrush="#1C1C1C" BorderThickness="1">
                <StackPanel>
                  <Border Width="48" Height="48" CornerRadius="13" HorizontalAlignment="Left" Background="{StaticResource GradGreen}">
                    <TextBlock Text="🧹" FontSize="24" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <TextBlock Text="Nettoyer le PC" FontSize="16" FontWeight="Bold" Foreground="White" Margin="0,14,0,0"/>
                  <TextBlock Text="Fichiers temporaires, caches, corbeille, programmes au démarrage et optimisation du disque." FontSize="12" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,6,0,14" MinHeight="64"/>
                  <Button x:Name="BtnOpti" Content="Lancer le nettoyage" Height="38" Foreground="#04130B" Background="{StaticResource GradGreen}" Style="{StaticResource Btn}"/>
                </StackPanel>
              </Border>
            </Grid>

            <Grid Grid.Row="1" Margin="26,12,26,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Button x:Name="BtnAll" Grid.Column="0" Content="⚡   TOUT FAIRE" Width="240" Height="52" FontSize="16" Foreground="#04130B" Background="{StaticResource GradGreen}" Style="{StaticResource Btn}"/>
              <StackPanel Grid.Column="1" Margin="22,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="Statut" Text="Prêt" FontSize="13" Foreground="#CFCFCF" Margin="0,0,0,8"/>
                <ProgressBar x:Name="Prog" Minimum="0" Maximum="100" Value="0"/>
              </StackPanel>
            </Grid>

            <Grid Grid.Row="2" Margin="26,16,26,8">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <Grid Grid.Row="0" Margin="0,0,0,8">
                <TextBlock Text="JOURNAL" FontSize="12" FontWeight="Bold" Foreground="#6E6E6E" VerticalAlignment="Center"/>
                <Button x:Name="BtnRapport" Content="📄  Ouvrir le rapport" Visibility="Collapsed" HorizontalAlignment="Right" Padding="14,6" Background="#161616" Style="{StaticResource Btn}"/>
              </Grid>
              <Border Grid.Row="1" CornerRadius="12" Background="#050505" BorderBrush="#1A1A1A" BorderThickness="1">
                <RichTextBox x:Name="Log" IsReadOnly="True" Background="Transparent" BorderThickness="0" Padding="12" FontFamily="Consolas" FontSize="12.5" Foreground="#CFCFCF" VerticalScrollBarVisibility="Auto"/>
              </Border>
            </Grid>
          </Grid>

          <!-- ===== PAGE OPTIMISATIONS ===== -->
          <Grid x:Name="PageOpti" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid Grid.Row="0" Margin="26,0,26,0">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Bottom">
                <RadioButton x:Name="TabPriv" GroupName="tabs" Tag="priv" IsChecked="True" Style="{StaticResource TabBtn}" Content="CONFIDENTIALITÉ"/>
                <RadioButton x:Name="TabConfort" GroupName="tabs" Tag="confort" Style="{StaticResource TabBtn}" Content="CONFORT"/>
                <RadioButton x:Name="TabReseau" GroupName="tabs" Tag="reseau" Style="{StaticResource TabBtn}" Content="RÉSEAU"/>
                <RadioButton x:Name="TabPerf" GroupName="tabs" Tag="perf" Style="{StaticResource TabBtn}" Content="PERFORMANCES"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,0,8">
                <Button x:Name="BtnRestore" Content="↩  Tout restaurer" Padding="16,9" Margin="0,0,10,0" Background="#161616" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnBoost" Content="⚡  BOOST" Padding="22,9" Foreground="#04130B" Background="#18E58A" Style="{StaticResource Btn}"/>
              </StackPanel>
            </Grid>
            <ScrollViewer x:Name="Scroll" Grid.Row="1" Margin="20,12,12,6" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <UniformGrid x:Name="Cartes" Columns="3"/>
            </ScrollViewer>
          </Grid>
        </Grid>

        <!-- Pied de page -->
        <Grid Grid.Row="2" Margin="26,0,26,16">
          <TextBlock x:Name="Toast" FontSize="12" Foreground="#7E7E7E" VerticalAlignment="Center" Text="⚡ = réglage recommandé"/>
          <TextBlock Text="BY MICKAEL" FontSize="15" FontWeight="Black" Foreground="#18E58A" HorizontalAlignment="Right" VerticalAlignment="Center">
            <TextBlock.Effect><DropShadowEffect Color="#18E58A" BlurRadius="14" ShadowDepth="0" Opacity="0.75"/></TextBlock.Effect>
          </TextBlock>
        </Grid>
      </Grid>

      <!-- ===== Fenêtre de question ===== -->
      <Border x:Name="Overlay" Grid.ColumnSpan="2" Background="#E6030303" CornerRadius="16" Visibility="Collapsed">
        <Border Width="540" VerticalAlignment="Center" HorizontalAlignment="Center" Padding="28" CornerRadius="18" Background="#0F0F0F" BorderBrush="#1F3D2E" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="❓" FontSize="30"/>
            <TextBlock x:Name="QTexte" FontSize="17" FontWeight="Bold" Foreground="White" TextWrapping="Wrap" Margin="0,10,0,0"/>
            <TextBlock x:Name="QDetail" FontFamily="Consolas" FontSize="12" Foreground="#8A8A8A" TextWrapping="Wrap" Margin="0,10,0,0"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0">
              <Button x:Name="BtnNon" Content="Non" Width="110" Height="40" Margin="0,0,10,0" Background="#1E1E1E" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnOui" Content="Oui" Width="110" Height="40" Foreground="#04130B" Background="{StaticResource GradGreen}" Style="{StaticResource Btn}"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Border>
    </Grid>
  </Border>
</Window>
'@

# Modèle d'une carte à interrupteur
$carteXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Margin="6" Padding="20" CornerRadius="14" Background="#0F0F0F" BorderBrush="#1C1C1C" BorderThickness="1" MinHeight="170">
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <TextBlock x:Name="CTitre" FontSize="16" FontWeight="Bold" Foreground="White" TextWrapping="Wrap" Margin="0,0,12,0"/>
    <ToggleButton x:Name="CTog" Grid.Column="1" VerticalAlignment="Top"/>
    <Button x:Name="CBtn" Grid.Column="1" Content="Ouvrir" Visibility="Collapsed" Padding="16,7" VerticalAlignment="Top" Background="#1E1E1E"/>
    <StackPanel Grid.Row="1" Grid.ColumnSpan="2" Margin="0,16,0,0">
      <TextBlock x:Name="CD1" FontSize="12.5" Foreground="#B0B0B0" TextWrapping="Wrap"/>
      <TextBlock x:Name="CD2" FontSize="12.5" Foreground="#7A7A7A" TextWrapping="Wrap" Margin="0,8,0,0"/>
    </StackPanel>
    <TextBlock x:Name="CReco" Grid.Row="1" Grid.ColumnSpan="2" Text="⚡" FontSize="14" Foreground="#18E58A" HorizontalAlignment="Right" VerticalAlignment="Bottom" Visibility="Collapsed"/>
  </Grid>
</Border>
'@

try {
  $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
  foreach ($n in 'TitleBar','SousTitre','BtnMin','BtnClose','BtnVerif','BtnMaj','BtnOpti','BtnAll','Statut','Prog','Log','BtnRapport','Overlay','QTexte','QDetail','BtnOui','BtnNon','NavDash','NavOpti','PageDash','PageOpti','TabPriv','TabConfort','TabReseau','TabPerf','BtnBoost','BtnRestore','Cartes','Scroll','Toast') {
    Set-Variable -Name $n -Value $window.FindName($n)
  }

  # ---------- État partagé avec le thread de travail ----------
  $sync = [hashtable]::Synchronized(@{})
  $sync.Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
  $sync.Event = New-Object System.Threading.ManualResetEvent $false
  $sync.Answer = $false
  $sync.Question = $null
  $sync.Progress = 0
  $sync.Statut = "Prêt"
  $sync.Fini = $false
  $sync.Occupe = $false

  $conv = New-Object System.Windows.Media.BrushConverter
  $couleurs = @{ titre = '#1DF28F'; ligne = '#9A9A9A'; ok = '#4ADE80'; alerte = '#FACC15'; info = '#D0D0D0'; fin = '#38BDF8' }
  $script:cheminRapport = $null
  $script:ps = $null
  $script:handle = $null
  $script:restaureUI = $false
  $boutons = @($BtnVerif, $BtnMaj, $BtnOpti, $BtnAll)

  $libre = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
  $SousTitre.Text = "$env:COMPUTERNAME  •  C: $libre Go libres"

  # =================================================================
  # OPTIMISATIONS : outils registre
  # =================================================================
  function RSet($p, $n, $v, $type = 'DWord') {
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $type -Force | Out-Null
  }
  function RDel($p, $n) { Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue }
  function RGet($p, $n) { return (Get-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue).$n }

  $CDM   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
  $ADV   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
  $EXADV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
  $EXP   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
  $POL   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
  $CLSID = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
  $SYSPROF = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
  $TCPIF = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'

  $tweaks = New-Object System.Collections.ArrayList
  function Tw($tab, $titre, $d1, $d2, $reco, $test, $on, $off) {
    [void]$tweaks.Add(@{ Tab = $tab; Titre = $titre; D1 = $d1; D2 = $d2; Reco = $reco; Test = $test; On = $on; Off = $off; Action = $null; Etat = $false })
  }

  # ---------------- CONFIDENTIALITÉ ----------------
  Tw 'priv' 'Supprimer les publicités Windows' 'Élimine les messages promotionnels intégrés à Windows.' 'Réduit les interruptions et distractions inutiles.' $true `
    { (RGet $ADV 'Enabled') -eq 0 } `
    { RSet $ADV 'Enabled' 0; foreach ($n in 'SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338393Enabled') { RSet $CDM $n 0 } } `
    { RSet $ADV 'Enabled' 1; foreach ($n in 'SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338393Enabled') { RSet $CDM $n 1 } }

  Tw 'priv' 'Désactiver les suggestions Windows' 'Désactive les suggestions et contenus sponsorisés dans le menu Démarrer et les paramètres.' 'Allège l''interface et réduit les sollicitations système inutiles.' $true `
    { (RGet $CDM 'SystemPaneSuggestionsEnabled') -eq 0 } `
    { foreach ($n in 'SystemPaneSuggestionsEnabled','SoftLandingEnabled','SubscribedContent-338389Enabled','SubscribedContent-310093Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') { RSet $CDM $n 0 } } `
    { foreach ($n in 'SystemPaneSuggestionsEnabled','SoftLandingEnabled','SubscribedContent-338389Enabled','SubscribedContent-310093Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') { RSet $CDM $n 1 } }

  Tw 'priv' 'Désactiver les recommandations du menu Démarrer' 'Masque la section Recommandé (apps et fichiers récemment ajoutés).' 'Épure le menu Démarrer et limite le suivi des fichiers récents.' $true `
    { (RGet $EXADV 'Start_TrackDocs') -eq 0 } `
    { RSet $EXADV 'Start_TrackDocs' 0; RSet $EXADV 'Start_IrisRecommendations' 0 } `
    { RSet $EXADV 'Start_TrackDocs' 1; RSet $EXADV 'Start_IrisRecommendations' 1 }

  Tw 'priv' 'Désactiver l''historique d''activité' 'Supprime l''historique des documents récents et des activités envoyées à Microsoft.' 'Réduit les données collectées par Windows en arrière-plan.' $true `
    { (RGet "$POL\System" 'EnableActivityFeed') -eq 0 } `
    { foreach ($n in 'EnableActivityFeed','PublishUserActivities','UploadUserActivities') { RSet "$POL\System" $n 0 } } `
    { foreach ($n in 'EnableActivityFeed','PublishUserActivities','UploadUserActivities') { RDel "$POL\System" $n } }

  Tw 'priv' 'Désactiver Windows Recall / analyse IA' 'Désactive l''analyse de l''activité par l''IA intégrée à Windows (captures d''écran en continu).' 'Sans effet si ta version de Windows n''a pas Recall.' $false `
    { (RGet "$POL\WindowsAI" 'DisableAIDataAnalysis') -eq 1 } `
    { RSet "$POL\WindowsAI" 'DisableAIDataAnalysis' 1 } `
    { RDel "$POL\WindowsAI" 'DisableAIDataAnalysis' }

  Tw 'priv' 'Désactiver la télémétrie Windows' 'Réduit la collecte de données et coupe les services de suivi (DiagTrack).' 'Réduit les charges invisibles pouvant ralentir le système.' $true `
    { (RGet "$POL\DataCollection" 'AllowTelemetry') -eq 0 } `
    { RSet "$POL\DataCollection" 'AllowTelemetry' 0; foreach ($s in 'DiagTrack','dmwappushservice') { Stop-Service $s -Force -ErrorAction SilentlyContinue; Set-Service $s -StartupType Disabled -ErrorAction SilentlyContinue } } `
    { RDel "$POL\DataCollection" 'AllowTelemetry'; foreach ($s in 'DiagTrack','dmwappushservice') { Set-Service $s -StartupType Automatic -ErrorAction SilentlyContinue }; Start-Service DiagTrack -ErrorAction SilentlyContinue }

  Tw 'priv' 'Désactiver la géolocalisation' 'Bloque l''accès de Windows et des applications à ta position.' 'Réduit les accès réseau en arrière-plan.' $false `
    { (RGet 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value') -eq 'Deny' } `
    { RSet 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String' } `
    { RSet 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Allow' 'String' }

  Tw 'priv' 'Désactiver la reconnaissance vocale en ligne' 'Désactive les services de dictée et d''analyse vocale connectés.' 'Réduit les tâches actives pouvant provoquer des ralentissements ponctuels.' $false `
    { (RGet 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted') -eq 0 } `
    { RSet 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0 } `
    { RSet 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 1 }

  Tw 'priv' 'Bloquer les installations non sollicitées' 'Empêche Windows d''installer automatiquement des apps et jeux depuis le Store.' 'Allège le système en bloquant les installations en arrière-plan.' $true `
    { (RGet $CDM 'SilentInstalledAppsEnabled') -eq 0 } `
    { foreach ($n in 'SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OEMPreInstalledAppsEnabled') { RSet $CDM $n 0 } } `
    { foreach ($n in 'SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OEMPreInstalledAppsEnabled') { RSet $CDM $n 1 } }

  # ---------------- CONFORT ----------------
  Tw 'confort' 'Désactiver les effets visuels et animations' 'Supprime les effets graphiques inutiles de Windows (transparence, animations).' 'Améliore la fluidité de l''interface et la réactivité globale.' $true `
    { (RGet "$EXP\VisualEffects" 'VisualFXSetting') -eq 2 } `
    { RSet "$EXP\VisualEffects" 'VisualFXSetting' 2; RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0; RSet 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String' } `
    { RSet "$EXP\VisualEffects" 'VisualFXSetting' 0; RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 1; RSet 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '1' 'String' }

  Tw 'confort' 'Désactiver les résultats web dans la recherche' 'Supprime les suggestions Bing et du Store dans la barre de recherche Windows.' 'Rend la recherche plus rapide et moins encombrée.' $true `
    { (RGet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled') -eq 0 } `
    { RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0; RSet 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 } `
    { RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 1; RDel 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' }

  Tw 'confort' 'Supprimer les widgets Windows' 'Supprime les widgets intégrés dans la barre des tâches.' 'Réduit les processus actifs en arrière-plan et allège l''interface.' $true `
    { (RGet 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests') -eq 0 } `
    { RSet 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0; RSet $EXADV 'TaskbarDa' 0 } `
    { RDel 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests'; RSet $EXADV 'TaskbarDa' 1 }

  Tw 'confort' 'Optimiser la souris pour le jeu' 'Désactive l''accélération du pointeur (précision accrue, comportement prévisible).' 'Visible après reconnexion à Windows.' $true `
    { (RGet 'HKCU:\Control Panel\Mouse' 'MouseSpeed') -eq '0' } `
    { RSet 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'; RSet 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'; RSet 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String' } `
    { RSet 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '1' 'String'; RSet 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '6' 'String'; RSet 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '10' 'String' }

  Tw 'confort' 'Optimiser l''Explorateur Windows' 'Ouvre l''Explorateur directement sur Ce PC et masque les fichiers récents et fréquents.' 'Rend l''ouverture des dossiers plus rapide et plus fluide.' $false `
    { (RGet $EXP 'ShowFrequent') -eq 0 } `
    { RSet $EXADV 'LaunchTo' 1; RSet $EXP 'ShowRecent' 0; RSet $EXP 'ShowFrequent' 0 } `
    { RSet $EXADV 'LaunchTo' 2; RSet $EXP 'ShowRecent' 1; RSet $EXP 'ShowFrequent' 1 }

  Tw 'confort' 'Restaurer le menu contextuel classique' 'Restaure le menu clic droit classique au lieu du menu réduit de Windows 11.' 'Redémarre l''Explorateur (la barre des tâches clignote un instant).' $false `
    { Test-Path "$CLSID\InprocServer32" } `
    { New-Item -Path "$CLSID\InprocServer32" -Force | Out-Null; Set-ItemProperty -Path "$CLSID\InprocServer32" -Name '(default)' -Value ''; Stop-Process -Name explorer -Force } `
    { Remove-Item -Path $CLSID -Recurse -Force -ErrorAction SilentlyContinue; Stop-Process -Name explorer -Force }

  Tw 'confort' 'Optimisation Edge' 'Désactive le démarrage anticipé et l''exécution en arrière-plan d''Edge.' 'Réduit l''activité du navigateur en arrière-plan.' $true `
    { (RGet 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled') -eq 0 } `
    { foreach ($n in 'StartupBoostEnabled','BackgroundModeEnabled','PersonalizationReportingEnabled') { RSet 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' $n 0 } } `
    { foreach ($n in 'StartupBoostEnabled','BackgroundModeEnabled','PersonalizationReportingEnabled') { RDel 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' $n } }

  Tw 'confort' 'Désactiver Microsoft Copilot' 'Désactive l''IA Copilot intégrée à Windows et masque son bouton.' 'Réduit l''activité en arrière-plan pouvant consommer CPU et mémoire.' $false `
    { (RGet 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot') -eq 1 } `
    { RSet 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1; RSet $EXADV 'ShowCopilotButton' 0 } `
    { RDel 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'; RSet $EXADV 'ShowCopilotButton' 1 }

  # ---------------- RÉSEAU ----------------
  Tw 'reseau' 'Optimisation de la carte réseau' 'Désactive les économies d''énergie de la carte réseau.' 'Stabilise le ping et améliore la fiabilité de la connexion.' $true `
    { $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1; if (-not $a) { return $false }; $p = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue; return [bool]($p -and $p.AllowComputerToTurnOffDevice -eq 'Disabled') } `
    { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { Set-NetAdapterPowerManagement -Name $_.Name -AllowComputerToTurnOffDevice Disabled -NoRestart -ErrorAction SilentlyContinue } } `
    { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object { Set-NetAdapterPowerManagement -Name $_.Name -AllowComputerToTurnOffDevice Enabled -NoRestart -ErrorAction SilentlyContinue } }

  Tw 'reseau' 'Optimisation de la latence réseau' 'Désactive l''algorithme de Nagle pour réduire la latence des petits paquets.' 'Connexion plus réactive en jeu, avec moins de micro-saccades de ping.' $true `
    { @(Get-ChildItem $TCPIF -ErrorAction SilentlyContinue | Where-Object { (RGet $_.PSPath 'TcpAckFrequency') -eq 1 }).Count -gt 0 } `
    { Get-ChildItem $TCPIF -ErrorAction SilentlyContinue | ForEach-Object { RSet $_.PSPath 'TcpAckFrequency' 1; RSet $_.PSPath 'TCPNoDelay' 1 } } `
    { Get-ChildItem $TCPIF -ErrorAction SilentlyContinue | ForEach-Object { RDel $_.PSPath 'TcpAckFrequency'; RDel $_.PSPath 'TCPNoDelay' } }

  Tw 'reseau' 'Optimisation de la réactivité réseau' 'Désactive le bridage réseau de Windows pour le trafic en jeu.' 'Laisse passer davantage de paquets et réduit la latence en ligne.' $true `
    { (RGet $SYSPROF 'NetworkThrottlingIndex') -eq -1 } `
    { RSet $SYSPROF 'NetworkThrottlingIndex' -1; RSet $SYSPROF 'SystemResponsiveness' 0 } `
    { RSet $SYSPROF 'NetworkThrottlingIndex' 10; RSet $SYSPROF 'SystemResponsiveness' 20 }

  Tw 'reseau' 'DNS rapide (Cloudflare)' 'Fait passer ton PC par le DNS public 1.1.1.1, plus rapide que celui de ta box.' 'Annulable : remet le DNS automatique de ta box.' $false `
    { $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1; if (-not $a) { return $false }; $d = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses; return [bool]($d -contains '1.1.1.1') } `
    { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ('1.1.1.1','1.0.0.1') } } `
    { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses } }

  Tw 'reseau' 'Désactiver le partage P2P des mises à jour' 'Empêche Windows d''utiliser ta connexion pour distribuer ses mises à jour à d''autres PC.' 'Libère de la bande passante montante et réduit les pics de latence.' $true `
    { (RGet "$POL\DeliveryOptimization" 'DODownloadMode') -eq 0 } `
    { RSet "$POL\DeliveryOptimization" 'DODownloadMode' 0 } `
    { RDel "$POL\DeliveryOptimization" 'DODownloadMode' }

  # ---------------- PERFORMANCES ----------------
  Tw 'perf' 'Désactiver l''hibernation' 'Supprime le mode hibernation (utile surtout sur un PC fixe).' 'Libère de l''espace disque. À éviter sur un portable.' $false `
    { (RGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled') -eq 0 } `
    { powercfg /h off } `
    { powercfg /h on }

  Tw 'perf' 'Désactiver les apps en arrière-plan' 'Empêche les applications Microsoft Store de tourner en arrière-plan.' 'Libère de la RAM et réduit l''utilisation CPU au repos.' $true `
    { (RGet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled') -eq 1 } `
    { RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1; RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0 } `
    { RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 0; RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 1 }

  Tw 'perf' 'Plan d''alimentation Performances élevées' 'Active un mode performance maximale pour le PC.' 'Évite toute baisse automatique de performances.' $true `
    { [bool]((powercfg /getactivescheme) -match '8c5e7fda') } `
    { powercfg /setactive SCHEME_MIN } `
    { powercfg /setactive SCHEME_BALANCED }

  Tw 'perf' 'Mode Jeu Windows' 'Active le mode jeu : Windows donne la priorité au jeu en cours.' 'Limite les tâches de fond pendant tes parties.' $true `
    { (RGet 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled') -eq 1 } `
    { RSet 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 } `
    { RSet 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0 }

  Tw 'perf' 'Désactiver Xbox Game Bar' 'Désactive l''overlay Xbox Game Bar et la capture DVR.' 'Supprime un overlay actif en jeu sans toucher à l''app Xbox.' $true `
    { (RGet 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 0 } `
    { RSet 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0; RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0; RSet 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0 } `
    { RSet 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 1; RSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 1; RSet 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 1 }

  Tw 'perf' 'Désactiver SysMain (Superfetch)' 'Désactive le service SysMain de Windows.' 'Réduit les lectures disque en arrière-plan, surtout sur SSD. À éviter sur disque dur.' $false `
    { (Get-Service SysMain -ErrorAction SilentlyContinue).StartType -eq 'Disabled' } `
    { Stop-Service SysMain -Force -ErrorAction SilentlyContinue; Set-Service SysMain -StartupType Disabled } `
    { Set-Service SysMain -StartupType Automatic; Start-Service SysMain -ErrorAction SilentlyContinue }

  # Carte "action" (pas d'interrupteur)
  $carteAction = @{ Tab = 'perf'; Titre = 'Programmes au démarrage'; D1 = 'Affiche tous les programmes qui se lancent automatiquement au démarrage.'; D2 = 'Désactive ceux dont tu n''as pas besoin pour libérer des ressources.'; Reco = $true; Test = $null; On = $null; Off = $null; Etat = $false
         Action = { Start-Process 'ms-settings:startupapps' } }
  [void]$tweaks.Insert(($tweaks.Count - 3), $carteAction)

  # =================================================================
  # OPTIMISATIONS : logique des cartes
  # =================================================================
  function Dire($t) { $Toast.Text = $t }
  function Rafraichir { $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render) }

  function PointRestaurationUnique {
    if ($script:restaureUI) { return }
    $script:restaureUI = $true
    Dire "Création d'un point de restauration (quelques secondes)..."
    Rafraichir
    Enable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description "Avant optimisations PC Tout-en-Un" -RestorePointType MODIFY_SETTINGS -ErrorAction SilentlyContinue
  }

  function Appliquer($t, $actif) {
    PointRestaurationUnique
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { if ($actif) { & $t.On | Out-Null } else { & $t.Off | Out-Null } } catch {}
    try { $t.Etat = [bool](& $t.Test) } catch { $t.Etat = $false }
    $window.Cursor = $null
    return ($t.Etat -eq $actif)
  }

  function Basculer($tg) {
    $t = $tg.Tag
    $veut = [bool]$tg.IsChecked
    $ok = Appliquer $t $veut
    $tg.IsChecked = $t.Etat
    if ($ok) {
      $mot = 'désactivé'; if ($veut) { $mot = 'activé' }
      Dire "✓ $($t.Titre) : $mot"
    } else {
      Dire "✗ Impossible de modifier « $($t.Titre) » (protégé par Windows ?)"
    }
  }

  # Création des cartes + lecture de l'état réel
  $styleSwitch = $window.FindResource('Switch')
  $styleBtn = $window.FindResource('Btn')
  foreach ($t in $tweaks) {
    $c = [Windows.Markup.XamlReader]::Parse($carteXaml)
    $c.FindName('CTitre').Text = $t.Titre
    $c.FindName('CD1').Text = $t.D1
    $c.FindName('CD2').Text = $t.D2
    if ($t.Reco) { $c.FindName('CReco').Visibility = 'Visible' }
    $tg = $c.FindName('CTog')
    $bt = $c.FindName('CBtn')
    $tg.Style = $styleSwitch
    $bt.Style = $styleBtn
    if ($t.Action) {
      $tg.Visibility = 'Collapsed'
      $bt.Visibility = 'Visible'
      $bt.Tag = $t
      $bt.Add_Click({ & $args[0].Tag.Action })
    } else {
      try { $t.Etat = [bool](& $t.Test) } catch { $t.Etat = $false }
      $tg.IsChecked = $t.Etat
      $tg.Tag = $t
      $tg.Add_Click({ Basculer $args[0] })
    }
    $t.Carte = $c
    $t.Tg = $tg
  }

  function AfficherOnglet($nom) {
    $Cartes.Children.Clear()
    foreach ($t in $tweaks) {
      if ($t.Tab -eq $nom) {
        if (-not $t.Action) { $t.Tg.IsChecked = $t.Etat }
        [void]$Cartes.Children.Add($t.Carte)
      }
    }
    $Scroll.ScrollToTop()
  }

  foreach ($tab in @($TabPriv, $TabConfort, $TabReseau, $TabPerf)) { $tab.Add_Checked({ AfficherOnglet $args[0].Tag }) }
  AfficherOnglet 'priv'

  $BtnBoost.Add_Click({
    $reponse = [System.Windows.MessageBox]::Show("BOOST va activer tous les réglages recommandés (marqués ⚡) dans les 4 onglets.`n`nUn point de restauration est créé avant, et tout peut être annulé avec « Tout restaurer ».`n`nContinuer ?", "BOOST", 'YesNo', 'Question')
    if ($reponse -ne 'Yes') { return }
    $n = 0
    foreach ($t in $tweaks) {
      if ($t.Reco -and -not $t.Action -and -not $t.Etat) {
        # on évite de redémarrer l'Explorateur pendant un BOOST : aucun réglage recommandé ne le fait
        if (Appliquer $t $true) { $n++ }
      }
    }
    AfficherOnglet $(if ($TabPriv.IsChecked) { 'priv' } elseif ($TabConfort.IsChecked) { 'confort' } elseif ($TabReseau.IsChecked) { 'reseau' } else { 'perf' })
    Dire "⚡ BOOST terminé : $n réglage(s) appliqué(s). Redémarre le PC pour tout finaliser."
  })

  $BtnRestore.Add_Click({
    $reponse = [System.Windows.MessageBox]::Show("Remettre TOUS les réglages de cet onglet Optimisations aux valeurs par défaut de Windows ?", "Tout restaurer", 'YesNo', 'Question')
    if ($reponse -ne 'Yes') { return }
    $n = 0
    foreach ($t in $tweaks) {
      if (-not $t.Action -and $t.Etat) {
        if (Appliquer $t $false) { $n++ }
      }
    }
    AfficherOnglet $(if ($TabPriv.IsChecked) { 'priv' } elseif ($TabConfort.IsChecked) { 'confort' } elseif ($TabReseau.IsChecked) { 'reseau' } else { 'perf' })
    Dire "↩ $n réglage(s) remis par défaut."
  })

  # =================================================================
  # DASHBOARD : lancement des tâches en arrière-plan
  # =================================================================
  function Ajouter($type, $texte) {
    $haut = 0; if ($type -eq 'titre') { $haut = 10 }
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness -ArgumentList 0, $haut, 0, 0
    $r = New-Object System.Windows.Documents.Run $texte
    $r.Foreground = $conv.ConvertFromString($couleurs[$type])
    if ($type -eq 'titre' -or $type -eq 'fin') { $r.FontWeight = [System.Windows.FontWeights]::Bold }
    $p.Inlines.Add($r)
    $Log.Document.Blocks.Add($p)
    $Log.ScrollToEnd()
  }

  function Lancer($mode) {
    if ($sync.Occupe) { return }
    $sync.Occupe = $true
    $sync.Fini = $false
    $sync.Progress = 0
    $sync.Statut = "Démarrage..."
    $sync.Question = $null
    foreach ($b in $boutons) { $b.IsEnabled = $false }
    $BtnRapport.Visibility = 'Collapsed'
    $Log.Document.Blocks.Clear()
    $Prog.Value = 0

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $script:ps = [powershell]::Create()
    $script:ps.Runspace = $rs
    $null = $script:ps.AddScript($Work.ToString()).AddArgument($mode)
    $script:handle = $script:ps.BeginInvoke()
  }

  $BtnVerif.Add_Click({ Lancer 'verif' })
  $BtnMaj.Add_Click({ Lancer 'maj' })
  $BtnOpti.Add_Click({ Lancer 'opti' })
  $BtnAll.Add_Click({ Lancer 'tout' })
  $BtnRapport.Add_Click({ if ($script:cheminRapport) { Start-Process notepad.exe $script:cheminRapport } })
  $BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
  $BtnClose.Add_Click({ $window.Close() })
  $TitleBar.Add_MouseLeftButtonDown({ $window.DragMove() })
  $BtnOui.Add_Click({ $sync.Answer = $true;  $Overlay.Visibility = 'Collapsed'; $sync.Event.Set() | Out-Null })
  $BtnNon.Add_Click({ $sync.Answer = $false; $Overlay.Visibility = 'Collapsed'; $sync.Event.Set() | Out-Null })

  # Menu de gauche : changement de page
  $NavDash.Add_Checked({ $PageDash.Visibility = 'Visible'; $PageOpti.Visibility = 'Collapsed' })
  $NavOpti.Add_Checked({ $PageDash.Visibility = 'Collapsed'; $PageOpti.Visibility = 'Visible' })

  # Boucle d'affichage : vide la file de messages du thread de travail
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(100)
  $timer.Add_Tick({
    $item = $null
    while ($sync.Queue.TryDequeue([ref]$item)) {
      if ($item.T -eq 'rapport') {
        $script:cheminRapport = $item.X
        $BtnRapport.Visibility = 'Visible'
      } else {
        Ajouter $item.T $item.X
      }
    }
    $Prog.Value = [double]$sync.Progress
    if ($sync.Statut) { $Statut.Text = $sync.Statut }

    $q = $sync.Question
    if ($q) {
      $sync.Question = $null
      $QTexte.Text = $q.Texte
      $QDetail.Text = $q.Detail
      $QDetail.Visibility = $(if ($q.Detail) { 'Visible' } else { 'Collapsed' })
      $Overlay.Visibility = 'Visible'
    }

    if ($sync.Occupe -and $sync.Fini -and $sync.Queue.IsEmpty) {
      $sync.Occupe = $false
      foreach ($b in $boutons) { $b.IsEnabled = $true }
      try { $script:ps.EndInvoke($script:handle) } catch {}
      $script:ps.Runspace.Close()
      $script:ps.Dispose()
    }
  })
  $timer.Start()

  Ajouter 'titre' "Bienvenue !"
  Ajouter 'info' "Choisis une action ci-dessus, ou clique sur TOUT FAIRE."
  Ajouter 'ligne' "Va dans OPTIMISATIONS (menu de gauche) pour régler Windows avec des interrupteurs."
  Ajouter 'ligne' "Un point de restauration est créé avant toute modification. Le BIOS n'est jamais modifié."

  $window.ShowDialog() | Out-Null
}
catch {
  [System.Windows.MessageBox]::Show("Erreur : $($_.Exception.Message)", "PC Tout-en-Un") | Out-Null
}
