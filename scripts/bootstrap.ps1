#Requires -Version 5.1
<#
.SYNOPSIS
    Prépare l'environnement de développement et résout les dépendances publiques.
    Ne télécharge AUCUN modèle IA par défaut.
#>
[CmdletBinding()]
param(
    [switch]$WithWebMediaRuntime
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path

Write-Host "==> Exécution de verify_environment.ps1" -ForegroundColor Cyan
& "$PSScriptRoot\verify_environment.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Échec de vérification des prérequis."
    exit 1
}

Write-Host "`n==> Résolution des dépendances Flutter (flutter pub get)" -ForegroundColor Cyan

$flutterProjects = @(
    (Join-Path $repoRoot "CrisperWeaver"),
    (Join-Path $repoRoot "CrispASR\flutter\crispasr"),
    (Join-Path $repoRoot "CrispEmbed\flutter\crispembed"),
    (Join-Path $repoRoot "glint\bindings\dart")
)

foreach ($proj in $flutterProjects) {
    if (Test-Path (Join-Path $proj "pubspec.yaml")) {
        Write-Host "  -> flutter pub get dans $proj" -ForegroundColor Yellow
        Push-Location $proj
        try {
            & flutter pub get
            if ($LASTEXITCODE -ne 0) { throw "flutter pub get a échoué dans $proj" }
        } finally {
            Pop-Location
        }
    }
}

if ($WithWebMediaRuntime) {
    Write-Host "`n==> Téléchargement des runtimes Web Media portables (yt-dlp, deno, ffmpeg)..." -ForegroundColor Cyan
    & "$PSScriptRoot\bootstrap_runtime.ps1"
} else {
    Write-Host "`n[Note] Runtimes Web Media et modèles IA non téléchargés (utilisez -WithWebMediaRuntime si nécessaire)." -ForegroundColor DarkGray
}

Write-Host "`n==> Bootstrap terminé avec succès !" -ForegroundColor Green
exit 0
