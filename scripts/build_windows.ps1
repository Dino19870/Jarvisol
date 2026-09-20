#Requires -Version 5.1
<#
.SYNOPSIS
    Reconstruction complète de Jarvisol depuis les sources du monorepo.
    1. Compile la bibliothèque native CrispASR (whisper.dll, crispasr.dll)
    2. Compile la bibliothèque native CrispEmbed (crispembed.dll)
    3. Compile la bibliothèque native glint (glint.dll)
    4. Compile l'application Flutter Windows Release (crisper_weaver.exe / jarvisol.exe)
    5. Copie et groupe les DLLs nécessaires dans le dossier d'exécution.
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("debug","Debug","release","Release")]
    [string]$Config = "release",
    [switch]$RebuildCmake
)

$ErrorActionPreference = "Stop"

$flutterFlag    = if ($Config -ieq "debug") { "--debug" } else { "--release" }
$cmakeBuildType = "Release"
$runnerCfg      = if ($Config -ieq "debug") { "Debug" } else { "Release" }

$repoRoot      = (Resolve-Path "$PSScriptRoot\..").Path
$crispasrDir   = Join-Path $repoRoot "CrispASR"
$crispembedDir = Join-Path $repoRoot "CrispEmbed"
$glintDir      = Join-Path $repoRoot "glint"
$weaverDir     = Join-Path $repoRoot "CrisperWeaver"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "            Compilation Windows Jarvisol (Monorepo)             " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Monorepo Root : $repoRoot"
Write-Host "  Configuration : $Config"
Write-Host ""

# ---------------------------------------------------------------------------
# Étape 1 : Compilation CrispASR
# ---------------------------------------------------------------------------
Write-Host "==> 1/4 : Configuration et compilation de CrispASR (whisper.dll)..." -ForegroundColor Cyan
$crispasrBuild = Join-Path $crispasrDir "build-flutter-bundle"
if ($RebuildCmake -and (Test-Path $crispasrBuild)) { Remove-Item -Recurse -Force $crispasrBuild }

if (-not (Test-Path (Join-Path $crispasrBuild "CMakeCache.txt"))) {
    & cmake -S $crispasrDir -B $crispasrBuild `
        -DCMAKE_BUILD_TYPE=$cmakeBuildType `
        -DBUILD_SHARED_LIBS=ON `
        -DCRISPASR_BUILD_TESTS=OFF `
        -DCRISPASR_BUILD_EXAMPLES=OFF `
        -DCRISPASR_BUILD_SERVER=OFF `
        -DCRISPASR_OPUS_FETCH=ON `
        -DGGML_NATIVE=OFF `
        -DGGML_AVX512=OFF `
        -DGGML_AVX512_VBMI=OFF `
        -DGGML_AVX512_VNNI=OFF `
        -DGGML_AVX512_BF16=OFF `
        -DGGML_AVX2=ON `
        -DGGML_AVX=ON `
        -DGGML_FMA=ON `
        -DGGML_F16C=ON
    if ($LASTEXITCODE -ne 0) { throw "CMake configure CrispASR a échoué (code $LASTEXITCODE)" }
}

$existingVcxproj = Get-ChildItem -Path $crispasrBuild -Filter "*.vcxproj" -Recurse | Select-Object -ExpandProperty BaseName
$linkTarget = if ($existingVcxproj -contains "crispasr") { "crispasr" } else { "crispasr-lib" }
& cmake --build $crispasrBuild --config $cmakeBuildType --parallel --target $linkTarget
if ($LASTEXITCODE -ne 0) { throw "Build de CrispASR ($linkTarget) a échoué (code $LASTEXITCODE)" }

# ---------------------------------------------------------------------------
# Étape 2 : Compilation CrispEmbed
# ---------------------------------------------------------------------------
Write-Host "`n==> 2/4 : Configuration et compilation de CrispEmbed (crispembed.dll)..." -ForegroundColor Cyan
$crispembedBuild = Join-Path $crispembedDir "build"
if ($RebuildCmake -and (Test-Path $crispembedBuild)) { Remove-Item -Recurse -Force $crispembedBuild }

if (-not (Test-Path (Join-Path $crispembedBuild "CMakeCache.txt"))) {
    & cmake -S $crispembedDir -B $crispembedBuild `
        -DCMAKE_BUILD_TYPE=Release `
        -DCRISPEMBED_BUILD_SHARED=ON `
        -DCRISPEMBED_BUILD_TESTS=OFF `
        -DCRISPEMBED_BUILD_EXAMPLES=OFF
    if ($LASTEXITCODE -ne 0) { throw "CMake configure CrispEmbed a échoué (code $LASTEXITCODE)" }
}
& cmake --build $crispembedBuild --config Release --parallel --target crispembed
if ($LASTEXITCODE -ne 0) { throw "Build de CrispEmbed a échoué (code $LASTEXITCODE)" }

# ---------------------------------------------------------------------------
# Étape 3 : Compilation glint
# ---------------------------------------------------------------------------
Write-Host "`n==> 3/4 : Configuration et compilation de glint (glint.dll)..." -ForegroundColor Cyan
$glintBuild = Join-Path $glintDir "build"
if ($RebuildCmake -and (Test-Path $glintBuild)) { Remove-Item -Recurse -Force $glintBuild }

if (-not (Test-Path (Join-Path $glintBuild "CMakeCache.txt"))) {
    & cmake -S $glintDir -B $glintBuild -DCMAKE_BUILD_TYPE=Release
    if ($LASTEXITCODE -ne 0) { throw "CMake configure glint a échoué (code $LASTEXITCODE)" }
}
& cmake --build $glintBuild --config Release --parallel --target glint_shared
if ($LASTEXITCODE -ne 0) { throw "Build de glint a échoué (code $LASTEXITCODE)" }

# ---------------------------------------------------------------------------
# Étape 4 : Compilation Flutter Windows
# ---------------------------------------------------------------------------
Write-Host "`n==> 4/4 : Compilation Flutter Windows ($flutterFlag)..." -ForegroundColor Cyan
Push-Location $weaverDir
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get a échoué (code $LASTEXITCODE)" }

    & flutter build windows $flutterFlag
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows a échoué (code $LASTEXITCODE)" }

    $runnerDir = Join-Path $weaverDir "build\windows\x64\runner\$runnerCfg"
    if (-not (Test-Path $runnerDir)) {
        throw "Dossier Runner introuvable à : $runnerDir"
    }

    # Bundling des DLLs
    Write-Host "`n==> Bundling des DLLs dans : $runnerDir" -ForegroundColor Cyan
    $env:CRISPASR_DIR          = $crispasrDir
    $env:CRISPASR_BUILD_SUBDIR = "build-flutter-bundle"
    $env:RUNNER_DIR            = $runnerDir
    $env:GLINT_DIR             = $glintDir

    & "$weaverDir\scripts\bundle_windows_dlls.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Échec du bundling des DLLs CrispASR/glint" }

    # Copie de crispembed.dll
    $candEmbed = Join-Path $crispembedBuild "Release\crispembed.dll"
    if (Test-Path $candEmbed) {
        Copy-Item $candEmbed "$runnerDir\crispembed.dll" -Force
        Write-Host "  bundled crispembed.dll ($candEmbed)" -ForegroundColor Green
    }

    $exePath = Join-Path $runnerDir "crisper_weaver.exe"
    $jarvisolExe = Join-Path $runnerDir "jarvisol.exe"
    if (Test-Path $exePath -and -not (Test-Path $jarvisolExe)) {
        Copy-Item $exePath $jarvisolExe -Force
    }

    Write-Host "`n================================================================" -ForegroundColor Green
    Write-Host "      COMPILATION ET BUNDLING RÉUSSIS AVEC SUCCÈS !            " -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  Exécutable principal : $exePath"
    if (Test-Path $jarvisolExe) {
        Write-Host "  Alias Jarvisol       : $jarvisolExe"
    }
} finally {
    Pop-Location
}
