<#
.SYNOPSIS
    Téléchargement et vérification d'intégrité SHA-256 des modèles d'image pour Jarvisol.

.DESCRIPTION
    Ce script télécharge les modèles d'images (Text-to-Image, Inpainting, IP-Adapter,
    ADetailer Face YOLOv8) selon le manifeste canonique docs/image_models_manifest.json.
    Supporte les packs logiques, le mode simulation (-DryRun), le listing (-List)
    et garantit un renommage atomique (.part -> fichier final) après vérification SHA-256.

.PARAMETER Pack
    Nom du pack à télécharger :
    - IMAGE_BASIC      : DiT rapide Chroma Flash + VAE + T5-XXL (~7.94 Go)
    - IMAGE_INPAINT    : Inpainting SD 1.5 FP16 + VAE (~2.30 Go)
    - IMAGE_MULTI_SD15 : Inpaint + Clip Vision ViT-H + IP-Adapter (+ Face) (~4.84 Go)
    - IMAGE_AUTO_FACE  : Multi-SD15 + Détecteur YOLOv8n Face (~4.85 Go)
    - IMAGE_FULL / ALL : Ensemble des 19 modèles de production (~70.8 Go)

.PARAMETER Model
    Identifiant ou nom de fichier d'un modèle spécifique (ex: clip_vision_vit_h, face_yolov8n).

.PARAMETER List
    Affiche la liste des packs, modèles, tailles et état d'installation local.

.PARAMETER DryRun
    Simule les téléchargements sans récupérer les fichiers.

.PARAMETER Destination
    Dossier racine d'installation (par défaut: racine du dépôt Jarvisol).

.PARAMETER Force
    Force le re-téléchargement même si le fichier est déjà présent et valide.

.EXAMPLE
    .\scripts\download_image_models.ps1 -List
    .\scripts\download_image_models.ps1 -Pack IMAGE_AUTO_FACE -DryRun
    .\scripts\download_image_models.ps1 -Pack IMAGE_AUTO_FACE
    .\scripts\download_image_models.ps1 -Model clip_vision_vit_h
#>

[CmdletBinding()]
param(
    [ValidateSet("IMAGE_BASIC", "IMAGE_INPAINT", "IMAGE_MULTI_SD15", "IMAGE_AUTO_FACE", "IMAGE_FULL", "ALL")]
    [string]$Pack,

    [string]$Model,

    [switch]$List,

    [switch]$DryRun,

    [string]$Destination,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
} catch {
    # Déjà chargé ou géré par l'environnement
}

# Détermination du dossier racine Jarvisol
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = $RepoRoot
}

$ManifestPath = Join-Path $RepoRoot "docs\image_models_manifest.json"
if (-not (Test-Path $ManifestPath)) {
    # Recherche dans le dossier courant si exécuté ailleurs
    $AltManifest = Join-Path (Get-Location) "docs\image_models_manifest.json"
    if (Test-Path $AltManifest) {
        $ManifestPath = $AltManifest
    } else {
        Write-Error "Impossible de trouver le manifeste : $ManifestPath"
        exit 1
    }
}

$Manifest = Get-Content -Raw -Encoding UTF8 -Path $ManifestPath | ConvertFrom-Json

function Format-Bytes([long]$Bytes) {
    if ($Bytes -ge 1GB) {
        return ("{0:N2} Go" -f ($Bytes / 1GB))
    } elseif ($Bytes -ge 1MB) {
        return ("{0:N2} Mo" -f ($Bytes / 1MB))
    } elseif ($Bytes -ge 1KB) {
        return ("{0:N2} Ko" -f ($Bytes / 1KB))
    } else {
        return "$Bytes octets"
    }
}

# --- Traitement de l'option -List ---
if ($List) {
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "          JARVISOL - CATALOGUE DES PACKS ET MODÈLES D'IMAGES                   " -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "Destination d'installation : $Destination`n"

    Write-Host "--- PACKS DISPONIBLES ---" -ForegroundColor Yellow
    foreach ($packKey in $Manifest.packs.PSObject.Properties.Name) {
        $p = $Manifest.packs.$packKey
        Write-Host ("  [{0}] {1}" -f $p.name, $p.description) -ForegroundColor Green
        Write-Host ("       Fichiers: {0} | Taille totale: {1}" -f $p.files.Count, $p.total_size_human) -ForegroundColor Gray
    }

    Write-Host "`n--- DÉTAIL DES 19 MODÈLES ---" -ForegroundColor Yellow
    foreach ($m in $Manifest.models) {
        $targetFile = Join-Path $Destination $m.relative_path
        $status = "[MANQUANT]"
        $statusColor = "Red"
        if (Test-Path $targetFile) {
            $fInfo = Get-Item $targetFile
            if ($fInfo.Length -eq $m.size_bytes) {
                $status = "[PRÉSENT - TAILLE OK]"
                $statusColor = "Green"
            } else {
                $status = "[PRÉSENT - TAILLE INCORRECTE]"
                $statusColor = "Yellow"
            }
        }
        Write-Host ("  {0,-35} | {1,-10} | {2,-10} | {3}" -f $m.filename, (Format-Bytes $m.size_bytes), $m.architecture, $status) -ForegroundColor $statusColor
    }
    Write-Host ""
    exit 0
}

# --- Validation des paramètres ---
if ([string]::IsNullOrWhiteSpace($Pack) -and [string]::IsNullOrWhiteSpace($Model)) {
    Write-Host "Aucun pack ou modèle spécifié. Utilisez -List pour afficher les options ou -Pack <PACK>." -ForegroundColor Yellow
    Write-Host "Exemples :"
    Write-Host "  .\scripts\download_image_models.ps1 -List"
    Write-Host "  .\scripts\download_image_models.ps1 -Pack IMAGE_AUTO_FACE"
    Write-Host "  .\scripts\download_image_models.ps1 -Pack IMAGE_BASIC -DryRun"
    exit 0
}

# Résolution des fichiers cibles
$FilesToDownload = [System.Collections.Generic.List[string]]::new()

if ($Pack -eq "ALL" -or $Pack -eq "IMAGE_FULL") {
    $Pack = "IMAGE_FULL"
}

if (-not [string]::IsNullOrWhiteSpace($Pack)) {
    $packDef = $Manifest.packs.$Pack
    if ($null -eq $packDef) {
        Write-Error "Pack inconnu : '$Pack'. Packs valides : IMAGE_BASIC, IMAGE_INPAINT, IMAGE_MULTI_SD15, IMAGE_AUTO_FACE, IMAGE_FULL, ALL."
        exit 1
    }
    foreach ($f in $packDef.files) {
        $FilesToDownload.Add($f)
    }
    Write-Host ("Sélection du Pack : [{0}] ({1} fichiers, {2})" -f $packDef.name, $packDef.files.Count, $packDef.total_size_human) -ForegroundColor Cyan
}

if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $found = $false
    foreach ($m in $Manifest.models) {
        if ($m.id -eq $Model -or $m.filename -eq $Model -or $m.filename -like "$Model*") {
            if (-not $FilesToDownload.Contains($m.relative_path)) {
                $FilesToDownload.Add($m.relative_path)
            }
            $found = $true
        }
    }
    if (-not $found) {
        Write-Error "Modèle introuvable pour '$Model'. Utilisez -List pour consulter les identifiants disponibles."
        exit 1
    }
}

Write-Host "Destination : $Destination" -ForegroundColor Gray
Write-Host "Fichiers à traiter : $($FilesToDownload.Count)`n" -ForegroundColor Gray

# Préparation du client HTTP
$httpClient = [System.Net.Http.HttpClient]::new()
$httpClient.DefaultRequestHeaders.Add("User-Agent", "Jarvisol-Model-Installer/1.0")
$httpClient.Timeout = [System.TimeSpan]::FromHours(4)

$totalExpectedBytes = 0
$pendingModels = [System.Collections.Generic.List[PSObject]]::new()

foreach ($relPath in $FilesToDownload) {
    $modelDef = $Manifest.models | Where-Object { $_.relative_path -eq $relPath } | Select-Object -First 1
    if ($null -eq $modelDef) {
        Write-Warning "Fichier dans le pack mais absent de la liste des modèles : $relPath"
        continue
    }

    $finalPath = Join-Path $Destination $modelDef.relative_path
    $needsDownload = $true

    if ((Test-Path $finalPath) -and (-not $Force)) {
        $fInfo = Get-Item $finalPath
        if ($fInfo.Length -eq $modelDef.size_bytes) {
            Write-Host ("  [EXISTS] {0} ({1}) - Vérification SHA-256..." -f $modelDef.filename, (Format-Bytes $modelDef.size_bytes)) -ForegroundColor Gray
            $existingHash = (Get-FileHash -Algorithm SHA256 -Path $finalPath).Hash.ToUpperInvariant()
            if ($existingHash -eq $modelDef.sha256.ToUpperInvariant()) {
                Write-Host ("  [VALID]  {0} : Déjà présent et intègre." -f $modelDef.filename) -ForegroundColor Green
                $needsDownload = $false
            } else {
                Write-Warning ("  [CORRUPT] {0} : Taille correspondante mais empreinte incorrecte (Attendu: {1}, Obtenu: {2}). Re-téléchargement nécessaire." -f $modelDef.filename, $modelDef.sha256, $existingHash)
            }
        } else {
            Write-Host ("  [TAILLE INVALIDE] {0} : {1} octets au lieu de {2}." -f $modelDef.filename, $fInfo.Length, $modelDef.size_bytes) -ForegroundColor Yellow
        }
    }

    if ($needsDownload) {
        $pendingModels.Add($modelDef)
        $totalExpectedBytes += $modelDef.size_bytes
    }
}

Write-Host ""
if ($pendingModels.Count -eq 0) {
    Write-Host "Tous les modèles demandés sont déjà présents et valides. Aucun téléchargement requis." -ForegroundColor Green
    exit 0
}

Write-Host ("Modèles à télécharger : {0} ({1})" -f $pendingModels.Count, (Format-Bytes $totalExpectedBytes)) -ForegroundColor Yellow

if ($DryRun) {
    Write-Host "`n--- MODE SIMULATION (-DryRun) : AUCUN FICHIER TÉLÉCHARGÉ ---" -ForegroundColor Cyan
    foreach ($m in $pendingModels) {
        $destPath = Join-Path $Destination $m.relative_path
        Write-Host ("  [DRY-RUN] Modèle : {0}" -f $m.filename) -ForegroundColor White
        Write-Host ("            Taille : {0}" -f (Format-Bytes $m.size_bytes)) -ForegroundColor Gray
        Write-Host ("            Cible  : {0}" -f $destPath) -ForegroundColor Gray
        Write-Host ("            URL    : {0}" -f $m.download_url) -ForegroundColor Gray
        Write-Host ("            SHA256 : {0}" -f $m.sha256) -ForegroundColor Gray
    }
    Write-Host "`nSimulation terminée avec succès." -ForegroundColor Green
    exit 0
}

# --- Téléchargement réel ---
$currentIndex = 0
foreach ($m in $pendingModels) {
    $currentIndex++
    $finalPath = Join-Path $Destination $m.relative_path
    $parentDir = Split-Path -Parent $finalPath
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $partPath = "$finalPath.part"
    if (Test-Path $partPath) {
        Remove-Item -Path $partPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host ("`n[{0}/{1}] Téléchargement de {2} ({3})..." -f $currentIndex, $pendingModels.Count, $m.filename, (Format-Bytes $m.size_bytes)) -ForegroundColor Cyan
    Write-Host ("      URL : {0}" -f $m.download_url) -ForegroundColor Gray

    try {
        $response = $httpClient.GetAsync($m.download_url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Erreur HTTP $($response.StatusCode) ($($response.ReasonPhrase))"
        }

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [System.IO.File]::Create($partPath)
        $buffer = [byte[]]::new(1048576) # Tampon de 1 Mo
        $totalRead = 0
        $lastReport = [System.DateTime]::UtcNow

        while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $totalRead += $bytesRead
            
            $now = [System.DateTime]::UtcNow
            if (($now - $lastReport).TotalSeconds -ge 3 -or $totalRead -eq $m.size_bytes) {
                $lastReport = $now
                $percent = if ($m.size_bytes -gt 0) { [math]::Round(($totalRead / $m.size_bytes) * 100, 1) } else { 0 }
                Write-Host ("      Progression : {0} / {1} ({2}%)" -f (Format-Bytes $totalRead), (Format-Bytes $m.size_bytes), $percent) -ForegroundColor Gray
            }
        }

        $fileStream.Flush()
        $fileStream.Close()
        $stream.Close()

        # Contrôle d'intégrité
        Write-Host "      Calcul du hachage SHA-256 de vérification..." -ForegroundColor Gray
        $downloadedHash = (Get-FileHash -Algorithm SHA256 -Path $partPath).Hash.ToUpperInvariant()

        if ($downloadedHash -ne $m.sha256.ToUpperInvariant()) {
            Remove-Item -Path $partPath -Force -ErrorAction SilentlyContinue
            throw "Échec du contrôle d'intégrité SHA-256 pour $($m.filename) !`nAttendu: $($m.sha256)`nReçu:    $downloadedHash"
        }

        # Renommage atomique vers destination finale
        Move-Item -Path $partPath -Destination $finalPath -Force
        Write-Host ("  [SUCCÈS] {0} installé et vérifié avec succès." -f $m.filename) -ForegroundColor Green

    } catch {
        if (Test-Path $partPath) {
            Remove-Item -Path $partPath -Force -ErrorAction SilentlyContinue
        }
        Write-Error "Échec du téléchargement pour $($m.filename) : $_"
        exit 1
    }
}

Write-Host "`nTous les téléchargements demandés ont été validés et installés avec succès !" -ForegroundColor Green
exit 0
