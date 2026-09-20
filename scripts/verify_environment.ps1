#Requires -Version 5.1
<#
.SYNOPSIS
    Verifie que la chaine d'outils necessaire pour compiler Jarvisol est installee sur ce PC Windows.
#>
[CmdletBinding()]
param(
    [switch]$FullRelease
)

$ErrorActionPreference = "Continue"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "     Verification de l'Environnement de Developpement Jarvisol   " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Mode : $(if ($FullRelease) { 'Full Release (Helpers Python requis)' } else { 'Standard (C++ & Flutter)' })"
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
            Write-Host " $Name : Non detecte (Optionnel pour build minimal, obligatoire pour Full Release)" -ForegroundColor DarkYellow
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
if (-not $flutterCmd) {
    if ($env:FLUTTER_ROOT -and (Test-Path "$env:FLUTTER_ROOT\bin\flutter.bat")) {
        $env:PATH = "$env:FLUTTER_ROOT\bin;$env:PATH"
        $flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
    } elseif (Test-Path "$PSScriptRoot\..\..\flutter\bin\flutter.bat") {
        $cand = (Resolve-Path "$PSScriptRoot\..\..\flutter\bin").Path
        $env:PATH = "$cand;$env:PATH"
        $flutterCmd = Get-Command flutter.bat -ErrorAction SilentlyContinue
    }
}
if ($flutterCmd) {
    $v = (& flutter.bat --version 2>&1 | Select-Object -First 1)
    Report-Tool "Flutter" $true $v.Trim() $flutterCmd.Source $true
} else {
    Report-Tool "Flutter" $false "" "" $true
}

# 3. Dart
$dartCmd = Get-Command dart -ErrorAction SilentlyContinue
if (-not $dartCmd -and $flutterCmd) {
    $cand = Join-Path (Split-Path (Split-Path $flutterCmd.Source -Parent) -Parent) "bin\cache\dart-sdk\bin"
    if (Test-Path "$cand\dart.exe") {
        $env:PATH = "$cand;$env:PATH"
        $dartCmd = Get-Command dart -ErrorAction SilentlyContinue
    }
}
if ($dartCmd) {
    $v = (& dart --version 2>&1)
    Report-Tool "Dart" $true $v.Trim() $dartCmd.Source $true
} else {
    Report-Tool "Dart" $false "" "" $true
}

# 4. Visual Studio & MSVC
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsFound = $false
$msvcFound = $false
$msvcVersion = ""
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vsPath -and (Test-Path $vsPath)) {
        $vsFound = $true
        $msvcDir = Get-ChildItem "$vsPath\VC\Tools\MSVC" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($msvcDir) {
            $msvcFound = $true
            $msvcVersion = $msvcDir.Name
        }
        # Injecter CMake et Ninja de VS dans PATH si non presents
        $vsCMake = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
        $vsNinja = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
        if (Test-Path $vsCMake) { $env:PATH = "$vsCMake;$env:PATH" }
        if (Test-Path $vsNinja) { $env:PATH = "$vsNinja;$env:PATH" }
    }
}
Report-Tool "Visual Studio C++" $vsFound "VS 2022" $vsPath $true
Report-Tool "MSVC Toolset" $msvcFound $msvcVersion "$vsPath\VC\Tools\MSVC\$msvcVersion" $true

# 5. CMake
$cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCmd) {
    $v = (& cmake --version 2>&1 | Select-Object -First 1) -replace 'cmake version ',' '
    Report-Tool "CMake" $true $v.Trim() $cmakeCmd.Source $true
} else {
    Report-Tool "CMake" $false "" "" $true
}

# 6. Ninja
$ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
if ($ninjaCmd) {
    $v = (& ninja --version 2>&1)
    Report-Tool "Ninja" $true $v.Trim() $ninjaCmd.Source $true
} else {
    Report-Tool "Ninja" $false "" "" $true
}

# 7. Python
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if ($pythonCmd) {
    $v = (& python --version 2>&1)
    Report-Tool "Python" $true $v.Trim() $pythonCmd.Source $FullRelease
} else {
    Report-Tool "Python" $false "" "" $FullRelease
}

# 8. PyInstaller
$pyinstallerCmd = Get-Command pyinstaller -ErrorAction SilentlyContinue
if ($pyinstallerCmd) {
    $v = (& pyinstaller --version 2>&1)
    Report-Tool "PyInstaller" $true $v.Trim() $pyinstallerCmd.Source $FullRelease
} else {
    Report-Tool "PyInstaller" $false "" "" $FullRelease
}

Write-Host ""
if ($allOk) {
    Write-Host "==> Tous les outils requis pour compiler Jarvisol sont presents !" -ForegroundColor Green
    exit 0
} else {
    Write-Host "==> Certains composants requis sont manquants. Consultez docs/PREREQUISITES_WINDOWS.md." -ForegroundColor Red
    exit 1
}
