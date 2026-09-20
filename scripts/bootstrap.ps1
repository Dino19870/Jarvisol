#Requires -Version 5.1
<#
.SYNOPSIS
    Prepare l'environnement de developpement et resout les dependances publiques.
    Ne telecharge AUCUN modele IA.
#>
[CmdletBinding()]
param(
    [switch]$WithWebMediaRuntime
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path

# Resolution de Flutter dans la session
$flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutterCmd) {
    if ($env:FLUTTER_ROOT -and (Test-Path "$env:FLUTTER_ROOT\bin\flutter.bat")) {
        $env:PATH = "$env:FLUTTER_ROOT\bin;$env:PATH"
    } elseif (Test-Path "$PSScriptRoot\..\..\flutter\bin\flutter.bat") {
        $cand = (Resolve-Path "$PSScriptRoot\..\..\flutter\bin").Path
        $env:PATH = "$cand;$env:PATH"
    }
}

Write-Host "==> Execution de verify_environment.ps1" -ForegroundColor Cyan
& "$PSScriptRoot\verify_environment.ps1"
if ($LASTEXITCODE -ne 0) {
    throw "Echec de verification des prerequis."
}

Write-Host "`n==> Resolution des dependances Flutter (flutter pub get)" -ForegroundColor Cyan

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
            & flutter.bat pub get
            if ($LASTEXITCODE -ne 0) { throw "flutter pub get a echoue dans $proj" }
        } finally {
            Pop-Location
        }
    }
}

if ($WithWebMediaRuntime) {
    Write-Host "`n==> Telechargement et verification des runtimes Web Media portables..." -ForegroundColor Cyan
    & "$PSScriptRoot\bootstrap_runtime.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Echec de bootstrap_runtime.ps1" }
} else {
    Write-Host "`n[Note] Runtimes Web Media et modeles IA non telecharges (utilisez -WithWebMediaRuntime si necessaire)." -ForegroundColor DarkGray
}

Write-Host "`n==> Bootstrap termine avec succes !" -ForegroundColor Green
exit 0
