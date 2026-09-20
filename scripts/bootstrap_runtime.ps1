#Requires -Version 5.1
<#
.SYNOPSIS
    Telecharge, extrait et verifie les runtimes tiers portables pour le module Web Media.
    Aucun modele IA n'est telecharge par ce script.
#>
[CmdletBinding()]
param(
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$runtimeDir = Join-Path $repoRoot "CrisperWeaver\runtime\web_media"
$null = New-Item -ItemType Directory -Path $runtimeDir -Force

$checksumFile = Join-Path $runtimeDir "SHA2-256SUMS"
if (-not (Test-Path $checksumFile)) {
    throw "Fichier de sommes de controle introuvable : $checksumFile"
}

# Lecture des sommes de controle de reference
$expectedHashes = @{}
Get-Content $checksumFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $parts = $line -split '\s+'
        if ($parts.Count -ge 2) {
            $expectedHashes[$parts[1].Trim()] = $parts[0].Trim().ToLower()
        }
    }
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     Bootstrap et Verification des Runtimes Tiers Web Media      " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Dossier cible : $runtimeDir"
Write-Host ""

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "jarvisol_bootstrap_$(Get-Random)"
$null = New-Item -ItemType Directory -Path $tempDir -Force

try {
    # 1. yt-dlp.exe
    $ytdlpPath = Join-Path $runtimeDir "yt-dlp.exe"
    $ytdlpValid = $false
    if (Test-Path $ytdlpPath) {
        $h = (Get-FileHash $ytdlpPath -Algorithm SHA256).Hash.ToLower()
        if ($h -eq $expectedHashes["yt-dlp.exe"]) { $ytdlpValid = $true }
    }
    if (-not $ytdlpValid) {
        if ($VerifyOnly) { throw "yt-dlp.exe manquant ou invalide et -VerifyOnly specifie." }
        Write-Host "==> Telechargement de yt-dlp.exe (2026.08.19)..." -ForegroundColor Yellow
        $url = "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp.exe"
        & curl.exe -L -o $ytdlpPath $url
        if ($LASTEXITCODE -ne 0) { throw "Echec du telechargement de yt-dlp.exe" }
    }

    # 2. deno.exe
    $denoPath = Join-Path $runtimeDir "deno.exe"
    $denoValid = $false
    if (Test-Path $denoPath) {
        $h = (Get-FileHash $denoPath -Algorithm SHA256).Hash.ToLower()
        if ($h -eq $expectedHashes["deno.exe"]) { $denoValid = $true }
    }
    if (-not $denoValid) {
        if ($VerifyOnly) { throw "deno.exe manquant ou invalide et -VerifyOnly specifie." }
        Write-Host "==> Telechargement de Deno v2.9.6..." -ForegroundColor Yellow
        $denoZip = Join-Path $tempDir "deno.zip"
        $url = "https://github.com/denoland/deno/releases/download/v2.9.6/deno-x86_64-pc-windows-msvc.zip"
        & curl.exe -L -o $denoZip $url
        if ($LASTEXITCODE -ne 0) { throw "Echec du telechargement de Deno" }
        Expand-Archive -Path $denoZip -DestinationPath $runtimeDir -Force
        Remove-Item $denoZip -Force -ErrorAction SilentlyContinue
    }

    # 3. ffmpeg.exe & ffprobe.exe
    $ffmpegPath  = Join-Path $runtimeDir "ffmpeg.exe"
    $ffprobePath = Join-Path $runtimeDir "ffprobe.exe"
    $ffmpegValid = $false
    $ffprobeValid = $false
    if (Test-Path $ffmpegPath) {
        $h = (Get-FileHash $ffmpegPath -Algorithm SHA256).Hash.ToLower()
        if ($h -eq $expectedHashes["ffmpeg.exe"]) { $ffmpegValid = $true }
    }
    if (Test-Path $ffprobePath) {
        $h = (Get-FileHash $ffprobePath -Algorithm SHA256).Hash.ToLower()
        if ($h -eq $expectedHashes["ffprobe.exe"]) { $ffprobeValid = $true }
    }
    if (-not ($ffmpegValid -and $ffprobeValid)) {
        if ($VerifyOnly) { throw "ffmpeg.exe/ffprobe.exe manquant ou invalide et -VerifyOnly specifie." }
        Write-Host "==> Telechargement de FFmpeg 8.0 (gyan.dev)..." -ForegroundColor Yellow
        $ffmpegZip = Join-Path $tempDir "ffmpeg.zip"
        $ffmpegExtract = Join-Path $tempDir "ffmpeg_ext"
        $url = "https://github.com/GyanD/codexffmpeg/releases/download/8.0/ffmpeg-8.0-full_build.zip"
        & curl.exe -L -o $ffmpegZip $url
        if ($LASTEXITCODE -ne 0) { throw "Echec du telechargement de FFmpeg" }
        Expand-Archive -Path $ffmpegZip -DestinationPath $ffmpegExtract -Force
        $candFfmpeg = Get-ChildItem -Path $ffmpegExtract -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
        $candFfprobe = Get-ChildItem -Path $ffmpegExtract -Filter "ffprobe.exe" -Recurse | Select-Object -First 1
        if ($candFfmpeg) { Copy-Item $candFfmpeg.FullName $ffmpegPath -Force }
        if ($candFfprobe) { Copy-Item $candFfprobe.FullName $ffprobePath -Force }
        Remove-Item $ffmpegExtract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $ffmpegZip -Force -ErrorAction SilentlyContinue
    }

    # 4. Verification finale SHA-256
    Write-Host "`n==> Verification des sommes de controle SHA-256 :" -ForegroundColor Cyan
    $allHashOk = $true
    foreach ($fn in @("yt-dlp.exe", "deno.exe", "ffmpeg.exe", "ffprobe.exe")) {
        $p = Join-Path $runtimeDir $fn
        if (-not (Test-Path $p)) {
            Write-Host "  [FAIL] $fn introuvable !" -ForegroundColor Red
            $allHashOk = $false
            continue
        }
        $actual = (Get-FileHash $p -Algorithm SHA256).Hash.ToLower()
        $expected = $expectedHashes[$fn]
        if ($actual -eq $expected) {
            Write-Host "  [PASS] $fn : $actual" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] $fn : empreinte invalide !" -ForegroundColor Red
            Write-Host "         Attendu : $expected" -ForegroundColor DarkGray
            Write-Host "         Obtenu  : $actual" -ForegroundColor Red
            $allHashOk = $false
        }
    }

    # 5. Verification des licences tierces
    Write-Host "`n==> Verification des licences tierces :" -ForegroundColor Cyan
    $licensesDir = Join-Path $runtimeDir "licenses"
    $allLicOk = $true
    foreach ($lic in @("LICENSE_yt-dlp.txt", "LICENSE_deno.txt", "LICENSE_ffmpeg.txt")) {
        $licPath = Join-Path $licensesDir $lic
        if (Test-Path $licPath) {
            Write-Host "  [PASS] Licence presente : $lic" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] Licence manquante : $lic" -ForegroundColor Red
            $allLicOk = $false
        }
    }

    if (-not ($allHashOk -and $allLicOk)) {
        throw "La verification cryptographique ou documentaire des runtimes Web Media a echoue."
    }

    Write-Host "`n================================================================" -ForegroundColor Green
    Write-Host "   RUNTIMES TIERS WEB MEDIA PRETS ET VERIFIES AVEC SUCCES !     " -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
} finally {
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
