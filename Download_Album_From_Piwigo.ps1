<#
.SYNOPSIS
    Piwigo gallery downloader via API
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Piwigo Gallery Downloader"               -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# --- Inputs ---
$GalleryUrl = Read-Host "URL de la galerie Piwigo (ex: https://site.com/index.php?/category/12)"
if ([string]::IsNullOrWhiteSpace($GalleryUrl)) { throw "URL obligatoire." }

$Parallel = 5
do {
    $p = Read-Host "Telechargements paralleles [1-20] (defaut 5)"
    if ([string]::IsNullOrWhiteSpace($p)) { $Parallel = 5; break }
} while (-not ([int]::TryParse($p, [ref]$Parallel)) -or $Parallel -lt 1 -or $Parallel -gt 20)

Write-Host "Tailles : original | large | medium | small | thumb"
$Size = Read-Host "Taille (defaut original)"
if ([string]::IsNullOrWhiteSpace($Size)) { $Size = 'original' }

$rec = Read-Host "Inclure les sous-albums recursivement ? [O/n]"
$Recursive = -not ($rec -match '^[nN]')

$ow = Read-Host "Ecraser les fichiers existants ? [o/N]"
$Overwrite = ($ow -match '^[oOyY]')

$ins = Read-Host "Ignorer la verification SSL ? [o/N]"
$Insecure = ($ins -match '^[oOyY]')

$au = Read-Host "Galerie privee (authentification) ? [o/N]"
$UseAuth = ($au -match '^[oOyY]')
$Username = ''; $Password = ''
if ($UseAuth) {
    $Username = Read-Host "Nom d'utilisateur"
    $SecPwd   = Read-Host "Mot de passe" -AsSecureString
    $Password = [System.Net.NetworkCredential]::new('', $SecPwd).Password
}

$DestDir = Read-Host "Dossier de destination (vide = a cote du script)"

# --- SSL bypass for PS 5.1 ---
$script:SkipSSL = $Insecure
if ($Insecure -and $PSVersionTable.PSVersion.Major -lt 6) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# --- Helper: build query URL safely ---
function Build-Url {
    param([string]$Base, [hashtable]$Params)
    $parts = @()
    foreach ($k in $Params.Keys) {
        $v = [System.Uri]::EscapeDataString([string]$Params[$k])
        $parts += "$k=$v"
    }
    $sep = if ($Base.Contains('?')) { '&' } else { '?' }
    return $Base + $sep + ($parts -join '&')
}

function Invoke-Api {
    param(
        [string]$ApiBase,
        [hashtable]$Query,
        [hashtable]$PostBody,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )
    $url = Build-Url -Base $ApiBase -Params $Query
    $params = @{
        Uri = $url
        WebSession = $Session
        UseBasicParsing = $true
    }
    if ($PostBody) {
        $params.Method = 'POST'
        $params.Body = $PostBody
    }
    if ($script:SkipSSL -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params.SkipCertificateCheck = $true
    }
    return Invoke-RestMethod @params
}

# --- Parse URL ---
$uri = [Uri]$GalleryUrl
$BaseUrl = "$($uri.Scheme)://$($uri.Authority)"
if ($uri.AbsolutePath -match '^(.*?)/index\.php') {
    if ($Matches[1]) { $BaseUrl += $Matches[1] }
} elseif ($uri.AbsolutePath -and $uri.AbsolutePath -ne '/') {
    $BaseUrl += ($uri.AbsolutePath.TrimEnd('/'))
}

$CatId = $null
if ("$GalleryUrl" -match 'category/(\d+)') { $CatId = $Matches[1] }
if (-not $CatId) { $CatId = Read-Host "ID de categorie introuvable, saisissez-le" }

$ApiBase = "$BaseUrl/ws.php"
$ApiQueryBase = @{ format = 'json' }

Write-Host "-> Base URL  : $BaseUrl"
Write-Host "-> Categorie : $CatId"

$Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# --- Login ---
if ($UseAuth) {
    Write-Host "-> Authentification..."
    $login = Invoke-Api -ApiBase $ApiBase -Query $ApiQueryBase -Session $Session -PostBody @{
        method   = 'pwg.session.login'
        username = $Username
        password = $Password
    }
    if ($login.stat -ne 'ok') { throw "Echec authentification" }
    Write-Host "   OK"
}

# --- Album info ---
$catInfo = Invoke-Api -ApiBase $ApiBase -Session $Session -Query @{
    format = 'json'
    method = 'pwg.categories.getList'
    cat_id = $CatId
}
$AlbumName = $catInfo.result.categories[0].name
if (-not $AlbumName) { $AlbumName = "piwigo-album" }
$invalid = [IO.Path]::GetInvalidFileNameChars()
$AlbumNameSafe = -join ($AlbumName.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } })

if ([string]::IsNullOrWhiteSpace($DestDir)) {
    $DestDir = Join-Path $ScriptDir $AlbumNameSafe
}
if (-not (Test-Path -LiteralPath $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}
Write-Host "-> Dossier   : $DestDir"

# --- List images ---
Write-Host "-> Recuperation de la liste..."
$Images = New-Object System.Collections.Generic.List[object]
$page = 0
$perPage = 500
$recFlag = if ($Recursive) { 'true' } else { 'false' }

do {
    $resp = Invoke-Api -ApiBase $ApiBase -Session $Session -Query @{
        format    = 'json'
        method    = 'pwg.categories.getImages'
        cat_id    = $CatId
        recursive = $recFlag
        per_page  = $perPage
        page      = $page
    }
    $batch = $resp.result.images
    if (-not $batch) { break }
    foreach ($img in $batch) {
        $url = switch ($Size) {
            'original' { if ($img.element_url) { $img.element_url } else { $img.derivatives.medium.url } }
            'large'    { if ($img.derivatives.large) { $img.derivatives.large.url } else { $img.element_url } }
            'medium'   { $img.derivatives.medium.url }
            'small'    { if ($img.derivatives.small) { $img.derivatives.small.url } else { $img.derivatives.medium.url } }
            'thumb'    { $img.derivatives.thumb.url }
            default    { $img.element_url }
        }
        $Images.Add([pscustomobject]@{
            Id   = $img.id
            Url  = $url
            File = $img.file
        })
    }
    $count = $batch.Count
    $page++
} while ($count -ge $perPage)

Write-Host "-> $($Images.Count) image(s) trouvee(s)"
if ($Images.Count -eq 0) { return }

# --- Cookies header for parallel downloads ---
$cookieHeader = ''
foreach ($c in $Session.Cookies.GetCookies($BaseUrl)) {
    $cookieHeader += "$($c.Name)=$($c.Value); "
}

Write-Host ("-> Telechargement ({0} en parallele)..." -f $Parallel)

if ($PSVersionTable.PSVersion.Major -ge 7) {
    $Images | ForEach-Object -ThrottleLimit $Parallel -Parallel {
        $img       = $_
        $dest      = Join-Path $using:DestDir ("{0}_{1}" -f $img.Id, $img.File)
        $overwrite = $using:Overwrite
        $insecure  = $using:Insecure
        $cookie    = $using:cookieHeader

        if ((Test-Path -LiteralPath $dest) -and -not $overwrite) {
            Write-Host "  [skip] $($img.File)"
            return
        }
        try {
            $params = @{
                Uri = $img.Url
                OutFile = $dest
                Headers = @{ Cookie = $cookie }
                UseBasicParsing = $true
            }
            if ($insecure) { $params.SkipCertificateCheck = $true }
            Invoke-WebRequest @params
            Write-Host "  [ok]   $($img.File)"
        } catch {
            Write-Host "  [FAIL] $($img.File) : $_"
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        }
    }
} else {
    $queue = [System.Collections.Queue]::new()
    $Images | ForEach-Object { $queue.Enqueue($_) }
    $running = @()
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($running.Count -lt $Parallel -and $queue.Count -gt 0) {
            $img = $queue.Dequeue()
            $job = Start-Job -ArgumentList $img, $DestDir, $Overwrite, $cookieHeader, $Insecure -ScriptBlock {
                param($img, $DestDir, $Overwrite, $cookie, $insecure)
                if ($insecure) {
                    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllJob : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
                    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllJob
                    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
                }
                $dest = Join-Path $DestDir ("{0}_{1}" -f $img.Id, $img.File)
                if ((Test-Path -LiteralPath $dest) -and -not $Overwrite) {
                    return "[skip] $($img.File)"
                }
                try {
                    Invoke-WebRequest -Uri $img.Url -OutFile $dest -Headers @{Cookie=$cookie} -UseBasicParsing
                    return "[ok]   $($img.File)"
                } catch {
                    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
                    return "[FAIL] $($img.File)"
                }
            }
            $running += $job
        }
        Start-Sleep -Milliseconds 200
        $done = $running | Where-Object { $_.State -ne 'Running' }
        foreach ($j in $done) {
            Receive-Job $j | ForEach-Object { Write-Host "  $_" }
            Remove-Job $j
        }
        $running = @($running | Where-Object { $_.State -eq 'Running' })
    }
}

if ($UseAuth) {
    try {
        Invoke-Api -ApiBase $ApiBase -Session $Session -Query @{
            format = 'json'; method = 'pwg.session.logout'
        } | Out-Null
    } catch {}
}

Write-Host ""
Write-Host "Termine. Fichiers dans : $DestDir" -ForegroundColor Green
