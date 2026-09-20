#Requires -Version 5.1
<#
.SYNOPSIS
    Bundle le runtime Python + les packages litert-lm dans un dossier auto-contenu.

.DESCRIPTION
    Ce script :
    1. Auto-detecte le venv source (Hermes, pipx, ou litert-lm global)
    2. Lit pyvenv.cfg pour localiser le runtime Python
    3. Verifie l'idempotence via manifest.json
    4. Copie le runtime Python (hors include\ et tcl\)
    5. Copie les packages litert-lm requis depuis site-packages
    6. Ecrit manifest.json avec versions, date, host

.PARAMETER TargetDir
    Dossier cible du bundle (sera cree si inexistant).

.PARAMETER SourceVenv
    (Optionnel) Chemin du venv source. Auto-detecte si absent.

.EXAMPLE
    .\bundle_litert_runtime.ps1 -TargetDir 'D:\...\Release\runtime\litert_lm'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetDir,

    [Parameter(Mandatory = $false)]
    [string]$SourceVenv = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Step  { param($msg) Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-OK    { param($msg) Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "  WARN  $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "`nERREUR : $msg" -ForegroundColor Red; exit 1 }

function Get-DirSizeMB {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $bytes = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    [math]::Round($bytes / 1MB, 1)
}

# ─────────────────────────────────────────────────────────────────────────────
# ETAPE 1 — Auto-detection du venv source
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Detection du venv source"

if ($SourceVenv -ne '' -and (Test-Path $SourceVenv)) {
    Write-OK "Venv fourni explicitement : $SourceVenv"
} else {
    # Candidats dans l'ordre de priorite
    $candidates = @(
        "$env:LOCALAPPDATA\hermes\hermes-agent\venv",
        "$env:LOCALAPPDATA\pipx\venvs\litert-lm"
    )

    # Ajout du venv de litert-lm detecte via Get-Command
    $litert_cmd = Get-Command 'litert-lm' -ErrorAction SilentlyContinue
    if ($litert_cmd) {
        $inferred = Split-Path (Split-Path $litert_cmd.Source -Parent) -Parent
        $candidates += $inferred
    }

    $SourceVenv = ''
    foreach ($c in $candidates) {
        if (Test-Path "$c\Lib\site-packages") {
            $SourceVenv = $c
            break
        }
    }

    if ($SourceVenv -eq '') {
        Write-Fail "Impossible de trouver un venv contenant litert-lm. Specifiez -SourceVenv."
    }
    Write-OK "Venv auto-detecte : $SourceVenv"
}

# ─────────────────────────────────────────────────────────────────────────────
# ETAPE 2 — Lecture de pyvenv.cfg pour localiser le runtime Python
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Lecture de pyvenv.cfg"

$pyvenvCfg = "$SourceVenv\pyvenv.cfg"
if (-not (Test-Path $pyvenvCfg)) {
    Write-Fail "pyvenv.cfg introuvable dans $SourceVenv"
}

$pythonHomeBase = $null
foreach ($line in Get-Content $pyvenvCfg) {
    if ($line -match '^\s*home\s*=\s*(.+)$') {
        $pythonHomeBase = $Matches[1].Trim()
        break
    }
}
if (-not $pythonHomeBase -or -not (Test-Path $pythonHomeBase)) {
    Write-Fail "Repertoire 'home' introuvable ou invalide dans pyvenv.cfg : '$pythonHomeBase'"
}

# Le 'home' pointe vers le dossier qui contient python.exe
# Pour uv, 'home' = C:\...\cpython-3.11-windows-x86_64-none (contient python.exe)
$pythonExeInHome = Join-Path $pythonHomeBase 'python.exe'
if (-not (Test-Path $pythonExeInHome)) {
    # Peut-etre un sous-dossier bin/
    $pythonExeInHome = Join-Path $pythonHomeBase 'bin\python.exe'
    if (-not (Test-Path $pythonExeInHome)) {
        Write-Fail "python.exe introuvable dans '$pythonHomeBase' ni dans son sous-dossier bin\"
    }
}

# Source runtime = le dossier qui contient python.exe
$sourceRuntimeDir = Split-Path $pythonExeInHome -Parent
if ((Split-Path $sourceRuntimeDir -Leaf) -eq 'bin') {
    $sourceRuntimeDir = Split-Path $sourceRuntimeDir -Parent
}

Write-OK "Runtime Python source : $sourceRuntimeDir"
Write-OK "python.exe : $pythonExeInHome"

# Determination version Python
try {
    $pythonVersion = (& $pythonExeInHome --version 2>&1) -replace 'Python ',''
    $pythonVersion = $pythonVersion.Trim()
} catch {
    $pythonVersion = 'unknown'
    foreach ($line in Get-Content $pyvenvCfg) {
        if ($line -match '^\s*version\s*=\s*(.+)$') {
            $pythonVersion = $Matches[1].Trim()
            break
        }
    }
}
Write-OK "Python version : $pythonVersion"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPE 3 — Determination version litert_lm
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Determination version litert_lm"

$sitePackages = "$SourceVenv\Lib\site-packages"
if (-not (Test-Path $sitePackages)) {
    Write-Fail "site-packages introuvable : $sitePackages"
}

# Chercher litert_lm-*.dist-info/METADATA (pas litert_lm_api, cli ou builder)
$litert_distinfo = Get-ChildItem $sitePackages -Directory -Filter 'litert_lm-*.dist-info' |
                   Where-Object { $_.Name -notmatch 'api|cli|builder' } |
                   Select-Object -First 1

$litert_lm_version = 'unknown'
if ($litert_distinfo) {
    $metadataFile = Join-Path $litert_distinfo.FullName 'METADATA'
    if (Test-Path $metadataFile) {
        foreach ($line in Get-Content $metadataFile) {
            if ($line -match '^Version:\s*(.+)$') {
                $litert_lm_version = $Matches[1].Trim()
                break
            }
        }
    }
}
Write-OK "litert_lm version : $litert_lm_version"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPE 4 — Verification idempotence
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Verification idempotence"

$manifestPath = "$TargetDir\manifest.json"
if (Test-Path $manifestPath) {
    try {
        $existing = Get-Content $manifestPath -Raw | ConvertFrom-Json
        if ($existing.python_version -eq $pythonVersion -and
            $existing.litert_lm_version -eq $litert_lm_version) {
            Write-Host "`nRuntime deja bundle — skip" -ForegroundColor Green
            Write-Host "  python_version   : $($existing.python_version)"
            Write-Host "  litert_lm_version: $($existing.litert_lm_version)"
            exit 0
        } else {
            Write-Warn "Versions differentes — re-bundling"
            Write-Warn "  Existant : python=$($existing.python_version) litert_lm=$($existing.litert_lm_version)"
            Write-Warn "  Nouveau  : python=$pythonVersion litert_lm=$litert_lm_version"
        }
    } catch {
        Write-Warn "manifest.json illisible, on re-bundle"
    }
} else {
    Write-OK "Pas de manifest existant, bundling initial"
}

# ─────────────────────────────────────────────────────────────────────────────
# ETAPE 5 — Copie du runtime Python
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Copie du runtime Python vers $TargetDir\python\"

$pythonDest = "$TargetDir\python"
$null = New-Item -ItemType Directory -Force -Path $pythonDest

# Dossiers a exclure (headers C et Tcl/Tk)
$excludeItems = @('include', 'tcl', 'tcl8', 'tk', 'tcl8.6', 'tk8.6')

$items = Get-ChildItem -Path $sourceRuntimeDir -ErrorAction SilentlyContinue
$copiedPython = 0
foreach ($item in $items) {
    if ($excludeItems -contains $item.Name.ToLower()) {
        Write-Warn "  Skip (exclu) : $($item.Name)"
        continue
    }
    Write-Host "  Copie : $($item.Name)" -ForegroundColor Gray
    $dst = Join-Path $pythonDest $item.Name
    Copy-Item -Path $item.FullName -Destination $dst -Recurse -Force -ErrorAction Stop
    $copiedPython++
}

# Verification que python.exe est bien la
$destPythonExe = "$pythonDest\python.exe"
if (-not (Test-Path $destPythonExe)) {
    Write-Fail "python.exe absent de $pythonDest apres la copie"
}
Write-OK "python.exe present dans $pythonDest"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPE 6 — Copie des packages litert-lm depuis site-packages
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Copie des packages litert-lm vers $TargetDir\site-packages\"

$sitePackagesDest = "$TargetDir\site-packages"
$null = New-Item -ItemType Directory -Force -Path $sitePackagesDest

# Liste des patterns de dossiers/fichiers a copier
$packagePatterns = @(
    # litert_lm core et ses dist-info
    'litert_lm',
    'litert_lm_api-*.dist-info',
    'litert_lm-*.dist-info',
    # litert_lm_cli
    'litert_lm_cli',
    'litert_lm_cli-*.dist-info',
    # litert_lm_builder
    'litert_lm_builder',
    'litert_lm_builder-*.dist-info',
    # uvicorn (serveur ASGI)
    'uvicorn',
    'uvicorn-*.dist-info',
    # fastapi
    'fastapi',
    'fastapi-*.dist-info',
    # pydantic
    'pydantic',
    'pydantic-*.dist-info',
    'pydantic_core',
    'pydantic_core-*.dist-info',
    'pydantic_settings',
    'pydantic_settings-*.dist-info',
    # starlette
    'starlette',
    'starlette-*.dist-info',
    # click (CLI)
    'click',
    'click-*.dist-info',
    # anyio
    'anyio',
    'anyio-*.dist-info',
    # h11
    'h11',
    'h11-*.dist-info',
    # httptools
    'httptools',
    'httptools-*.dist-info',
    # httpx
    'httpx',
    'httpx-*.dist-info',
    'httpx_sse',
    'httpx_sse-*.dist-info',
    # sniffio
    'sniffio',
    'sniffio-*.dist-info',
    # sse_starlette
    'sse_starlette',
    'sse_starlette-*.dist-info',
    # certifi
    'certifi',
    'certifi-*.dist-info',
    # charset_normalizer
    'charset_normalizer',
    'charset_normalizer-*.dist-info',
    # idna
    'idna',
    'idna-*.dist-info',
    # annotated_types
    'annotated_types',
    'annotated_types-*.dist-info',
    # annotated_doc
    'annotated_doc',
    'annotated_doc-*.dist-info',
    # typing_extensions (dist-info + module .py ou dossier)
    'typing_extensions-*.dist-info',
    'typing_extensions.py',
    'typing_extensions',
    # exceptiongroup
    'exceptiongroup',
    # exceptiongroup
    'exceptiongroup',
    'exceptiongroup-*.dist-info',
    # ── Dépendances litert_lm_cli.main serve (requis au démarrage du serveur) ──
    # flatbuffers: litert_lm_builder -> litertlm_builder -> flatbuffers
    'flatbuffers',
    'flatbuffers-*.dist-info',
    # prompt_toolkit: benchmark -> cli_helpers -> prompt_toolkit.keys
    'prompt_toolkit',
    'prompt_toolkit-*.dist-info',
    # wcwidth: dépendance de prompt_toolkit
    'wcwidth',
    'wcwidth-*.dist-info',
    # questionary: interactions litert_lm_cli
    'questionary',
    'questionary-*.dist-info',
    # rich: formatage output CLI
    'rich',
    'rich-*.dist-info',
    # colorama: support couleurs Windows pour prompt_toolkit
    'colorama',
    'colorama-*.dist-info',
    # pygments: syntax highlighting pour rich/prompt_toolkit
    'pygments',
    'pygments-*.dist-info',
    # packaging: utilitaires version
    'packaging',
    'packaging-*.dist-info',
    # markdown_it (markdown_it_py): rendu markdown CLI
    'markdown_it',
    'markdown_it_py-*.dist-info',
    # mdurl: dépendance de markdown_it
    'mdurl',
    'mdurl-*.dist-info',
    # distro: détection plateforme OS
    'distro',
    'distro-*.dist-info',
    # google (protobuf): litert_lm_builder -> litertlm_builder -> google.protobuf
    'google',
    'protobuf-*.dist-info',
    # absl-py: litert_lm_builder -> absl
    'absl',
    'absl_py-*.dist-info',
    # tomli: litert_lm_builder -> tomli (parser TOML)
    'tomli',
    'tomli-*.dist-info',
    # mypyc compiled extension pour tomli (performance, architecture-spécifique)
    '3c22db458360489351e4__mypyc.cp311-win_amd64.pyd'
)

$packagesCopied = 0
$packagesMissing = @()
$essentialPackages = @('litert_lm', 'uvicorn', 'fastapi', 'pydantic')

foreach ($pattern in $packagePatterns) {
    if ($pattern.Contains('*')) {
        # Pattern avec wildcard — @() ensures array even for single result (required by Set-StrictMode)
        $found = @(Get-ChildItem -Path $sitePackages -Filter $pattern -ErrorAction SilentlyContinue)
        foreach ($m in $found) {
            $dst = Join-Path $sitePackagesDest $m.Name
            Write-Host "  Copie : $($m.Name)" -ForegroundColor Gray
            Copy-Item -Path $m.FullName -Destination $dst -Recurse -Force -ErrorAction Stop
            $packagesCopied++
        }
        if ($found.Count -eq 0) {
            Write-Warn "  Non trouve (optionnel) : $pattern"
        }
    } else {
        # Pattern exact
        $exactPath = Join-Path $sitePackages $pattern
        if (Test-Path $exactPath) {
            $dst = Join-Path $sitePackagesDest $pattern
            Write-Host "  Copie : $pattern" -ForegroundColor Gray
            Copy-Item -Path $exactPath -Destination $dst -Recurse -Force -ErrorAction Stop
            $packagesCopied++
        } else {
            $basePattern = $pattern -replace '\.py$',''
            if ($essentialPackages -contains $basePattern) {
                $packagesMissing += $pattern
                Write-Warn "  MANQUANT (essentiel) : $pattern"
            } else {
                Write-Warn "  Non trouve (optionnel) : $pattern"
            }
        }
    }
}

# Verification des packages essentiels
if ($packagesMissing.Count -gt 0) {
    Write-Fail "Packages essentiels manquants : $($packagesMissing -join ', ')"
}

# Verification litert_lm present dans destination
if (-not (Test-Path "$sitePackagesDest\litert_lm")) {
    Write-Fail "litert_lm absent de $sitePackagesDest apres la copie"
}
Write-OK "$packagesCopied elements copies vers site-packages"

# ─────────────────────────────────────────────────────────────────────────────
$architecture = 'windows-x86_64'

$pythonMB       = Get-DirSizeMB "$TargetDir\python"
$sitePackagesMB = Get-DirSizeMB "$TargetDir\site-packages"
$totalMB        = [math]::Round($pythonMB + $sitePackagesMB, 1)

# Valide les composants critiques (absence = erreur fatale)
$criticalList = @('litert_lm','litert_lm_cli','litert_lm_builder','uvicorn','fastapi',
                   'pydantic','pydantic_core','starlette','click','anyio','h11')
$criticalComponents = [ordered]@{}
foreach ($pkg in $criticalList) {
    $pkgPath = Join-Path $sitePackagesDest $pkg
    $criticalComponents[$pkg] = if (Test-Path $pkgPath) { 'ok' } else { 'MISSING' }
}

$manifest = [ordered]@{
    litert_lm_version   = $litert_lm_version
    python_version      = $pythonVersion
    architecture        = $architecture
    bundle_date         = [System.DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
    bundle_host         = $env:COMPUTERNAME
    source_venv         = (Resolve-Path $SourceVenv).Path
    source_python       = (Resolve-Path $sourceRuntimeDir).Path
    bundle_size_mb      = [ordered]@{
        python_runtime  = $pythonMB
        site_packages   = $sitePackagesMB
        total           = $totalMB
    }
    critical_components = $criticalComponents
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8
Write-OK "manifest.json ecrit dans $TargetDir"

$failedComponents = @($criticalComponents.GetEnumerator() | Where-Object { $_.Value -ne 'ok' })
if ($failedComponents.Count -eq 0) {
    Write-OK "Tous les composants critiques valides : $($criticalList -join ', ')"
} else {
    $failedNames = ($failedComponents | ForEach-Object { $_.Key }) -join ', '
    Write-Fail "Composants critiques MANQUANTS : $failedNames"
}

# ─────────────────────────────────────────────────────────────────────────────
# ETAPE 8 — Rapport final des tailles
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Rapport final"

Write-Host ""
Write-Host "  Python runtime   : ${pythonMB} MB" -ForegroundColor White
Write-Host "  site-packages    : ${sitePackagesMB} MB" -ForegroundColor White
Write-Host "  TOTAL            : ${totalMB} MB" -ForegroundColor White
Write-Host "  litert_lm        : $litert_lm_version" -ForegroundColor Gray
Write-Host "  Python           : $pythonVersion" -ForegroundColor Gray
Write-Host ""
Write-Host "Bundling termine avec succes !" -ForegroundColor Green

exit 0

