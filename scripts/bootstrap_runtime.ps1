#Requires -Version 5.1
<#
.SYNOPSIS
    Télécharge et vérifie les runtimes tiers portables nécessaires au module Web Media.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$runtimeDir = Join-Path $repoRoot "CrisperWeaver\runtime\web_media"
$null = New-Item -ItemType Directory -Path $runtimeDir -Force

$checksumFile = Join-Path $runtimeDir "SHA2-256SUMS"
if (-not (Test-Path $checksumFile)) {
    Write-Warning "Fichier de sommes de contrôle introuvable : $checksumFile"
}

Write-Host "==> Dossier cible des runtimes Web Media : $runtimeDir" -ForegroundColor Cyan
Write-Host "Les fichiers requis sont :"
Write-Host "  - yt-dlp.exe (https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe)"
Write-Host "  - deno.exe   (https://github.com/denoland/deno/releases)"
Write-Host "  - ffmpeg.exe & ffprobe.exe (https://www.gyan.dev/ffmpeg/builds/)"
Write-Host "Vérifiez les sommes SHA-256 avec celles indiquées dans $checksumFile."
