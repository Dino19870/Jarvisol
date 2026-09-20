<#
.SYNOPSIS
    Bundle le runtime Python Voice Bake + poids Chatterbox dans le Release.

.DESCRIPTION
    Modèle : bundle_litert_runtime.ps1 (même pattern : FATAL si incomplet,
    manifest.json avec versions exactes, smoke test offline).

    Structure produite dans -TargetDir (= Release\) :
        python_bake\
            python.exe
            python311.dll, python311.zip, python3.dll (runtime minimal)
            python311._pth              ← confine sys.path à python_bake\
            Lib\                        ← stdlib (sous-ensemble)
            site-packages\
                numpy\  torch\  torchaudio\  librosa\  gguf\  chatterbox\
                (dépendances transitives)
            hf_cache\                   ← redirect HF_HOME offline (vide)
            voice_bake_manifest.json    ← sentinel d'intégrité

        tools\voice_bake\
            bake-chatterbox-voice-from-wav.py
            chatterbox_paths.py
            chatterbox_weights\         ← snapshot PyTorch offline
                t3_mtl23ls_v3.safetensors
                s3gen.safetensors
                ve.safetensors / ve.pt
                grapheme_mtl_merged_expanded_v1.json / mtl_tokenizer.json
                conds.pt
                config.json  (si présent)

.PARAMETER TargetDir
    Racine du Release (CMAKE_INSTALL_PREFIX). Chemin absolu.

.PARAMETER SourceVenv
    Venv Python source contenant torch, chatterbox, gguf, librosa, numpy.
    Par défaut : <script>\..\voice_bake_bundle\venv_bake

.PARAMETER ChatterboxWeights
    Dossier contenant le snapshot PyTorch résemble-ai/chatterbox pinnée.
    Par défaut : <script>\..\voice_bake_bundle\chatterbox_weights

.PARAMETER ChatterboxSha
    SHA git du dépôt resemble-ai/chatterbox utilisé (documentation seulement).
    Par défaut : 5de7a54aa4e5e2baadb0182dde554908b48b85c2

.PARAMETER ModelRevision
    Révision HF ResembleAI/chatterbox (documentation seulement).
    Par défaut : 5bb1f6ee58e50c3b8d408bc82a6d3740c2db6e18
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TargetDir,

    [string]$SourceVenv        = '',
    [string]$ChatterboxWeights = '',
    [string]$BakeScript        = '',
    [string]$ChatterboxSha     = '5de7a54aa4e5e2baadb0182dde554908b48b85c2',
    [string]$ModelRevision     = '5bb1f6ee58e50c3b8d408bc82a6d3740c2db6e18'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Helpers ────────────────────────────────────────────────────────────────
function Write-Step  ([string]$m) { Write-Host "`n[VoiceBake] === $m ===" -ForegroundColor Cyan }
function Write-OK    ([string]$m) { Write-Host "[VoiceBake] OK  $m"  -ForegroundColor Green }
function Write-Warn  ([string]$m) { Write-Host "[VoiceBake] WARN $m" -ForegroundColor Yellow }
function Write-Fail  ([string]$m) { Write-Host "[VoiceBake] FAIL $m" -ForegroundColor Red; exit 1 }

function Get-DirSizeMB([string]$Path) {
    if (-not (Test-Path $Path)) { return 0.0 }
    $total = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    return [math]::Round($total / 1MB, 1)
}

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path $Path)) { return 'MISSING' }
    $hash = Get-FileHash -Path $Path -Algorithm SHA256
    return $hash.Hash.ToLower()
}

# ─── Résolution des chemins par défaut ──────────────────────────────────────
$scriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundleBaseDir = Join-Path $scriptDir '..\voice_bake_bundle'
$bundleBaseDir = (Resolve-Path $bundleBaseDir -ErrorAction SilentlyContinue)?.Path ?? $bundleBaseDir

if (-not $SourceVenv)        { $SourceVenv        = Join-Path $bundleBaseDir 'venv_bake' }
if (-not $ChatterboxWeights) { $ChatterboxWeights = Join-Path $bundleBaseDir 'chatterbox_weights' }
if (-not $BakeScript)        {
    # Chemin canonique dans CrispASR
    $BakeScript = Join-Path $bundleBaseDir '..\..\..\models\bake-chatterbox-voice-from-wav.py'
    $BakeScript = (Resolve-Path $BakeScript -ErrorAction SilentlyContinue)?.Path ?? $BakeScript
}

$TargetDir = $TargetDir.TrimEnd('\', '/')

# ─── Destinations ───────────────────────────────────────────────────────────
$pythonBakeDir    = Join-Path $TargetDir 'python_bake'
$sitePackagesDest = Join-Path $pythonBakeDir 'site-packages'
$hfCacheDir       = Join-Path $pythonBakeDir 'hf_cache'
$manifestPath     = Join-Path $pythonBakeDir 'voice_bake_manifest.json'
$toolsVoiceBake   = Join-Path $TargetDir 'tools\voice_bake'
$weightsDest      = Join-Path $toolsVoiceBake 'chatterbox_weights'

Write-Step "Vérification des prérequis"

# ─── ÉTAPE 1 : venv source ──────────────────────────────────────────────────
if (-not (Test-Path $SourceVenv)) {
    Write-Fail "SourceVenv introuvable : $SourceVenv`nCréez-le avec : python -m venv $SourceVenv && pip install torch torchaudio librosa gguf chatterbox@..."
}
$sourcePython = Join-Path $SourceVenv 'Scripts\python.exe'
if (-not (Test-Path $sourcePython)) {
    Write-Fail "python.exe absent du venv source : $sourcePython"
}

# ─── ÉTAPE 2 : script bake ──────────────────────────────────────────────────
if (-not (Test-Path $BakeScript)) {
    Write-Fail "Script bake introuvable : $BakeScript"
}
$chatterboxPathsScript = Join-Path (Split-Path $BakeScript -Parent) 'chatterbox_paths.py'
Write-OK "Script bake : $BakeScript"

# ─── ÉTAPE 3 : poids Chatterbox ─────────────────────────────────────────────
if (-not (Test-Path $ChatterboxWeights)) {
    Write-Fail "ChatterboxWeights introuvable : $ChatterboxWeights"
}
$requiredWeights = @(
    # from_local() opens these files directly (source: ChatterboxTTS.from_local source inspection)
    't3_cfg.safetensors',   # T3 model (from_local uses t3_cfg.safetensors, NOT t3_mtl23ls_v3)
    've.safetensors',       # VoiceEncoder
    's3gen.safetensors',    # S3Gen vocoder
    'tokenizer.json',       # Text tokenizer
    'conds.pt'              # Pre-computed conditioning (builtin voice, optional but expected)
)
foreach ($w in $requiredWeights) {
    if (-not (Test-Path (Join-Path $ChatterboxWeights $w))) {
        Write-Fail "Poids requis absent : $w dans $ChatterboxWeights"
    }
}
Write-OK "Poids Chatterbox présents dans : $ChatterboxWeights"

# ─── ÉTAPE 4 : Versions exactes des packages ────────────────────────────────
Write-Step "Collecte des versions exactes"
$pkgVersions = @{}
$pkgList = @('torch', 'torchaudio', 'numpy', 'librosa', 'gguf')
foreach ($pkg in $pkgList) {
    $v = & $sourcePython -c "import importlib.metadata; print(importlib.metadata.version('$pkg'))" 2>&1
    if ($LASTEXITCODE -eq 0 -and $v -notmatch 'Error') {
        $pkgVersions[$pkg] = $v.Trim()
        Write-Host "  $pkg : $($pkgVersions[$pkg])" -ForegroundColor Gray
    } else {
        Write-Fail "Package $pkg non trouvé dans le venv source. Installez-le avant de bundler."
    }
}

# chatterbox : installé en mode editable depuis clone git — pas de dist-info standard
# Obtenir la version depuis le clone git (SHA) ou le pyproject.toml
$cbVer = & $sourcePython -c @"
try:
    import importlib.metadata
    print(importlib.metadata.version('chatterbox'))
except Exception:
    try:
        import importlib.metadata
        print(importlib.metadata.version('chatterbox-tts'))
    except Exception:
        print('editable@$ChatterboxSha')
"@ 2>&1
$pkgVersions['chatterbox'] = $cbVer.Trim()
Write-Host "  chatterbox : $($pkgVersions['chatterbox'])" -ForegroundColor Gray

# Vérifier que chatterbox est importable (même sans metadata)
$cbTest = & $sourcePython -c "from chatterbox.tts import ChatterboxTTS; print('ok')" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "chatterbox non importable dans le venv source. Installez-le : pip install --no-deps -e <clone>. Erreur: $cbTest"
}
Write-OK "Versions collectées"


# ─── ÉTAPE 5 : Copie du runtime Python base ─────────────────────────────────
Write-Step "Copie du runtime Python base"
New-Item -ItemType Directory -Path $pythonBakeDir -Force | Out-Null

# Copie du venv COMPLET (approche robuste pour DLLs natives torch/numpy)
# Les approches à copie sélective (._pth, pyvenv.cfg seul) échouent car les
# C-extensions (.pyd) cherchent des DLLs via le pyvenv.cfg existant du venv,
# qui sait pointer correctement vers le base_prefix original.
Write-Host "  Copie du venv complet → python_bake\ (peut prendre 3-5 min)" -ForegroundColor Gray
Get-ChildItem $SourceVenv | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $pythonBakeDir $_.Name) -Recurse -Force -ErrorAction SilentlyContinue
}
$venvFileCount = (Get-ChildItem $pythonBakeDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
Write-OK "Venv copié ($venvFileCount fichiers)"

# hf_cache (vide — redirect HF_HOME offline, écrit par la Dart app avant bake)
New-Item -ItemType Directory -Path $hfCacheDir -Force | Out-Null
Write-OK "hf_cache\ créé (redirect HF_HOME)"

# Vérifier que Scripts\python.exe fonctionne de façon autonome (post-copie venv)
$bundlePython = Join-Path $pythonBakeDir 'Scripts\python.exe'
$pyTest = & $bundlePython --version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "python_bake\Scripts\python.exe non fonctionnel : $pyTest"
}
$pythonVersion = $pyTest.Trim()   # ex: "Python 3.11.15" — utilisé dans le manifest
Write-OK "python_bake\Scripts\python.exe autonome : $pythonVersion"

# NOTE: le venv copié apporte son propre pyvenv.cfg qui pointe vers le base_prefix original.
# Aucun rewrite nécessaire — la résolution DLL (numpy, torch) fonctionne via ce pyvenv.cfg.

# ─── ÉTAPE 6 : Validation site-packages (venv complet déjà en place) ────────
Write-Step "Validation site-packages"
# Step 5 a copié le venv COMPLET → Lib\site-packages\ contient déjà tous les packages.
# NE PAS recopier — cela corrompt les packages Rust (.pyd) comme tokenizers.
# On vérifie seulement la présence des packages essentiels.
$sitePackagesDest = Join-Path $pythonBakeDir 'Lib\site-packages'

$essentialPackages = @('torch', 'chatterbox', 'gguf', 'numpy', 'librosa',
                        'transformers', 'tokenizers', 'diffusers', 'safetensors')
$packagesMissing = @()
$packagesCopied  = ($essentialPackages | Where-Object {
    Test-Path (Join-Path $sitePackagesDest $_)
}).Count

foreach ($pkg in $essentialPackages) {
    $present = Test-Path (Join-Path $sitePackagesDest $pkg)
    Write-Host "  $(if($present){'[OK]'}else{'[MISSING]'}) $pkg" -ForegroundColor $(if($present){'Green'}else{'Red'})
    if (-not $present) { $packagesMissing += $pkg }
}

if ($packagesMissing.Count -gt 0) {
    Write-Fail "Packages essentiels manquants dans site-packages : $($packagesMissing -join ', ')"
}
Write-OK "$packagesCopied/$($essentialPackages.Count) packages essentiels présents (venv complet)"


# ─── ÉTAPE 7 : Script bake ──────────────────────────────────────────────────
Write-Step "Copie du script bake"
New-Item -ItemType Directory -Path $toolsVoiceBake -Force | Out-Null
Copy-Item -Path $BakeScript -Destination (Join-Path $toolsVoiceBake 'bake-chatterbox-voice-from-wav.py') -Force
if (Test-Path $chatterboxPathsScript) {
    Copy-Item -Path $chatterboxPathsScript -Destination (Join-Path $toolsVoiceBake 'chatterbox_paths.py') -Force
    Write-OK "chatterbox_paths.py copié"
}
Write-OK "Script bake copié"

# ─── ÉTAPE 8 : Poids Chatterbox ─────────────────────────────────────────────
Write-Step "Copie des poids Chatterbox"
New-Item -ItemType Directory -Path $weightsDest -Force | Out-Null
Get-ChildItem $ChatterboxWeights -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $weightsDest $_.Name) -Force
    Write-Host "  $($_.Name)  $([math]::Round($_.Length/1MB,1)) MB" -ForegroundColor Gray
}
Write-OK "Poids copiés vers $weightsDest"

# ─── ÉTAPE 9 : Smoke test from_local() OFFLINE ──────────────────────────────
Write-Step "Smoke test from_local() offline (appel réel — aucun réseau)"
$smokeScript = @"
import os, sys, time
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['HF_DATASETS_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'

weights_dir = sys.argv[1]
print(f'from_local({weights_dir}) ...')
t0 = time.time()

import torch
from chatterbox.tts import ChatterboxTTS

# Appel réel de from_local() sur CPU
# Cela charge ve.safetensors, t3_cfg.safetensors, s3gen.safetensors,
# tokenizer.json et conds.pt depuis le disque local uniquement.
model = ChatterboxTTS.from_local(weights_dir, device='cpu')
elapsed = time.time() - t0

print(f'from_local OK ({elapsed:.1f}s)')
print(f'torch: {torch.__version__}')

# Lister les attributs chargés (preuve des fichiers lus)
print(f't3 type: {type(model.t3).__name__}')
print(f's3gen type: {type(model.s3gen).__name__}')
print(f've type: {type(model.ve).__name__}')
print(f'tokenizer type: {type(model.tokenizer).__name__}')
print(f'conds: {model.conds is not None}')
print('SMOKE_OK')
"@

$smokePath = Join-Path $env:TEMP 'vb_smoke.py'
[System.IO.File]::WriteAllText($smokePath, $smokeScript, [System.Text.Encoding]::UTF8)

$smokeResult = & (Join-Path $pythonBakeDir 'Scripts\python.exe') $smokePath $weightsDest 2>&1
$smokeResult | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
Remove-Item $smokePath -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0 -or ($smokeResult | Where-Object { $_ -match 'SMOKE_OK' }).Count -eq 0) {
    Write-Fail "Smoke test from_local() échoué. Vérifiez le venv et les poids."
}
Write-OK "Smoke test from_local() PASSED — chargement offline confirmé"


# ─── ÉTAPE 10 : SHA256 de tous les fichiers critiques ───────────────────────
Write-Step "SHA256 des fichiers critiques"
$weightsSha256 = @{}
Get-ChildItem $weightsDest -File | ForEach-Object {
    $sha = Get-FileSha256 $_.FullName
    $weightsSha256[$_.Name] = $sha
    Write-Host "  $($_.Name) : $sha" -ForegroundColor Gray
}

# SHA256 du script bake
$bakeSha256 = Get-FileSha256 (Join-Path $toolsVoiceBake 'bake-chatterbox-voice-from-wav.py')

# SHA256 du Python bundlé
$pythonSha256 = Get-FileSha256 (Join-Path $pythonBakeDir 'python.exe')

# ─── ÉTAPE 11 : Validation composants critiques ─────────────────────────────
Write-Step "Validation composants critiques"
$criticalItems = [ordered]@{
    'Scripts\python.exe'            = (Test-Path (Join-Path $pythonBakeDir 'Scripts\python.exe'))
    'Lib\site-packages\torch'       = (Test-Path (Join-Path $pythonBakeDir 'Lib\site-packages\torch'))
    'Lib\site-packages\chatterbox'  = (Test-Path (Join-Path $pythonBakeDir 'Lib\site-packages\chatterbox'))
    'Lib\site-packages\gguf'        = (Test-Path (Join-Path $pythonBakeDir 'Lib\site-packages\gguf'))
    'Lib\site-packages\numpy'       = (Test-Path (Join-Path $pythonBakeDir 'Lib\site-packages\numpy'))
    'Lib\site-packages\librosa'     = (Test-Path (Join-Path $pythonBakeDir 'Lib\site-packages\librosa'))
    'tools/voice_bake/bake-*.py'    = (Test-Path (Join-Path $toolsVoiceBake 'bake-chatterbox-voice-from-wav.py'))
    # Fichiers réellement lus par from_local() (source inspectée) :
    't3_cfg.safetensors'            = (Test-Path (Join-Path $weightsDest 't3_cfg.safetensors'))
    've.safetensors'                = (Test-Path (Join-Path $weightsDest 've.safetensors'))
    's3gen.safetensors'             = (Test-Path (Join-Path $weightsDest 's3gen.safetensors'))
    'tokenizer.json'                = (Test-Path (Join-Path $weightsDest 'tokenizer.json'))
    'conds.pt'                      = (Test-Path (Join-Path $weightsDest 'conds.pt'))
}
$criticalStatus = [ordered]@{}
$failedCritical = @()
foreach ($k in $criticalItems.Keys) {
    $ok = $criticalItems[$k]
    $criticalStatus[$k] = if ($ok) { 'ok' } else { 'MISSING' }
    if (-not $ok) { $failedCritical += $k }
    Write-Host "  $(if($ok){'[OK]'}else{'[MISSING]'}) $k" -ForegroundColor $(if($ok){'Green'}else{'Red'})
}
if ($failedCritical.Count -gt 0) {
    Write-Fail "Composants critiques MANQUANTS : $($failedCritical -join ', ')"
}
Write-OK "Tous les composants critiques validés"

# ─── ÉTAPE 12 : Manifest ─────────────────────────────────────────────────────
Write-Step "Écriture du manifest"
$pythonBakeMB    = Get-DirSizeMB $pythonBakeDir
$weightsMB       = Get-DirSizeMB $weightsDest
$totalMB         = [math]::Round($pythonBakeMB + $weightsMB, 1)

$manifest = [ordered]@{
    bundle_date              = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    bundle_host              = $env:COMPUTERNAME
    architecture             = 'windows-x86_64'
    python_version           = $pythonVersion
    package_versions         = $pkgVersions
    chatterbox_code_sha      = $ChatterboxSha
    chatterbox_model_revision= $ModelRevision
    bake_script_sha256       = $bakeSha256
    python_exe_sha256        = $pythonSha256
    weights_sha256           = $weightsSha256
    bundle_size_mb           = [ordered]@{
        python_bake  = $pythonBakeMB
        weights      = $weightsMB
        total        = $totalMB
    }
    critical_components      = $criticalStatus
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
Write-OK "Manifest écrit : $manifestPath"

# ─── Rapport final ────────────────────────────────────────────────────────────
Write-Step "Rapport final"
Write-Host ""
Write-Host "  python_bake  : ${pythonBakeMB} MB" -ForegroundColor White
Write-Host "  weights      : ${weightsMB} MB"     -ForegroundColor White
Write-Host "  TOTAL        : ${totalMB} MB"        -ForegroundColor White
Write-Host "  torch        : $($pkgVersions['torch'])"      -ForegroundColor Gray
Write-Host "  chatterbox   : $($pkgVersions['chatterbox'])" -ForegroundColor Gray
Write-Host "  Python       : $pythonVersion"                 -ForegroundColor Gray
Write-Host ""
Write-Host "Voice Bake bundle terminé avec succès !" -ForegroundColor Green

exit 0
