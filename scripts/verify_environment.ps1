#Requires -Version 5.1
<#
.SYNOPSIS
    Vérifie que la chaîne d'outils nécessaire pour compiler Jarvisol est installée sur ce PC Windows.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     Vérification de l'Environnement de Développement Jarvisol   " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$allOk = $true

function Report-Tool {
    param(
        [string]$Name,
        [bool]$Found,
        [string]$Version,
        [string]$Path,
        [bool]$Mandatory = $true
    )
    if ($Found) {
        Write-Host "  [OK]  " -ForegroundColor Green -NoNewline
        Write-Host "$Name : " -NoNewline
        Write-Host "$Version " -ForegroundColor Yellow -NoNewline
        Write-Host "($Path)" -ForegroundColor DarkGray
    } else {
        if ($Mandatory) {
            Write-Host "  [FAIL]" -ForegroundColor Red -NoNewline
            Write-Host " $Name : MANQUANT (Obligatoire pour la compilation)" -ForegroundColor Red
            $script:allOk = $false
        } else {
            Write-Host "  [WARN]" -ForegroundColor DarkYellow -NoNewline
            Write-Host " $Name : Non détecté (Optionnel - requis seulement pour rebuild des helpers)" -ForegroundColor DarkYellow
        }
    }
}

# 1. Git
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd) {
    $v = (& git --version 2>&1) -replace 'git version ',' '
    Report-Tool "Git" $true $v.Trim() $gitCmd.Source $true
} else {
    Report-Tool "Git" $false "" "" $true
}

# 2. Flutter
$flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutterCmd -and (Test-Path "$PSScriptRoot\..\..\flutter\bin\flutter.bat")) {
    $flutterCmd = Get-Item "$PSScriptRoot\..\..\flutter\bin\flutter.bat"
}
if ($flutterCmd) {
    $v = (& $flutterCmd.FullName --version 2>&1 | Select-Object -First 1)
    Report-Tool "Flutter" $true $v.Trim() $flutterCmd.FullName $true
} else {
    Report-Tool "Flutter" $false "" "" $true
}

# 3. Dart
$dartCmd = Get-Command dart -ErrorAction SilentlyContinue
if (-not $dartCmd -and $flutterCmd) {
    $cand = Join-Path (Split-Path (Split-Path $flutterCmd.FullName -Parent) -Parent) "bin\cache\dart-sdk\bin\dart.exe"
    if (Test-Path $cand) { $dartCmd = Get-Item $cand }
}
if ($dartCmd) {
    $v = (& $dartCmd.FullName --version 2>&1)
    Report-Tool "Dart" $true $v.Trim() $dartCmd.FullName $true
} else {
    Report-Tool "Dart" $false "" "" $true
}

# 4. Visual Studio & MSVC
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsFound = $false
$msvcFound = $false
$msvcVersion = ""
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vsPath -and (Test-Path $vsPath)) {
        $vsFound = $true
        $msvcDir = Get-ChildItem "$vsPath\VC\Tools\MSVC" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($msvcDir) {
            $msvcFound = $true
            $msvcVersion = $msvcDir.Name
        }
    }
}
Report-Tool "Visual Studio C++" $vsFound "VS 2022" $vsPath $true
Report-Tool "MSVC Toolset" $msvcFound $msvcVersion "$vsPath\VC\Tools\MSVC\$msvcVersion" $true

# 5. CMake
$cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmakeCmd -and $vsPath) {
    $cand = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (Test-Path $cand) { $cmakeCmd = Get-Item $cand }
}
if ($cmakeCmd) {
    $v = (& $cmakeCmd.FullName --version 2>&1 | Select-Object -First 1) -replace 'cmake version ',' '
    Report-Tool "CMake" $true $v.Trim() $cmakeCmd.FullName $true
} else {
    Report-Tool "CMake" $false "" "" $true
}

# 6. Ninja
$ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
if (-not $ninjaCmd -and $vsPath) {
    $cand = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
    if (Test-Path $cand) { $ninjaCmd = Get-Item $cand }
}
if ($ninjaCmd) {
    $v = (& $ninjaCmd.FullName --version 2>&1)
    Report-Tool "Ninja" $true $v.Trim() $ninjaCmd.FullName $true
} else {
    Report-Tool "Ninja" $false "" "" $true
}

# 7. Python (Optionnel)
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if ($pythonCmd) {
    $v = (& python --version 2>&1)
    Report-Tool "Python" $true $v.Trim() $pythonCmd.Source $false
} else {
    Report-Tool "Python" $false "" "" $false
}

Write-Host ""
if ($allOk) {
    Write-Host "==> Tous les outils requis pour compiler Jarvisol sont présents !" -ForegroundColor Green
    exit 0
} else {
    Write-Host "==> Certains composants requis sont manquants. Consultez docs/PREREQUISITES_WINDOWS.md." -ForegroundColor Red
    exit 1
}
