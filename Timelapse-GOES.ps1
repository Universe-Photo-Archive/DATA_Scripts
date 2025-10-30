<#
.SYNOPSIS
    Script de téléchargement et création de timelapse depuis les satellites GOES
.DESCRIPTION
    Télécharge les images satellite GOES et crée automatiquement un timelapse MP4
#>

# ======================= CONFIGURATION =======================
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "config.ini"
$TempDir = Join-Path $ScriptDir "Temp"
$ToolsDir = Join-Path $ScriptDir "Tools"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ======================= FONCTIONS UTILITAIRES =======================

function Write-ColorHost {
    param(
        [string]$Message,
        [string]$Color = "White",
        [switch]$NoNewline
    )
    $params = @{ Object = $Message; ForegroundColor = $Color }
    if ($NoNewline) { $params.Add('NoNewline', $true) }
    Write-Host @params
}

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-ColorHost "===============================================================" -Color "Cyan"
    Write-ColorHost "  $Text" -Color "Cyan"
    Write-ColorHost "===============================================================" -Color "Cyan"
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-ColorHost "> $Text" -Color "Yellow"
}

function Write-Success {
    param([string]$Text)
    Write-ColorHost "[OK] $Text" -Color "Green"
}

function Write-ErrorMsg {
    param([string]$Text)
    Write-ColorHost "[ERREUR] $Text" -Color "Red"
}

function Get-LatestGitHubRelease {
    param(
        [string]$Repo,
        [string]$Pattern
    )
    
    try {
        $apiUrl = "https://api.github.com/repos/$Repo/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "PowerShell" }
        
        $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
        
        if ($asset) {
            return @{
                DownloadUrl = $asset.browser_download_url
                FileName = $asset.name
                Version = $release.tag_name
            }
        }
    } catch {
        Write-ErrorMsg "Erreur lors de la recuperation de la release : $($_.Exception.Message)"
    }
    
    return $null
}

function Download-WithProgress {
    param(
        [string]$Url,
        [string]$OutputPath
    )
    
    try {
        $webClient = New-Object System.Net.WebClient
        
        $scriptBlock = {
            param($sender, $e)
            $percent = $e.ProgressPercentage
            Write-Progress -Activity "Telechargement en cours" `
                          -Status "$percent% complete" `
                          -PercentComplete $percent
        }
        
        Register-ObjectEvent -InputObject $webClient -EventName DownloadProgressChanged -SourceIdentifier WebClient.DownloadProgressChanged -Action $scriptBlock | Out-Null
        
        $webClient.DownloadFileTaskAsync($Url, $OutputPath).Wait()
        
        Unregister-Event -SourceIdentifier WebClient.DownloadProgressChanged -ErrorAction SilentlyContinue
        Write-Progress -Activity "Telechargement en cours" -Completed
        
        $webClient.Dispose()
        return $true
    } catch {
        Write-ErrorMsg "Erreur de telechargement : $($_.Exception.Message)"
        return $false
    }
}

function Extract-Archive {
    param(
        [string]$ArchivePath,
        [string]$DestinationPath
    )
    
    Write-Step "Extraction en cours..."
    
    try {
        if ($ArchivePath -match '\.zip$') {
            Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
        } elseif ($ArchivePath -match '\.(tar\.gz|tgz)$') {
            if (Get-Command tar -ErrorAction SilentlyContinue) {
                & tar -xzf $ArchivePath -C $DestinationPath
            } else {
                throw "tar.gz necessaire mais tar non disponible"
            }
        } elseif ($ArchivePath -match '\.7z$') {
            if (Get-Command 7z -ErrorAction SilentlyContinue) {
                & 7z x $ArchivePath -o"$DestinationPath" -y
            } else {
                throw "Archive 7z necessaire mais 7-Zip non disponible"
            }
        }
        
        Write-Success "Extraction terminee"
        return $true
    } catch {
        Write-ErrorMsg "Erreur d'extraction : $($_.Exception.Message)"
        return $false
    }
}

function Find-ExecutableInDirectory {
    param(
        [string]$Directory,
        [string]$ExeName
    )
    
    $found = Get-ChildItem -Path $Directory -Filter $ExeName -Recurse -ErrorAction SilentlyContinue -File | Select-Object -First 1
    if ($found) {
        return $found.FullName
    }
    return $null
}

function Install-FFmpeg {
    Write-Header "INSTALLATION DE FFMPEG"
    
    Write-Step "Recherche de la derniere version de FFmpeg..."
    $release = Get-LatestGitHubRelease -Repo "BtbN/FFmpeg-Builds" -Pattern "ffmpeg-master-latest-win64-gpl\.zip"
    
    if (-not $release) {
        Write-ErrorMsg "Impossible de trouver la derniere version de FFmpeg"
        return $null
    }
    
    Write-Success "Version trouvee : $($release.Version)"
    Write-ColorHost "  Fichier : $($release.FileName)" -Color "Gray"
    
    $downloadPath = Join-Path $ToolsDir $release.FileName
    $extractPath = Join-Path $ToolsDir "ffmpeg"
    
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    
    Write-Step "Telechargement de FFmpeg..."
    if (-not (Download-WithProgress -Url $release.DownloadUrl -OutputPath $downloadPath)) {
        return $null
    }
    
    Write-Success "Telechargement termine"
    
    if (-not (Extract-Archive -ArchivePath $downloadPath -DestinationPath $extractPath)) {
        return $null
    }
    
    $ffmpegExe = Find-ExecutableInDirectory -Directory $extractPath -ExeName "ffmpeg.exe"
    
    if ($ffmpegExe) {
        Write-Success "FFmpeg installe : $ffmpegExe"
        Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
        return $ffmpegExe
    } else {
        Write-ErrorMsg "ffmpeg.exe introuvable apres extraction"
        return $null
    }
}

function Install-Aria2 {
    Write-Header "INSTALLATION DE ARIA2"
    
    Write-Step "Recherche de la derniere version d'Aria2..."
    $release = Get-LatestGitHubRelease -Repo "aria2/aria2" -Pattern "aria2-.*-win-64bit-build.*\.zip"
    
    if (-not $release) {
        Write-ErrorMsg "Impossible de trouver la derniere version d'Aria2"
        return $null
    }
    
    Write-Success "Version trouvee : $($release.Version)"
    Write-ColorHost "  Fichier : $($release.FileName)" -Color "Gray"
    
    $downloadPath = Join-Path $ToolsDir $release.FileName
    $extractPath = Join-Path $ToolsDir "aria2"
    
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    
    Write-Step "Telechargement d'Aria2..."
    if (-not (Download-WithProgress -Url $release.DownloadUrl -OutputPath $downloadPath)) {
        return $null
    }
    
    Write-Success "Telechargement termine"
    
    if (-not (Extract-Archive -ArchivePath $downloadPath -DestinationPath $extractPath)) {
        return $null
    }
    
    $aria2Exe = Find-ExecutableInDirectory -Directory $extractPath -ExeName "aria2c.exe"
    
    if ($aria2Exe) {
        Write-Success "Aria2 installe : $aria2Exe"
        Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
        return $aria2Exe
    } else {
        Write-ErrorMsg "aria2c.exe introuvable apres extraction"
        return $null
    }
}

function Select-Executable {
    param(
        [string]$Title,
        [string]$ExeName,
        [string]$ToolName
    )
    
    Write-Header "PREREQUIS : $ToolName"
    
    Write-Step "Recherche automatique de $ExeName..."
    $autoFound = Find-ExecutableInDirectory -Directory $ScriptDir -ExeName $ExeName
    
    if ($autoFound) {
        Write-Success "$ExeName trouve : $autoFound"
        Write-Host ""
        $response = Read-Host "Utiliser ce chemin ? (O/n)"
        if ($response -eq '' -or $response -match '^[oO]') {
            return $autoFound
        }
    } else {
        Write-ColorHost "> $ExeName absent..." -Color "Yellow"
    }
    
    Write-Host ""
    Write-ColorHost "Options disponibles :" -Color "Cyan"
    Write-Host "  [1] Telecharger automatiquement depuis GitHub"
    Write-Host "  [2] Selectionner manuellement un fichier existant"
    Write-Host ""
    
    $choice = Read-Host "Votre choix (1-2) [defaut: 1]"
    
    if ($choice -eq '' -or $choice -eq '1') {
        if ($ExeName -eq 'ffmpeg.exe') {
            return Install-FFmpeg
        } elseif ($ExeName -eq 'aria2c.exe') {
            return Install-Aria2
        }
    }
    
    Write-Step "Veuillez selectionner $ExeName manuellement..."
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = "Executables (*.exe)|*.exe|Tous les fichiers|*.*"
    $dialog.FileName = $ExeName
    
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }
    
    return $null
}


function Read-ConfigFile {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        return $null
    }
    
    $config = @{}
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^\s*([^=]+?)\s*=\s*(.+?)\s*$') {
            $config[$matches[1]] = $matches[2]
        }
    }
    return $config
}

function Write-ConfigFile {
    param(
        [string]$Path,
        [hashtable]$Config
    )
    
    $content = @"
# Configuration generee le $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')
FfmpegPath=$($Config.FfmpegPath)
Aria2Path=$($Config.Aria2Path)
"@
    
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Get-UserChoice {
    param(
        [string]$Prompt,
        [array]$Choices,
        [int]$Default = 1
    )
    
    Write-Host ""
    Write-ColorHost -Message $Prompt -Color "Cyan"
    for ($i = 0; $i -lt $Choices.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Choices[$i])"
    }
    Write-Host ""
    
    do {
        $input = Read-Host "Votre choix (1-$($Choices.Count)) [defaut: $Default]"
        if ([string]::IsNullOrWhiteSpace($input)) {
            return $Default - 1
        }
        $choice = $input -as [int]
    } while ($choice -lt 1 -or $choice -gt $Choices.Count)
    
    return $choice - 1
}

function Get-DateRange {
    $maxDays = 11
    $today = [datetime]::Today
    $minDate = $today.AddDays(-$maxDays + 1)
    
    Write-Host ""
    Write-ColorHost "Plage de dates disponible : du $($minDate.ToString('dd/MM/yyyy')) au $($today.ToString('dd/MM/yyyy'))" -Color "Cyan"
    Write-Host ""
    
    do {
        $inputStart = Read-Host "Date de debut (jj/MM/aaaa) [Entree = $($minDate.ToString('dd/MM/yyyy'))]"
        if ([string]::IsNullOrWhiteSpace($inputStart)) {
            $startDate = $minDate
            break
        }
        
        try {
            $startDate = [datetime]::ParseExact($inputStart, 'dd/MM/yyyy', $null)
            # CORRECTION: >= au lieu de >
            if ($startDate -lt $minDate -or $startDate -gt $today) {
                Write-ErrorMsg "Date hors de la plage autorisee"
                continue
            }
            break
        } catch {
            Write-ErrorMsg "Format invalide. Utilisez jj/MM/aaaa"
        }
    } while ($true)
    
    do {
        $inputEnd = Read-Host "Date de fin (jj/MM/aaaa) [Entree = $($today.ToString('dd/MM/yyyy'))]"
        if ([string]::IsNullOrWhiteSpace($inputEnd)) {
            $endDate = $today
            break
        }
        
        try {
            $endDate = [datetime]::ParseExact($inputEnd, 'dd/MM/yyyy', $null)
            # CORRECTION: >= au lieu de >
            if ($endDate -lt $startDate -or $endDate -gt $today) {
                Write-ErrorMsg "Date invalide (doit etre entre $($startDate.ToString('dd/MM/yyyy')) et $($today.ToString('dd/MM/yyyy')))"
                continue
            }
            break
        } catch {
            Write-ErrorMsg "Format invalide. Utilisez jj/MM/aaaa"
        }
    } while ($true)
    
    return @{ Start = $startDate; End = $endDate }
}

function Show-ProgressBar {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete
    )
    
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}

# ======================= INITIALISATION =======================

Clear-Host
Write-Header "GOES SATELLITE TIMELAPSE GENERATOR"

$config = Read-ConfigFile -Path $ConfigFile

if (-not $config) {
    Write-Step "Premiere utilisation - Configuration requise"
    Write-Host ""
    
    $ffmpegPath = Select-Executable -Title "Selectionnez ffmpeg.exe" -ExeName "ffmpeg.exe" -ToolName "FFMPEG"
    if (-not $ffmpegPath -or -not (Test-Path $ffmpegPath)) {
        Write-ErrorMsg "FFmpeg est requis pour continuer"
        Write-Host ""
        Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    Write-Host ""
    
    $aria2Path = Select-Executable -Title "Selectionnez aria2c.exe" -ExeName "aria2c.exe" -ToolName "ARIA2"
    if (-not $aria2Path -or -not (Test-Path $aria2Path)) {
        Write-ErrorMsg "Aria2 est requis pour continuer"
        Write-Host ""
        Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    $config = @{
        FfmpegPath = $ffmpegPath
        Aria2Path = $aria2Path
    }
    
    Write-Host ""
    Write-ConfigFile -Path $ConfigFile -Config $config
    Write-Success "Configuration sauvegardee dans $ConfigFile"
} else {
    Write-Success "Configuration chargee depuis $ConfigFile"
    
    if (-not (Test-Path $config.FfmpegPath)) {
        Write-ErrorMsg "FFmpeg introuvable: $($config.FfmpegPath)"
        Write-Host ""
        Write-Step "Reinstallation necessaire..."
        Write-Host ""
        
        $ffmpegPath = Select-Executable -Title "Selectionnez ffmpeg.exe" -ExeName "ffmpeg.exe" -ToolName "FFMPEG"
        if (-not $ffmpegPath -or -not (Test-Path $ffmpegPath)) {
            Write-ErrorMsg "FFmpeg est requis pour continuer"
            Write-Host ""
            Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }
        $config.FfmpegPath = $ffmpegPath
        Write-ConfigFile -Path $ConfigFile -Config $config
    }
    
    if (-not (Test-Path $config.Aria2Path)) {
        Write-ErrorMsg "Aria2 introuvable: $($config.Aria2Path)"
        Write-Host ""
        Write-Step "Reinstallation necessaire..."
        Write-Host ""
        
        $aria2Path = Select-Executable -Title "Selectionnez aria2c.exe" -ExeName "aria2c.exe" -ToolName "ARIA2"
        if (-not $aria2Path -or -not (Test-Path $aria2Path)) {
            Write-ErrorMsg "Aria2 est requis pour continuer"
            Write-Host ""
            Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }
        $config.Aria2Path = $aria2Path
        Write-ConfigFile -Path $ConfigFile -Config $config
    }
}


# ======================= SELECTION DES PARAMETRES =======================

Write-Header "CONFIGURATION DU TIMELAPSE"

Write-Host ""
Write-ColorHost -Message "Information sur les satellites :" -Color "Cyan"
Write-Host "  - GOES-18 (Ouest) : Couvre le Pacifique, l'Asie, l'Australie"
Write-Host "  - GOES-19 (Est)   : Couvre les Ameriques, l'Europe, l'Afrique"
Write-Host ""

$satellites = @(
    "GOES-18 (Ouest) - Pacifique/Asie/Australie",
    "GOES-19 (Est) - Ameriques/Europe/Afrique"
)
$satChoice = Get-UserChoice -Prompt "Choisissez le satellite :" -Choices $satellites -Default 2
$satelliteNum = if ($satChoice -eq 0) { "18" } else { "19" }
$satelliteName = "GOES$satelliteNum"

Write-Success "Satellite selectionne : $satelliteName"

$resolutions = @(
    "678x678 (Basse - rapide)",
    "1808x1808 (Moyenne)",
    "5424x5424 (Haute - lent)"
)
$resChoice = Get-UserChoice -Prompt "Choisissez la resolution :" -Choices $resolutions -Default 3
$resolution = switch ($resChoice) {
    0 { "678x678" }
    1 { "1808x1808" }
    2 { "5424x5424" }
}

Write-Success "Resolution selectionnee : $resolution"

$dateRange = Get-DateRange
Write-Success "Periode : du $($dateRange.Start.ToString('dd/MM/yyyy')) au $($dateRange.End.ToString('dd/MM/yyyy'))"

$baseUrl = "https://cdn.star.nesdis.noaa.gov/$satelliteName/ABI/FD/GEOCOLOR/"
$fileSuffix = "$resolution.jpg"

# ======================= LISTING DES FICHIERS =======================

Write-Header "TELECHARGEMENT DES IMAGES"

New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
Write-Success "Dossier temporaire cree : $TempDir"

Write-Step "Analyse de l'index du satellite..."
try {
    $resp = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing
} catch {
    Write-ErrorMsg "Echec de recuperation de l'index : $($_.Exception.Message)"
    Write-Host ""
    Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    return
}

$html = $resp.Content

# Pattern simplifié : capture le lien + la date qui suit
$pattern = '<a\s+href="(?<href>\d{11}_' + $satelliteName + '-ABI-FD-GEOCOLOR-' + [regex]::Escape($resolution) + '\.jpg)"[^>]*>.*?</a>\s+(?<date>\d{2}-[A-Za-z]{3}-\d{4}\s+\d{2}:\d{2})'

$matches = [System.Text.RegularExpressions.Regex]::Matches($html, $pattern, 'IgnoreCase')

Write-Host "Liens detectes dans l'index : $($matches.Count)"

if ($matches.Count -eq 0) {
    Write-Host ""
    Write-ErrorMsg "Aucun lien trouve dans l'index"
    Write-ColorHost "Verifiez que le satellite et la resolution sont corrects" -Color "Yellow"
    Write-Host ""
    Write-ColorHost "URL testee : $baseUrl" -Color "Gray"
    Write-Host ""
    Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    return
}

# Formats de date possibles dans l'index
$IndexDateFormats = @('dd-MMM-yyyy HH:mm', 'dd-MMM-yyyy HH:mm:ss')
$IndexCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Parse-IndexDate {
    param(
        [string]$DateText,
        [string[]]$Formats,
        [System.IFormatProvider]$Culture
    )
    foreach ($fmt in $Formats) {
        try {
            return [datetime]::ParseExact($DateText, $fmt, $Culture)
        } catch {
            continue
        }
    }
    throw "Format de date inattendu: '$DateText'"
}

# Collecte des fichiers correspondant à la plage de dates
$items = New-Object System.Collections.Generic.List[object]
$startDate = $dateRange.Start.Date
$endDate = $dateRange.End.Date.AddDays(1).AddSeconds(-1)

$parseErrors = 0

foreach ($m in $matches) {
    $href = $m.Groups['href'].Value
    $dateText = $m.Groups['date'].Value
    
    try {
        $fileDate = Parse-IndexDate -DateText $dateText -Formats $IndexDateFormats -Culture $IndexCulture
    } catch {
        $parseErrors++
        continue
    }
    
    # Filtrer uniquement par DATE (pas par heure/minute)
    if ($fileDate -ge $startDate -and $fileDate -le $endDate) {
        $url = $baseUrl.TrimEnd('/') + '/' + $href
        $items.Add([pscustomobject]@{ 
            Url = $url
            Date = $fileDate
            FileName = $href 
        })
    }
}

if ($parseErrors -gt 0) {
    Write-ColorHost "  $parseErrors fichier(s) ignore(s) (dates non parsables)" -Color "DarkGray"
}

if ($items.Count -eq 0) {
    Write-ErrorMsg "Aucune image trouvee pour la periode selectionnee"
    Write-ColorHost "  Periode demandee : $($startDate.ToString('dd/MM/yyyy')) -> $($endDate.ToString('dd/MM/yyyy'))" -Color "Gray"
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    return
}

# Trier par date et supprimer les doublons par FileName uniquement
$items = $items | Sort-Object Date | Sort-Object FileName -Unique

Write-Success "$($items.Count) image(s) a telecharger"

# Afficher les infos avec vérification de nullité
$firstItem = $items[0]
$lastItem = $items[-1]

if ($firstItem.Date) {
    Write-ColorHost "  Premiere image : $($firstItem.FileName) ($($firstItem.Date.ToString('dd/MM/yyyy HH:mm')))" -Color "Gray"
} else {
    Write-ColorHost "  Premiere image : $($firstItem.FileName)" -Color "Gray"
}

if ($lastItem.Date) {
    Write-ColorHost "  Derniere image : $($lastItem.FileName) ($($lastItem.Date.ToString('dd/MM/yyyy HH:mm')))" -Color "Gray"
} else {
    Write-ColorHost "  Derniere image : $($lastItem.FileName)" -Color "Gray"
}

# Créer le fichier de liste pour aria2
$urlListFile = Join-Path $TempDir "urls.txt"
$items.Url | Set-Content -Path $urlListFile -Encoding UTF8

# ======================= TELECHARGEMENT AVEC ARIA2 =======================

Write-Step "Telechargement en cours (10 fichiers simultanement)..."
Write-ColorHost "  Parametres : 16 connexions par fichier | Split : 16" -Color "Gray"
Write-Host ""

$aria2LogFile = Join-Path $TempDir "aria2.log"
$aria2StdOut = Join-Path $TempDir "aria2_stdout.tmp"
$aria2StdErr = Join-Path $TempDir "aria2_stderr.tmp"

$aria2Args = @(
    "--input-file=`"$urlListFile`""
    "--dir=`"$TempDir`""
    "--max-concurrent-downloads=10"
    "--max-connection-per-server=16"
    "--split=16"
    "--min-split-size=1M"
    "--continue=true"
    "--auto-file-renaming=false"
    "--allow-overwrite=false"
    "--console-log-level=error"
    "--summary-interval=0"
    "--download-result=hide"
    "--log=`"$aria2LogFile`""
    "--log-level=info"
    "--quiet=true"
)

$startTime = Get-Date

# Lancer aria2 en silence totale
$aria2Process = Start-Process -FilePath $config.Aria2Path `
                              -ArgumentList $aria2Args `
                              -NoNewWindow -PassThru `
                              -RedirectStandardOutput $aria2StdOut `
                              -RedirectStandardError $aria2StdErr

# Monitoring en temps réel
$lastCount = 0
$checkInterval = 300 # ms

while (-not $aria2Process.HasExited) {
    Start-Sleep -Milliseconds $checkInterval
    
    $currentFiles = @(Get-ChildItem -Path $TempDir -File -Filter "*.jpg" -ErrorAction SilentlyContinue)
    $currentCount = $currentFiles.Count
    
    if ($currentCount -ne $lastCount) {
        $percent = [math]::Min(100, [int](($currentCount / $items.Count) * 100))
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        
        if ($currentCount -gt 0 -and $elapsed -gt 5) {
            $speed = $currentCount / $elapsed
            $remaining = ($items.Count - $currentCount) / $speed
            $remainingMin = [math]::Floor($remaining / 60)
            $remainingSec = [math]::Floor($remaining % 60)
            
            Write-Progress -Activity "Telechargement des images" `
                          -Status "$currentCount / $($items.Count) fichiers | Restant : ${remainingMin}m ${remainingSec}s | Vitesse : $([math]::Round($speed, 2)) img/s" `
                          -PercentComplete $percent
        } else {
            Write-Progress -Activity "Telechargement des images" `
                          -Status "$currentCount / $($items.Count) fichiers" `
                          -PercentComplete $percent
        }
        
        $lastCount = $currentCount
    }
}

Write-Progress -Activity "Telechargement des images" -Completed

$aria2Process.WaitForExit()
$exitCode = $aria2Process.ExitCode

# Nettoyer les fichiers temporaires de redirection
Remove-Item $aria2StdOut -Force -ErrorAction SilentlyContinue
Remove-Item $aria2StdErr -Force -ErrorAction SilentlyContinue

# Vérifier les résultats
$downloadedImages = @(Get-ChildItem -Path $TempDir -File -Filter "*.jpg")

if ($downloadedImages.Count -eq 0) {
    Write-Host ""
    Write-ErrorMsg "Aucune image telechargee"
    
    # Afficher les dernières lignes du log en cas d'erreur totale
    if (Test-Path $aria2LogFile) {
        Write-Host ""
        Write-ColorHost "Dernieres lignes du log aria2 :" -Color "Yellow"
        Get-Content $aria2LogFile -Tail 15 | ForEach-Object {
            Write-ColorHost "  $_" -Color "Gray"
        }
    }
    
    Remove-Item -Path $TempDir -Recurse -Force
    Write-Host ""
    Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    return
}

$elapsed = ((Get-Date) - $startTime).TotalSeconds
$avgSpeed = [math]::Round($downloadedImages.Count / $elapsed, 2)

Write-Host ""
Write-Success "$($downloadedImages.Count) image(s) telechargee(s) en $([math]::Round($elapsed, 1)) secondes"
Write-ColorHost "  Vitesse moyenne : $avgSpeed images/seconde" -Color "Gray"

# Vérifier s'il manque des fichiers
$missingCount = $items.Count - $downloadedImages.Count
if ($missingCount -gt 0) {
    Write-ColorHost "  Attention : $missingCount fichier(s) manquant(s)" -Color "Yellow"
    Write-ColorHost "  Consultez le log : $aria2LogFile" -Color "Gray"
}

# Code de sortie 0 ou 1 accepté (1 = fichiers déjà existants)
if ($exitCode -gt 1) {
    Write-ErrorMsg "Aria2 a termine avec des erreurs (code $exitCode)"
    Write-ColorHost "  Consultez le log : $aria2LogFile" -Color "Yellow"
}


# ======================= VERIFICATION MANUELLE =======================

Write-Host ""
Write-Header "VERIFICATION DES IMAGES"

Write-ColorHost "Souhaitez-vous verifier manuellement les images telechargees ?" -Color "Cyan"
Write-ColorHost "Cela permet de supprimer les images corrompues ou indesirables." -Color "Gray"
Write-Host ""
$response = Read-Host "Ouvrir le dossier pour verification ? (O/n)"

if ($response -eq '' -or $response -match '^[oO]') {
    Write-Step "Ouverture du dossier : $TempDir"
    Start-Process explorer.exe -ArgumentList "`"$TempDir`""
    
    Write-Host ""
    Write-ColorHost "Supprimez les images que vous ne souhaitez pas inclure dans le timelapse." -Color "Yellow"
    Write-ColorHost "Une fois termine, appuyez sur une touche pour continuer..." -Color "Yellow"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    
    $verifiedImages = @(Get-ChildItem -Path $TempDir -File -Filter "*.jpg")
    
    if ($verifiedImages.Count -eq 0) {
        Write-Host ""
        Write-ErrorMsg "Aucune image restante apres verification"
        Remove-Item -Path $TempDir -Recurse -Force
        Write-Host ""
        Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    $removedCount = $downloadedImages.Count - $verifiedImages.Count
    if ($removedCount -gt 0) {
        Write-Success "$removedCount image(s) supprimee(s)"
    }
    Write-Success "$($verifiedImages.Count) image(s) validee(s) pour le timelapse"
    
    $downloadedImages = $verifiedImages
} else {
    Write-Step "Verification manuelle ignoree"
}

# ======================= CREATION DU TIMELAPSE =======================

Write-Header "CREATION DU TIMELAPSE"

$outputFileName = "timelapse_${satelliteName}_${resolution}_$($dateRange.Start.ToString('yyyyMMdd'))-$($dateRange.End.ToString('yyyyMMdd')).mp4"
$outputFile = Join-Path $ScriptDir $outputFileName

$sortedImages = $downloadedImages | Sort-Object Name

Write-Step "Generation de la liste d'images pour FFmpeg..."

$listFile = Join-Path $TempDir "ffmpeg_list.txt"
$fps = 30
$duration = [string](1.0 / [double]$fps)

function To-FfmpegPath([string]$p) {
    ($p -replace '\\','/') -replace "'", "''"
}

$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $sortedImages.Count; $i++) {
    $p = To-FfmpegPath $sortedImages[$i].FullName
    [void]$sb.AppendLine("file '$p'")
    if ($i -lt $sortedImages.Count - 1) {
        [void]$sb.AppendLine("duration $duration")
    }
}
$lastPath = To-FfmpegPath $sortedImages[-1].FullName
[void]$sb.AppendLine("file '$lastPath'")

[System.IO.File]::WriteAllText($listFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))

Write-Success "Liste d'images creee"

$ffmpegArgs = "-hide_banner -loglevel warning -stats -f concat -safe 0 -i `"$listFile`" -vsync vfr -c:v libx264 -pix_fmt yuv420p -crf 18 -preset medium -movflags +faststart -y `"$outputFile`""

Write-Step "Encodage video en cours..."
Write-ColorHost -Message "  Resolution : $resolution | FPS : $fps | Codec : H.264" -Color "Gray"
Write-ColorHost -Message "  Cela peut prendre plusieurs minutes selon le nombre d'images..." -Color "Gray"

$ffmpegProcess = Start-Process -FilePath $config.FfmpegPath `
                               -ArgumentList $ffmpegArgs `
                               -NoNewWindow -PassThru `
                               -Wait `
                               -RedirectStandardError (Join-Path $TempDir "ffmpeg_log.txt")

if ($ffmpegProcess.ExitCode -ne 0) {
    Write-ErrorMsg "Erreur lors de l'encodage (code $($ffmpegProcess.ExitCode))"
    $errLog = Get-Content (Join-Path $TempDir "ffmpeg_log.txt") -Raw -ErrorAction SilentlyContinue
    if ($errLog) { Write-Host $errLog }
    Remove-Item -Path $TempDir -Recurse -Force
    Write-Host ""
    Write-ColorHost "Appuyez sur une touche pour quitter..." -Color "Gray"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    return
}

Write-Success "Video creee avec succes !"

# ======================= NETTOYAGE =======================

Write-Header "FINALISATION"

Write-Step "Nettoyage du dossier temporaire..."
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Success "Dossier temporaire supprime"

# ======================= RESUME =======================

Write-Host ""
Write-ColorHost -Message "===============================================================" -Color "Green"
Write-ColorHost -Message "                    TRAITEMENT TERMINE                         " -Color "Green"
Write-ColorHost -Message "===============================================================" -Color "Green"
Write-Host ""
Write-ColorHost -Message "  Satellite       : " -Color "Cyan" -NoNewline; Write-Host $satelliteName
Write-ColorHost -Message "  Resolution      : " -Color "Cyan" -NoNewline; Write-Host $resolution
Write-ColorHost -Message "  Periode         : " -Color "Cyan" -NoNewline; Write-Host "$($dateRange.Start.ToString('dd/MM/yyyy')) -> $($dateRange.End.ToString('dd/MM/yyyy'))"
Write-ColorHost -Message "  Images utilisees: " -Color "Cyan" -NoNewline; Write-Host $sortedImages.Count
Write-ColorHost -Message "  Duree video     : " -Color "Cyan" -NoNewline; Write-Host "$([math]::Round($sortedImages.Count / $fps, 1)) secondes"
Write-ColorHost -Message "  Fichier cree    : " -Color "Cyan" -NoNewline; Write-Host $outputFileName
Write-Host ""
Write-ColorHost -Message "  Emplacement : $outputFile" -Color "Yellow"
Write-Host ""

$response = Read-Host "Ouvrir le dossier de destination ? (O/n)"
if ($response -eq '' -or $response -match '^[oO]') {
    Start-Process explorer.exe -ArgumentList "/select,`"$outputFile`""
}

Write-Host ""
Write-ColorHost -Message "Appuyez sur une touche pour quitter..." -Color "Gray"
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
