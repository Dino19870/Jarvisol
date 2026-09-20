#Requires -Version 5.1
<#
.SYNOPSIS
    Reconstruction complete de Jarvisol depuis les sources du monorepo.
    1. Compile la bibliotheque native CrispASR (whisper.dll, crispasr.dll)
    2. Compile la bibliotheque native CrispEmbed (crispembed.dll)
    3. Compile la bibliotheque native glint (glint.dll)
    4. Compile l'application Flutter Windows Release (crisper_weaver.exe / jarvisol.exe)
    5. Copie et groupe les DLLs necessaires dans le dossier d'execution.
    6. (Optionnel / FullRelease) Compile les serveurs auxiliaires Python (memory_server, sd_server, jarvisol_tray)
       et integre le runtime Web Media portable.
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("debug","Debug","release","Release")]
    [string]$Config = "release",
    [switch]$RebuildCmake,
    [switch]$FullRelease
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

# Resolution de CMake et Ninja via Visual Studio si non presents dans PATH
$cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
$ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
if (-not $cmakeCmd -or -not $ninjaCmd) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vsPath) {
            $vsCMake = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
            $vsNinja = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
            if (Test-Path $vsCMake) { $env:PATH = "$vsCMake;$env:PATH" }
            if (Test-Path $vsNinja) { $env:PATH = "$vsNinja;$env:PATH" }
        }
    }
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "            Compilation Windows Jarvisol (Monorepo)             " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Monorepo Root : $repoRoot"
Write-Host "  Configuration : $Config"
Write-Host "  Full Release  : $FullRelease"
Write-Host ""

# ---------------------------------------------------------------------------
# Etape 1 : Compilation CrispASR
# ---------------------------------------------------------------------------
Write-Host "==> 1/5 : Configuration et compilation de CrispASR (whisper.dll)..." -ForegroundColor Cyan
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
    if ($LASTEXITCODE -ne 0) { throw "CMake configure CrispASR a echoue (code $LASTEXITCODE)" }
}

$existingVcxproj = Get-ChildItem -Path $crispasrBuild -Filter "*.vcxproj" -Recurse | Select-Object -ExpandProperty BaseName
$linkTarget = if ($existingVcxproj -contains "crispasr") { "crispasr" } else { "crispasr-lib" }
& cmake --build $crispasrBuild --config $cmakeBuildType --parallel --target $linkTarget
if ($LASTEXITCODE -ne 0) { throw "Build de CrispASR ($linkTarget) a echoue (code $LASTEXITCODE)" }

# ---------------------------------------------------------------------------
# Etape 2 : Compilation CrispEmbed
# ---------------------------------------------------------------------------
Write-Host "`n==> 2/5 : Configuration et compilation de CrispEmbed (crispembed.dll)..." -ForegroundColor Cyan
$crispembedBuild = Join-Path $crispembedDir "build"
if ($RebuildCmake -and (Test-Path $crispembedBuild)) { Remove-Item -Recurse -Force $crispembedBuild }

if (-not (Test-Path (Join-Path $crispembedBuild "CMakeCache.txt"))) {
    & cmake -S $crispembedDir -B $crispembedBuild `
        -DCMAKE_BUILD_TYPE=Release `
        -DCRISPEMBED_BUILD_SHARED=ON `
        -DCRISPEMBED_BUILD_TESTS=OFF `
        -DCRISPEMBED_BUILD_EXAMPLES=OFF
    if ($LASTEXITCODE -ne 0) { throw "CMake configure CrispEmbed a echoue (code $LASTEXITCODE)" }
}
& cmake --build $crispembedBuild --config Release --parallel --target crispembed-shared
if ($LASTEXITCODE -ne 0) { throw "Build de CrispEmbed a echoue (code $LASTEXITCODE)" }

# ---------------------------------------------------------------------------
# Etape 3 : Compilation glint
# ---------------------------------------------------------------------------
Write-Host "`n==> 3/5 : Configuration et compilation de glint (glint.dll)..." -ForegroundColor Cyan
$glintBuild = Join-Path $glintDir "build"
if ($RebuildCmake -and (Test-Path $glintBuild)) { Remove-Item -Recurse -Force $glintBuild }

if (-not (Test-Path (Join-Path $glintBuild "CMakeCache.txt"))) {
    & cmake -S $glintDir -B $glintBuild -DCMAKE_BUILD_TYPE=Release
    if ($LASTEXITCODE -ne 0) { throw "CMake configure glint a echoue (code $LASTEXITCODE)" }
}
& cmake --build $glintBuild --config Release --parallel --target glint_shared
if ($LASTEXITCODE -ne 0) { throw "Build de glint a echoue (code $LASTEXITCODE)" }

# ---------------------------------------------------------------------------
# Etape 4 : Compilation Flutter Windows
# ---------------------------------------------------------------------------
Write-Host "`n==> 4/5 : Compilation Flutter Windows ($flutterFlag)..." -ForegroundColor Cyan
Push-Location $weaverDir
try {
    & flutter.bat pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get a echoue (code $LASTEXITCODE)" }

    & flutter.bat build windows $flutterFlag
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows a echoue (code $LASTEXITCODE)" }

    $runnerDir = Join-Path $weaverDir "build\windows\x64\runner\$runnerCfg"
    if (-not (Test-Path $runnerDir)) {
        throw "Dossier Runner introuvable a : $runnerDir"
    }

    # Bundling des DLLs natives
    Write-Host "`n==> 5/5 : Bundling des DLLs dans : $runnerDir" -ForegroundColor Cyan
    $env:CRISPASR_DIR          = $crispasrDir
    $env:CRISPASR_BUILD_SUBDIR = "build-flutter-bundle"
    $env:RUNNER_DIR            = $runnerDir
    $env:GLINT_DIR             = $glintDir

    & "$weaverDir\scripts\bundle_windows_dlls.ps1"
    if ($LASTEXITCODE -ne 0) { throw "Echec du bundling des DLLs CrispASR/glint" }

    # Copie de crispembed.dll
    $candEmbed = Join-Path $crispembedBuild "Release\crispembed.dll"
    if (Test-Path $candEmbed) {
        Copy-Item $candEmbed "$runnerDir\crispembed.dll" -Force
        Write-Host "  bundled crispembed.dll ($candEmbed)" -ForegroundColor Green
    }

    $exePath = Join-Path $runnerDir "jarvisol.exe"
    if (-not (Test-Path $exePath)) {
        $exePath = Join-Path $runnerDir "crisper_weaver.exe"
    }
    $jarvisolExe = Join-Path $runnerDir "jarvisol.exe"
    $cwExe       = Join-Path $runnerDir "crisper_weaver.exe"
    if ((Test-Path $cwExe) -and (-not (Test-Path $jarvisolExe))) {
        Copy-Item $cwExe $jarvisolExe -Force
    }
    if ((Test-Path $jarvisolExe) -and (-not (Test-Path $cwExe))) {
        Copy-Item $jarvisolExe $cwExe -Force
    }

    # ---------------------------------------------------------------------------
    # Etape 6 : Helpers Python & Runtimes Tiers (Full Release)
    # ---------------------------------------------------------------------------
    if ($FullRelease) {
        Write-Host "`n==> Compilation et bundling des helpers Python (Full Release)..." -ForegroundColor Cyan
        
        $pyCmd = Get-Command python -ErrorAction SilentlyContinue
        $pyinstallerCmd = Get-Command pyinstaller -ErrorAction SilentlyContinue
        if (-not $pyCmd -or -not $pyinstallerCmd) {
            throw "Python ou PyInstaller introuvable pour la compilation des helpers (--FullRelease requis)."
        }

        # 1. memory_server.exe
        Write-Host "  -> Compilation de memory_server.exe via PyInstaller..." -ForegroundColor Yellow
        Push-Location $weaverDir
        try {
            & pyinstaller memory_server.spec
            if ($LASTEXITCODE -ne 0) { throw "Echec du build de memory_server.exe" }
            $memDist = Join-Path $weaverDir "dist\memory_server.exe"
            if (Test-Path $memDist) {
                Copy-Item $memDist "$runnerDir\memory_server.exe" -Force
                Write-Host "  bundled memory_server.exe" -ForegroundColor Green
            }
        } finally {
            Pop-Location
        }

        # 2. sd_server.exe
        Write-Host "  -> Compilation de sd_server.exe via PyInstaller..." -ForegroundColor Yellow
        Push-Location $weaverDir
        try {
            & pyinstaller sd_server.spec
            if ($LASTEXITCODE -ne 0) { throw "Echec du build de sd_server.exe" }
            $sdDist = Join-Path $weaverDir "dist\sd_server.exe"
            if (Test-Path $sdDist) {
                Copy-Item $sdDist "$runnerDir\sd_server.exe" -Force
                Write-Host "  bundled sd_server.exe" -ForegroundColor Green
            }
        } finally {
            Pop-Location
        }

        # 3. jarvisol_tray.exe
        Write-Host "  -> Compilation de jarvisol_tray.exe via PyInstaller..." -ForegroundColor Yellow
        Push-Location $repoRoot
        try {
            & pyinstaller --noconfirm --onefile --noconsole --name jarvisol_tray "scripts\jarvisol_tray.py"
            if ($LASTEXITCODE -ne 0) { throw "Echec du build de jarvisol_tray.exe" }
            $trayDist = Join-Path $repoRoot "dist\jarvisol_tray.exe"
            if (Test-Path $trayDist) {
                Copy-Item $trayDist "$runnerDir\jarvisol_tray.exe" -Force
                Write-Host "  bundled jarvisol_tray.exe" -ForegroundColor Green
            }
        } finally {
            Pop-Location
        }

        # 4. launch_servers.vbs
        $vbsSrc = Join-Path $repoRoot "scripts\launch_servers.vbs"
        if (Test-Path $vbsSrc) {
            Copy-Item $vbsSrc "$runnerDir\launch_servers.vbs" -Force
            Write-Host "  bundled launch_servers.vbs" -ForegroundColor Green
        }

        # 5. Runtime Web Media
        $webMediaSrc = Join-Path $weaverDir "runtime\web_media"
        if (Test-Path $webMediaSrc) {
            $webMediaDest = Join-Path $runnerDir "runtime\web_media"
            $null = New-Item -ItemType Directory -Path $webMediaDest -Force
            Copy-Item "$webMediaSrc\*" $webMediaDest -Recurse -Force
            Write-Host "  bundled runtime\web_media (yt-dlp, deno, ffmpeg, ffprobe)" -ForegroundColor Green
        }

        # 6. Repertoires requis
        foreach ($d in @("memory", "models", "prompts_library", "mcp_servers")) {
            $destD = Join-Path $runnerDir $d
            $null = New-Item -ItemType Directory -Path $destD -Force
            $srcD = Join-Path $weaverDir $d
            if (Test-Path $srcD) {
                Copy-Item "$srcD\*" $destD -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host "`n================================================================" -ForegroundColor Green
    Write-Host "      COMPILATION ET BUNDLING REUSSIS AVEC SUCCES !            " -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  Dossier Release      : $runnerDir"
    Write-Host "  Executable principal : $exePath"
    if (Test-Path $jarvisolExe) {
        Write-Host "  Alias Jarvisol       : $jarvisolExe"
    }
} finally {
    Pop-Location
}
