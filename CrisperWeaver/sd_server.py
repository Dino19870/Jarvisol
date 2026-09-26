"""
Local Neural Text-to-Image HTTP Server for CrisperWeaver
Multi-Model Pipeline with auto-discovery, adaptive GPU->CPU retry and zero OOM.
"""

import argparse
import base64
import io
import json
import os
import subprocess
import sys
import time
import uuid
import psutil
import numpy as np
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageStat, ImageChops

try:
    import cv2
except ImportError:
    cv2 = None

try:
    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision as mp_vision
except ImportError:
    mp = None
    mp_python = None
    mp_vision = None

# --- Detection du repertoire reel (PyInstaller --onefile compatible) ----------
if getattr(sys, "frozen", False):
    SCRIPT_DIR = os.path.dirname(os.path.abspath(sys.executable))
else:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# ------------------------------------------------------------------------------

active_process = None


def find_file(filename: str):
    """Recherche un fichier auxiliaire (VAE, CLIP, T5, sd-cli, IP-Adapter) dans les dossiers connus."""
    if not filename:
        return None
    candidates = [
        os.path.join(SCRIPT_DIR, "models", "Stable-diffusion", filename),
        os.path.join(SCRIPT_DIR, "models", filename),
        os.path.join(SCRIPT_DIR, "sd_vulkan", filename),
        os.path.join(SCRIPT_DIR, "models", "image_conditioning", "ip_adapter", filename),
        os.path.join(SCRIPT_DIR, "models", "image_conditioning", "clip_vision", filename),
        os.path.join(SCRIPT_DIR, "models", "image_conditioning", "detectors", filename),
    ]
    # Fallback vers le répertoire runtime de référence si SCRIPT_DIR n'a pas les modèles
    runtime_ref = os.path.join(os.path.dirname(SCRIPT_DIR), "Jarvisol_V1_POST_GEL_Final_v2")
    if os.path.isdir(runtime_ref):
        candidates.extend([
            os.path.join(runtime_ref, "models", "Stable-diffusion", filename),
            os.path.join(runtime_ref, "models", filename),
            os.path.join(runtime_ref, "sd_vulkan", filename),
            os.path.join(runtime_ref, "models", "image_conditioning", "ip_adapter", filename),
            os.path.join(runtime_ref, "models", "image_conditioning", "clip_vision", filename),
            os.path.join(runtime_ref, "models", "image_conditioning", "detectors", filename),
        ])
    for c in candidates:
        if os.path.exists(c):
            return os.path.abspath(c)
    return None


def find_conditioning_file(filename: str):
    """Recherche un fichier de conditionnement (IP-Adapter, CLIP Vision, détecteur)."""
    if not filename:
        return None
    direct = find_file(filename)
    if direct:
        return direct
    search_dirs = [
        os.path.join(SCRIPT_DIR, "models", "image_conditioning"),
        os.path.join(os.path.dirname(SCRIPT_DIR), "Jarvisol_V1_POST_GEL_Final_v2", "models", "image_conditioning"),
    ]
    stem = os.path.splitext(filename)[0].lower()
    for base in search_dirs:
        if not os.path.isdir(base):
            continue
        for root, _, files in os.walk(base):
            for f in files:
                if stem in f.lower() or f.lower() in stem:
                    return os.path.abspath(os.path.join(root, f))
    return None


# --- Auto-discovery des modeles principaux ------------------------------------

_AUXILIARY_FRAGMENTS = [
    "ae.", "vae", "clip_l", "clip_g", "t5xxl", "t5-", "lora", "controlnet",
    "embedding", "textual", "hypernetwork", "ggml", "encoder", "tokenizer",
    "adapter", "canny", "depth", "normal", "openpose", "shuffle", "mlsd",
    "hed", "scribble", "seg", "chatterbox", "kokoro", "parakeet", "qwen3-tts",
    "vibevoice", "f5-tts", "tts", "voice",
]


def _is_auxiliary(filename: str) -> bool:
    name = filename.lower()
    if "bakedvae" in name:
        return False
    return any(frag in name for frag in _AUXILIARY_FRAGMENTS)


def _classify_model(filename: str) -> str:
    name = filename.lower()
    if "flux" in name:
        return "flux"
    if "chroma" in name:
        return "chroma"
    if "sd3" in name or "sd-3" in name or "stable-diffusion-3" in name:
        return "sd3"
    if "inpaint" in name:
        return "inpaint"
    if "turbo" in name and "sd3" not in name and "flux" not in name and "chroma" not in name:
        return "turbo"
    if ("sdxl" in name or "xl" in name or "pony" in name) and "sd1" not in name:
        return "sdxl"
    return "sd1x"


def scan_available_models() -> dict:
    search_dirs = [
        os.path.join(SCRIPT_DIR, "models", "Stable-diffusion"),
        os.path.join(SCRIPT_DIR, "models"),
        os.path.join(SCRIPT_DIR, "sd_vulkan"),   # P1 — répertoire portable des modèles
        os.path.join(os.path.dirname(SCRIPT_DIR), "Jarvisol_V1_POST_GEL_Final_v2", "models", "Stable-diffusion"),
        os.path.join(os.path.dirname(SCRIPT_DIR), "Jarvisol_V1_POST_GEL_Final_v2", "models"),
        os.path.join(os.path.dirname(SCRIPT_DIR), "Jarvisol_V1_POST_GEL_Final_v2", "sd_vulkan"),
    ]
    found = {"chroma": [], "flux": [], "sd3": [], "sdxl": [], "inpaint": [], "turbo": [], "sd1x": []}
    seen = set()
    for d in search_dirs:
        if not os.path.isdir(d):
            continue
        for fname in os.listdir(d):
            ext = os.path.splitext(fname)[1].lower()
            if ext not in {".gguf", ".safetensors"}:
                continue
            if _is_auxiliary(fname):
                continue
            fpath = os.path.abspath(os.path.join(d, fname))
            if fpath in seen:
                continue
            seen.add(fpath)
            try:
                if os.path.getsize(fpath) < 200 * 1024 * 1024:
                    continue
            except OSError:
                continue
            mtype = _classify_model(fname)
            found[mtype].append(fpath)
    return found



_MODEL_CACHE: dict = {}


def get_models(force_refresh: bool = False) -> dict:
    global _MODEL_CACHE
    if not _MODEL_CACHE or force_refresh:
        _MODEL_CACHE = scan_available_models()
        total = sum(len(v) for v in _MODEL_CACHE.values())
        print(f"[Model Discovery] {total} modele(s) trouve(s) (force_refresh={force_refresh}) :")
        for mtype, paths in _MODEL_CACHE.items():
            for p in paths:
                print(f"  [{mtype.upper():6s}] {os.path.basename(p)}")
        if total == 0:
            print("[Model Discovery] ATTENTION : Aucun modele dans models/ - placez un .gguf dans models/Stable-diffusion/")
    return _MODEL_CACHE


def pick_best_model(hint: str = "", force_refresh: bool = False) -> tuple:
    models = get_models(force_refresh=force_refresh)
    hint_lower = hint.lower().strip()
    if hint_lower:
        # Recherche exacte par type (inpaint inclus)
        for mtype in ("chroma", "flux", "sd3", "sdxl", "inpaint", "turbo", "sd1x"):
            if hint_lower == mtype and models.get(mtype):
                return models[mtype][0], mtype
        # Recherche partielle dans le nom de fichier (inpaint inclus)
        for mtype in ("inpaint", "turbo", "sd1x", "sdxl", "sd3", "flux", "chroma"):
            for p in models.get(mtype, []):
                if hint_lower in os.path.basename(p).lower():
                    return p, mtype
        # Recherche partielle dans le type
        for mtype in ("chroma", "flux", "sd3", "sdxl", "inpaint", "turbo", "sd1x"):
            if mtype in hint_lower and models.get(mtype):
                return models[mtype][0], mtype
    # Sélection automatique par défaut : inpaint EXCLU (réservé à l'usage explicite)
    for mtype in ("turbo", "sd1x", "sdxl", "sd3", "flux", "chroma"):
        if models.get(mtype):
            return models[mtype][0], mtype
    return None, None


def all_model_names(force_refresh: bool = False) -> list:
    models = get_models(force_refresh=force_refresh)
    return [os.path.basename(p) for paths in models.values() for p in paths]


def resolve_explicit_model(model_name: str, force_refresh: bool = False) -> tuple:
    """
    Résolution STRICTE pour une sélection explicite de modèle (Inpainting / Multi-Images).
    Interdit formellement toute substitution silencieuse :
    Si model_name est spécifié mais introuvable, retourne (None, None).
    """
    if not model_name or not model_name.strip():
        return None, None
    models = get_models(force_refresh=force_refresh)

    # 0. Chemin direct vers un fichier existant sur disque
    clean_name = model_name.strip()
    if os.path.isfile(clean_name):
        norm_path = os.path.abspath(clean_name)
        for mtype, paths in models.items():
            for p in paths:
                if os.path.abspath(p).lower() == norm_path.lower():
                    return p, mtype
        return norm_path, _classify_model(os.path.basename(norm_path))

    target_base = os.path.basename(clean_name).lower()

    # 1. Correspondance exacte du nom de fichier
    for mtype, paths in models.items():
        for p in paths:
            base = os.path.basename(p).lower()
            if base == target_base:
                return p, mtype

    # 2. Correspondance sans extension ou sous-chaîne significative
    for mtype, paths in models.items():
        for p in paths:
            base = os.path.basename(p).lower()
            base_no_ext = os.path.splitext(base)[0]
            target_no_ext = os.path.splitext(target_base)[0]
            if base_no_ext == target_no_ext or (len(target_no_ext) >= 5 and target_no_ext in base):
                return p, mtype

    return None, None


# --- Helpers ------------------------------------------------------------------

def _kill_proc_tree(proc):
    """Arrête proprement l'ensemble de l'arbre de processus pour éviter les orphelins."""
    if proc is None:
        return
    try:
        if sys.platform == "win32":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        else:
            proc.kill()
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
    try:
        proc.wait(timeout=2)
    except Exception:
        pass


is_interrupted = False


def interrupt_active_generation():
    global active_process, is_interrupted
    is_interrupted = True
    if active_process is not None:
        try:
            print("[Neural Image Engine] Interruption manuelle demandée. Arrêt immédiat de l'arbre...")
            _kill_proc_tree(active_process)
            active_process = None
            return True
        except Exception as e:
            print(f"[Neural Image Engine] Erreur interruption : {e}")
    return False


_OOM_MARKERS = [
    "ErrorOutOfDeviceMemory", "vae alloc compute buffer failed",
    "vae: failed to allocate", "failed to allocate Vulkan",
    "decode_first_stage failed",
]


def _is_vram_oom(log: str) -> bool:
    return any(m in log for m in _OOM_MARKERS)


def validate_real_image(img_bytes: bytes, min_bytes: int = 500) -> tuple:
    """
    Oracle de validation d'image réelle (JARVISOL-IMAGE-PORTABILITY-TIMEOUT-V1).
    Garantit qu'une image vide, noire, blanche, uniforme, corrompue ou tronquée
    n'est JAMAIS considérée comme un succès.
    Retourne (is_valid: bool, reason: str).
    """
    if not img_bytes or len(img_bytes) < min_bytes:
        size_str = f"{len(img_bytes)} octets" if img_bytes else "0 octet"
        return False, f"GENERATION_FAILED_INVALID_OUTPUT: taille insuffisante ({size_str} < {min_bytes})"

    try:
        with Image.open(io.BytesIO(img_bytes)) as im:
            im.load()
            w, h = im.size
            if w <= 0 or h <= 0:
                return False, f"GENERATION_FAILED_INVALID_OUTPUT: dimensions invalides ({w}x{h})"

            rgb = im.convert("RGB")
            stat = ImageStat.Stat(rgb)
            extrema = stat.extrema
            if all(low == high for (low, high) in extrema):
                val = extrema[0][0]
                if val == 0:
                    return False, "GENERATION_FAILED_INVALID_OUTPUT: image entièrement noire"
                elif val == 255:
                    return False, "GENERATION_FAILED_INVALID_OUTPUT: image entièrement blanche"
                return False, f"GENERATION_FAILED_INVALID_OUTPUT: image monochrome uniforme (valeur={val})"

            avg_std = sum(stat.stddev) / len(stat.stddev)
            if avg_std < 2.0:
                return False, f"GENERATION_FAILED_INVALID_OUTPUT: variance quasi-nulle ({avg_std:.2f} < 2.0)"

            return True, "OK"
    except Exception as e:
        return False, f"GENERATION_FAILED_INVALID_OUTPUT: décodage corrompu ({e})"


def _run_sd_cli(cmd: list, work_dir: str, output_png: str, unique_id: str,
                stalled_timeout: int = 120, base_wall_clock: int = 900,
                max_wall_clock: int = 7200):
    """
    Exécute sd-cli avec surveillance d'activité multi-signaux (stdout + progression CPU psutil)
    et budget dynamique extensible pour garantir que 'LENT + ACTIF != BLOQUÉ' tout en
    neutralisant les processus réellement bloqués (STALLED) ou annulés par l'utilisateur.
    """
    global active_process, is_interrupted
    import threading
    import queue

    is_interrupted = False
    log_chunks = []
    q = queue.Queue()

    def _reader(pipe, out_q):
        try:
            while True:
                chunk = pipe.read(256)
                if not chunk:
                    break
                out_q.put(chunk)
        except Exception:
            pass
        finally:
            pipe.close()

    try:
        active_process = subprocess.Popen(
            cmd, cwd=work_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        ps_proc = None
        try:
            ps_proc = psutil.Process(active_process.pid)
        except Exception:
            ps_proc = None

        t = threading.Thread(target=_reader, args=(active_process.stdout, q))
        t.daemon = True
        t.start()

        start_time = time.time()
        last_active_time = time.time()
        last_stdout_time = time.time()
        last_cpu_activity_time = time.time()
        last_cpu_total = 0.0
        if ps_proc:
            try:
                ct = ps_proc.cpu_times()
                last_cpu_total = ct.user + ct.system
            except Exception:
                pass

        effective_wall_clock = float(base_wall_clock)
        process_state = "ACTIVE"

        while True:
            # 0. Interruption utilisateur immédiate
            if is_interrupted:
                print(f"[Neural Image Engine] [{unique_id}] Annulation utilisateur détectée. Nettoyage...")
                _kill_proc_tree(active_process)
                active_process = None
                if os.path.exists(output_png):
                    try: os.remove(output_png)
                    except Exception: pass
                raw_log = b"".join(log_chunks).decode("utf-8", errors="ignore")
                return None, f"{raw_log}\n[USER_CANCEL] Opération annulée par l'utilisateur"

            ret = active_process.poll()
            now = time.time()

            # 1. Collecte des sorties stdout brutes
            got_stdout = False
            while not q.empty():
                try:
                    c = q.get_nowait()
                    log_chunks.append(c)
                    got_stdout = True
                except queue.Empty:
                    break

            if got_stdout:
                last_stdout_time = now

            # 2. Mesure de la progression CPU (Kernel + User)
            got_cpu_progress = False
            if ps_proc and ret is None:
                try:
                    ct = ps_proc.cpu_times()
                    curr_cpu_total = ct.user + ct.system
                    cpu_delta = curr_cpu_total - last_cpu_total
                    if cpu_delta > 0.05:  # Progression significative de calcul
                        got_cpu_progress = True
                        last_cpu_activity_time = now
                        last_cpu_total = curr_cpu_total
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass

            # 3. Qualification de l'état du processus (ACTIVE / IDLE_BUT_ALIVE / STALLED / DEAD)
            if got_stdout or got_cpu_progress:
                process_state = "ACTIVE"
                last_active_time = now
            elif ret is not None:
                process_state = "DEAD"
            else:
                process_state = "IDLE_BUT_ALIVE"

            # 4. Si le processus s'est terminé
            if ret is not None:
                t.join(timeout=1.0)
                while not q.empty():
                    try:
                        log_chunks.append(q.get_nowait())
                    except queue.Empty:
                        break
                break

            # 5. Détection de blocage réel (STALLED) : convergence de silence stdout ET absence de calcul CPU
            inactivity_duration = now - last_active_time
            if inactivity_duration > stalled_timeout:
                print(f"[Neural Image Engine] [{unique_id}] WATCHDOG STALLED : Aucune progression CPU ni stdout depuis {inactivity_duration:.1f}s (> {stalled_timeout}s). Processus bloqué tué.")
                _kill_proc_tree(active_process)
                active_process = None
                if os.path.exists(output_png):
                    try: os.remove(output_png)
                    except Exception: pass
                raw_log = b"".join(log_chunks).decode("utf-8", errors="ignore")
                return None, f"{raw_log}\n[WATCHDOG_STALLED] Processus terminé pour absence d'activité CPU et stdout (> {stalled_timeout}s)"

            # 6. Gestion du plafond dynamique extensible (LENT + ACTIF != BLOQUÉ)
            elapsed = now - start_time
            if elapsed > effective_wall_clock:
                # Si le processus est actif (calcul en cours dans les 30 dernières secondes)
                if (now - last_active_time) < 30.0 and effective_wall_clock < max_wall_clock:
                    effective_wall_clock = min(elapsed + 300.0, float(max_wall_clock))
                    print(f"[Neural Image Engine] [{unique_id}] Budget étendu dynamiquement: calcul CPU actif (écoulé: {int(elapsed)}s, nouveau plafond: {int(effective_wall_clock)}s)")
                else:
                    # Non actif ou plafond absolu ultime atteint
                    print(f"[Neural Image Engine] [{unique_id}] TIMEOUT : Plafond global ({int(effective_wall_clock)}s) atteint sans progression active récente. Processus tué.")
                    _kill_proc_tree(active_process)
                    active_process = None
                    if os.path.exists(output_png):
                        try: os.remove(output_png)
                        except Exception: pass
                    raw_log = b"".join(log_chunks).decode("utf-8", errors="ignore")
                    return None, f"{raw_log}\n[TIMEOUT] Plafond d'exécution dépassé ({int(effective_wall_clock)}s)"

            time.sleep(0.2)

        active_process = None
        raw_log = b"".join(log_chunks).decode("utf-8", errors="ignore")

        if os.path.exists(output_png):
            with open(output_png, "rb") as f:
                data = f.read()
            try:
                os.remove(output_png)
            except Exception:
                pass

            # Validation Oracle
            is_valid, reason = validate_real_image(data)
            if not is_valid:
                print(f"[Neural Image Engine] [{unique_id}] [Oracle Rejet] {reason}")
                return None, f"{raw_log}\n[ORACLE_REJECT] {reason}"

            return data, raw_log

        return None, raw_log

    except Exception as e:
        if active_process:
            _kill_proc_tree(active_process)
            active_process = None
        if os.path.exists(output_png):
            try: os.remove(output_png)
            except Exception: pass
        return None, str(e)


def build_chroma_cmd(sd_cli: str, model_file: str, prompt: str, output_png: str,
                     vae_file: str, t5_file: str, steps: int = 8,
                     t5_on_cpu: bool = False, width: int = 768, height: int = 768) -> list:
    """Construit la commande sd-cli déterministe pour Chroma."""
    cmd = [
        sd_cli, "-t", "16", "-p", prompt.strip(),
        "-W", str(width), "-H", str(height), "--steps", str(steps), "-o", output_png,
        "--diffusion-model", model_file,
        "--vae", vae_file,
        "--t5xxl", t5_file,
        "--cfg-scale", "1.0",
        "--guidance", "0.0",
        "--sampling-method", "euler",
        "--scheduler", "simple",
        "--model-args", "chroma_use_dit_mask=false",
        "--vae-tiling", "--vae-on-cpu",
    ]
    if t5_on_cpu:
        cmd.append("--t5xxl-on-cpu")
    return cmd


def resolve_generation_dimensions(width: int, height: int, mtype: str) -> tuple:
    """
    Détermine les dimensions compatibles pour l'architecture cible (AUD-IMG-05 / TNR-057).
    Profil standard :
      - chroma / flux / sdxl / sd3 : 768x768 (profil stable VRAM)
      - sd1x / turbo : 512x512
    Si la requête spécifie des dimensions valides (multiples de 64 dans la plage supportée) :
      - chroma / flux / sdxl / sd3 : multiples de 64 dans [512, 768] (ou 1024)
      - sd1x / turbo : multiples de 64 dans [256, 512]
    Si non supporté ou hors profil : normalise vers la dimension nominale et indique is_normalized = True.
    """
    is_heavy = mtype in ("chroma", "flux", "sdxl", "sd3")
    nominal_w, nominal_h = (768, 768) if is_heavy else (512, 512)

    if width <= 0 or height <= 0:
        return nominal_w, nominal_h, False

    valid_multiple = (width % 64 == 0) and (height % 64 == 0)

    if is_heavy:
        if valid_multiple and (width, height) in [(512, 512), (768, 768)]:
            return width, height, False
        else:
            return nominal_w, nominal_h, (width != nominal_w or height != nominal_h)
    else:
        if valid_multiple and (width, height) in [(256, 256), (512, 512)]:
            return width, height, False
        else:
            return nominal_w, nominal_h, (width != nominal_w or height != nominal_h)


def _wrap_result(img_bytes: bytes, target_w: int, target_h: int, req_w: int, req_h: int) -> tuple:
    """Garantit l'alignement strict entre métadonnées annoncées et dimensions réelles de l'image (TNR-057)."""
    actual_w, actual_h = target_w, target_h
    if img_bytes:
        try:
            with Image.open(io.BytesIO(img_bytes)) as im:
                actual_w, actual_h = im.size
        except Exception:
            pass
    is_norm = (actual_w != req_w) or (actual_h != req_h)
    return img_bytes, actual_w, actual_h, is_norm


# --- Generation principale ----------------------------------------------------

def generate_real_neural_image(prompt: str, model_name: str = "", width: int = 512, height: int = 512, steps: int = 15) -> tuple:
    global active_process
    sd_cli = find_file("sd-cli.exe")
    unique_id = uuid.uuid4().hex[:8]
    output_png = os.path.join(SCRIPT_DIR, f"temp_gen_{unique_id}.png")

    model_file, mtype = pick_best_model(model_name)
    if not model_file:
        print(f"[Neural Image Engine] [{unique_id}] ERREUR : Aucun modele trouve dans models/")
        print(f"[Neural Image Engine] Placez un .gguf dans : {os.path.join(SCRIPT_DIR, 'models', 'Stable-diffusion')}")
        raise RuntimeError("Aucun modèle de diffusion disponible pour la génération.")

    is_chroma = (mtype == "chroma")
    is_flux   = (mtype == "flux")
    is_sd3    = (mtype == "sd3")
    is_sdxl   = (mtype == "sdxl")
    is_turbo  = (mtype == "turbo")

    w, h, is_normalized = resolve_generation_dimensions(width, height, mtype)
    if is_normalized:
        print(f"[Neural Image Engine] [{unique_id}] Normalisation dimensions : demandées {width}x{height} -> effectives {w}x{h} (profil sécurisé VRAM)")

    is_chroma_flash = is_chroma and ("flash" in os.path.basename(model_file).lower())
    is_lightning = "lightning" in os.path.basename(model_file).lower()
    if is_chroma:
        step_count = 8 if is_chroma_flash else 20
    elif is_flux or is_sd3 or is_turbo:
        step_count = 4
    elif is_lightning:
        step_count = 8
    else:
        step_count = 25
    clean_prompt = prompt.strip()

    print(f"[Neural Image Engine] [{unique_id}] Modele : \"{os.path.basename(model_file)}\" (type:{mtype})")
    print(f"[Neural Image Engine] [{unique_id}] Prompt : \"{clean_prompt}\" ({w}x{h}, {step_count} steps)")

    if not sd_cli:
        print(f"[Neural Image Engine] [{unique_id}] ERREUR : sd-cli.exe introuvable dans {SCRIPT_DIR}")
        raise RuntimeError("sd-cli.exe introuvable pour la génération.")

    work_dir = os.path.dirname(sd_cli)
    base_cmd = [sd_cli, "-t", "16", "-p", clean_prompt,
                "-W", str(w), "-H", str(h), "--steps", str(step_count), "-o", output_png]

    # --- CHROMA --------------------------------------------------------------
    if is_chroma:
        vae_file = find_file("ae.safetensors")
        t5_file  = find_file("t5xxl_q4_k.gguf")

        if vae_file and t5_file:
            print(f"[Neural Image Engine] [{unique_id}] [CHROMA] Vulkan-safe args: --model-args chroma_use_dit_mask=false --guidance 0.0 --scheduler simple")
            chroma_base = build_chroma_cmd(sd_cli, model_file, clean_prompt, output_png,
                                           vae_file, t5_file, steps=step_count, t5_on_cpu=False, width=w, height=h)
            print(f"[Neural Image Engine] [{unique_id}] CHROMA 1/2 - T5 GPU")
            img, log = _run_sd_cli(chroma_base, work_dir, output_png, unique_id)
            if img:
                print(f"[Neural Image Engine] [{unique_id}] OK CHROMA (T5 GPU)")
                return _wrap_result(img, w, h, width, height)

            print(f"[Neural Image Engine] [{unique_id}] CHROMA 2/2 - T5 sur CPU (fallback VRAM)")
            chroma_cpu = build_chroma_cmd(sd_cli, model_file, clean_prompt, output_png,
                                          vae_file, t5_file, steps=step_count, t5_on_cpu=True, width=w, height=h)
            img, log = _run_sd_cli(chroma_cpu, work_dir, output_png, unique_id)
            if img:
                print(f"[Neural Image Engine] [{unique_id}] OK CHROMA (T5 CPU)")
                return _wrap_result(img, w, h, width, height)
            print(f"[Neural Image Engine] [{unique_id}] CHROMA impossible -> bascule SD")
        else:
            missing = []
            if not vae_file: missing.append("ae.safetensors")
            if not t5_file: missing.append("t5xxl_q4_k.gguf")
            print(f"[Neural Image Engine] [{unique_id}] CHROMA: fichiers manquants ({', '.join(missing)}) -> bascule SD")

        mdls = get_models()
        fallback_file, fallback_type = None, None
        for ft in ("turbo", "sd1x", "sdxl"):
            if mdls.get(ft):
                fallback_file, fallback_type = mdls[ft][0], ft
                break
        if fallback_file:
            print(f"[Neural Image Engine] [{unique_id}] Bascule {fallback_type}: {os.path.basename(fallback_file)}")
            fb_cmd = [sd_cli, "-t", "16", "-p", clean_prompt,
                      "-W", "512", "-H", "512", "--steps", "4", "-o", output_png,
                      "-m", fallback_file, "--cfg-scale", "7.0", "--sampling-method", "euler_a"]
            for attempt, extra in enumerate([[], ["--vae-on-cpu", "--vae-tiling"], ["--backend", "cpu"]]):
                mode = "GPU" if attempt == 0 else ("CPU VAE" if attempt == 1 else "Pure CPU")
                print(f"[Neural Image Engine] [{unique_id}] Bascule {fallback_type} {attempt + 1}/3 - {mode}")
                img, log = _run_sd_cli(fb_cmd + extra, work_dir, output_png, unique_id)
                if img:
                    print(f"[Neural Image Engine] [{unique_id}] OK {fallback_type} {mode}")
                    return _wrap_result(img, 512, 512, width, height)
                print(f"[Neural Image Engine] [{unique_id}] {fallback_type} {mode} échoué -> essai suivant")
        raise RuntimeError(f"Échec de génération d'image Chroma/SD (tentatives GPU/CPU épuisées ou rejetées par l'oracle) — {prompt}")

    # --- FLUX ----------------------------------------------------------------
    if is_flux:
        vae_file  = find_file("ae.safetensors")
        clip_file = find_file("clip_l.safetensors")
        t5_file   = find_file("t5xxl_q4_k.gguf")

        if vae_file and clip_file:
            flux_base = base_cmd + [
                "--diffusion-model", model_file,
                "--vae", vae_file, "--clip_l", clip_file, "--cfg-scale", "1.0",
                "--vae-tiling", "--vae-on-cpu",
            ]
            if t5_file:
                flux_base += ["--t5xxl", t5_file]

            print(f"[Neural Image Engine] [{unique_id}] FLUX 1/2 - encodeurs GPU")
            img, log = _run_sd_cli(flux_base, work_dir, output_png, unique_id)
            if img:
                print(f"[Neural Image Engine] [{unique_id}] OK FLUX (encodeurs GPU)")
                return _wrap_result(img, w, h, width, height)

            print(f"[Neural Image Engine] [{unique_id}] FLUX 2/2 - CLIP+T5 sur CPU")
            extra_cpu = ["--clip-on-cpu"] + (["--t5xxl-on-cpu"] if t5_file else [])
            img, log = _run_sd_cli(flux_base + extra_cpu, work_dir, output_png, unique_id)
            if img:
                print(f"[Neural Image Engine] [{unique_id}] OK FLUX (CLIP+T5 CPU)")
                return _wrap_result(img, w, h, width, height)
            print(f"[Neural Image Engine] [{unique_id}] FLUX impossible -> bascule SD")
        else:
            print(f"[Neural Image Engine] [{unique_id}] FLUX: VAE/CLIP manquants -> bascule SD")

        mdls = get_models()
        fallback_file, fallback_type = None, None
        for ft in ("turbo", "sd1x", "sdxl"):
            if mdls.get(ft):
                fallback_file, fallback_type = mdls[ft][0], ft
                break
        if fallback_file:
            print(f"[Neural Image Engine] [{unique_id}] Bascule {fallback_type}: {os.path.basename(fallback_file)}")
            fb_cmd = [sd_cli, "-t", "16", "-p", clean_prompt,
                      "-W", "512", "-H", "512", "--steps", "4", "-o", output_png,
                      "-m", fallback_file, "--cfg-scale", "7.0", "--sampling-method", "euler_a"]
            for attempt, extra in enumerate([[], ["--vae-on-cpu", "--vae-tiling"], ["--backend", "cpu"]]):
                mode = "GPU" if attempt == 0 else ("CPU VAE" if attempt == 1 else "Pure CPU")
                print(f"[Neural Image Engine] [{unique_id}] Bascule {fallback_type} {attempt + 1}/3 - {mode}")
                img, log = _run_sd_cli(fb_cmd + extra, work_dir, output_png, unique_id)
                if img:
                    print(f"[Neural Image Engine] [{unique_id}] OK {fallback_type} {mode}")
                    return _wrap_result(img, 512, 512, width, height)
                print(f"[Neural Image Engine] [{unique_id}] {fallback_type} {mode} échoué -> essai suivant")
        raise RuntimeError(f"Échec de génération d'image FLUX/SD (tentatives GPU/CPU épuisées ou rejetées par l'oracle) — {prompt}")

    # --- SD3 -----------------------------------------------------------------
    if is_sd3:
        vae_file = find_file("sd3_vae.safetensors") or find_file("ae.safetensors")
        clip_l   = find_file("clip_l.safetensors")
        clip_g   = find_file("clip_g.safetensors")
        t5_file  = find_file("t5xxl_q4_k.gguf")
        if not (vae_file and clip_l and clip_g):
            print(f"[Neural Image Engine] [{unique_id}] SD3: fichiers auxiliaires manquants")
            raise RuntimeError(f"SD3: fichiers auxiliaires VAE/CLIP manquants — {prompt}")
        sd3_args = ["--vae-tiling", "--diffusion-model", model_file,
                    "--vae", vae_file, "--clip_l", clip_l, "--clip_g", clip_g, "--cfg-scale", "1.5"]
        if t5_file:
            sd3_args += ["--t5xxl", t5_file]
        for attempt, extra in enumerate([[], ["--vae-on-cpu", "--vae-tiling"], ["--backend", "cpu"]]):
            mode = "GPU" if attempt == 0 else ("CPU VAE" if attempt == 1 else "Pure CPU")
            print(f"[Neural Image Engine] [{unique_id}] SD3 {attempt + 1}/3 - {mode}")
            img, log = _run_sd_cli(base_cmd + sd3_args + extra, work_dir, output_png, unique_id)
            if img:
                print(f"[Neural Image Engine] [{unique_id}] OK SD3 {mode}")
                return _wrap_result(img, w, h, width, height)
            print(f"[Neural Image Engine] [{unique_id}] SD3 {mode} échoué -> essai suivant")
        raise RuntimeError(f"Échec de génération d'image SD3 (tentatives GPU/CPU épuisées ou rejetées par l'oracle) — {prompt}")

    # --- SDXL / Turbo / SD 1.x -----------------------------------------------
    m_lower = os.path.basename(model_file).lower()
    if "lightning" in m_lower:
        cfg = "2.0"
        sampler = "euler_a"
    elif "pony" in m_lower:
        cfg = "6.0"
        sampler = "euler_a"
    elif "juggernaut" in m_lower:
        cfg = "6.0"
        sampler = "euler_a"
    elif is_sdxl:
        cfg = "6.5"
        sampler = "euler_a"
    elif is_turbo:
        cfg = "7.0"
        sampler = "euler_a"
    else:
        cfg = "7.0"
        sampler = "euler_a"
    sd_args = ["-m", model_file, "--cfg-scale", cfg, "--sampling-method", sampler]
    for attempt, extra in enumerate([[], ["--vae-on-cpu", "--vae-tiling"], ["--backend", "cpu"]]):
        mode = "GPU" if attempt == 0 else ("CPU VAE" if attempt == 1 else "Pure CPU")
        print(f"[Neural Image Engine] [{unique_id}] {mtype.upper()} {attempt + 1}/3 - {mode}")
        img, log = _run_sd_cli(base_cmd + sd_args + extra, work_dir, output_png, unique_id)
        if img:
            print(f"[Neural Image Engine] [{unique_id}] OK {mtype.upper()} {mode}")
            return _wrap_result(img, w, h, width, height)
        oom_info = " [OOM]" if _is_vram_oom(log) else " [echec]"
        print(f"[Neural Image Engine] [{unique_id}] {mtype.upper()}{oom_info} ({mode}) -> essai suivant")
    raise RuntimeError(f"Échec de génération {mtype.upper()} (tentatives GPU/CPU épuisées ou rejetées par l'oracle) — {prompt}")


def generate_fallback_art(prompt: str, width: int = 512, height: int = 512) -> bytes:
    img = Image.new("RGB", (width, height), color=(20, 24, 38))
    draw = ImageDraw.Draw(img)
    margin = 20
    draw.rounded_rectangle([margin, margin, width - margin, height - margin],
                            radius=14, outline=(100, 180, 255), width=2)
    draw.text((margin + 16, margin + 14), "CrisperWeaver Neural Image Engine", fill=(180, 200, 255))
    caption = f'"{prompt}"'
    if len(caption) > 42:
        caption = caption[:39] + "...\""
    draw.text((margin + 16, height - margin - 26), caption, fill=(245, 245, 245))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()



def find_vae_for_sd1x() -> str:
    """Cherche le VAE externe pour les modèles SD 1.x / noVAE."""
    candidates = [
        "vae-ft-mse-840000-ema-pruned.safetensors",
        "vae-ft-mse-840000-ema-pruned.ckpt",
        "vae-ft-mse.safetensors",
        "vae-ft-ema.safetensors",
    ]
    extra_dirs = [
        os.path.join(SCRIPT_DIR, "models", "VAE"),
        os.path.join(SCRIPT_DIR, "models", "vae"),
        os.path.join(SCRIPT_DIR, "sd_vulkan"),   # P1 — VAE dans répertoire portable
    ]
    for name in candidates:
        f = find_file(name)
        if f:
            return f
        for d in extra_dirs:
            p = os.path.join(d, name)
            if os.path.exists(p):
                return os.path.abspath(p)
    return None


def inpaint_image(image_b64: str, mask_b64: str, prompt: str,
                  strength: float = 0.75, steps: int = 20,
                  model_hint: str = "",
                  ip_adapter_file: str = None,
                  clip_vision_file: str = None,
                  ref_image_b64: str = None) -> bytes:
    """
    Inpainting avec le modèle dédié : image originale + masque blanc → image modifiée.
    Le masque doit être en niveaux de gris : blanc = zones à régénérer, noir = zones à conserver.
    Supporte le conditionnement IP-Adapter + CLIP-Vision optionnel pour la composition multi-images.
    model_hint : nom de fichier partiel ou chemin (ex: "Realistic_Vision_V6.0_NV_B1_inpainting_fp16")
    """
    sd_cli = find_file("sd-cli.exe")
    if not sd_cli:
        # P0 — pas de fallback silencieux : erreur explicite remontée au client
        raise RuntimeError("sd-cli.exe introuvable — inpainting impossible (vérifiez sd_vulkan/sd-cli.exe)")

    # Résolution du modèle : sélection explicite stricte -> recherche automatique si non renseigné
    inpaint_file = None
    if model_hint and model_hint.strip():
        inpaint_file, _ = resolve_explicit_model(model_hint)
        if not inpaint_file:
            raise RuntimeError(f"MODEL_NOT_FOUND: Le modèle explicitement demandé '{model_hint}' est introuvable sur le disque. Aucune substitution silencieuse autorisée.")
    else:
        inpaint_file, _ = pick_best_model("inpaint")
        if not inpaint_file:
            raise RuntimeError(f"Aucun modèle inpainting détecté dans les répertoires de modèles — {prompt}")

    uid = uuid.uuid4().hex[:8]
    img_path  = os.path.join(SCRIPT_DIR, f"tmp_inp_img_{uid}.png")
    mask_path = os.path.join(SCRIPT_DIR, f"tmp_inp_mask_{uid}.png")
    ref_path  = os.path.join(SCRIPT_DIR, f"tmp_inp_ref_{uid}.png") if ref_image_b64 else None
    out_path  = os.path.join(SCRIPT_DIR, f"tmp_inp_out_{uid}.png")

    try:
        # Écriture des fichiers temporaires
        with open(img_path,  "wb") as f: f.write(base64.b64decode(image_b64))
        with open(mask_path, "wb") as f: f.write(base64.b64decode(mask_b64))
        if ref_path and ref_image_b64:
            with open(ref_path, "wb") as f: f.write(base64.b64decode(ref_image_b64))

        work_dir = os.path.dirname(sd_cli)
        cmd = [
            sd_cli,
            "-m", inpaint_file,
            "-p", prompt.strip() or "high quality photo",
            "--init-img", img_path,
            "--mask", mask_path,
            "--strength", str(round(strength, 2)),
            "--steps", str(steps),
            "--cfg-scale", "7.0",
            "--sampling-method", "euler_a",
            "-t", "8",
            "-o", out_path,
        ]

        if ip_adapter_file and clip_vision_file and ref_path:
            cmd += [
                "--ip-adapter", ip_adapter_file,
                "--clip_vision", clip_vision_file,
                "--ip-adapter-image", ref_path,
            ]
            print(f"[Inpaint] [{uid}] IP-Adapter : {os.path.basename(ip_adapter_file)}")
            print(f"[Inpaint] [{uid}] CLIP-Vision: {os.path.basename(clip_vision_file)}")
            print(f"[Inpaint] [{uid}] Ref Image  : {os.path.basename(ref_path)}")

        print(f"[Inpaint] [{uid}] Modele : {os.path.basename(inpaint_file)}")
        print(f"[Inpaint] [{uid}] Prompt : \"{prompt}\" (strength={strength})")

        # VAE externe (indispensable pour les modèles noVAE comme Realistic Vision)
        vae_file = find_vae_for_sd1x()
        if vae_file:
            cmd += ["--vae", vae_file]
            print(f"[Inpaint] [{uid}] VAE    : {os.path.basename(vae_file)}")
        else:
            print(f"[Inpaint] [{uid}] VAE    : (aucun — placez vae-ft-mse-840000-ema-pruned.safetensors dans models/VAE/)")

        # Tentatives d'exécution : GPU optimisé avec délestage VAE et streaming disque des paramètres,
        # puis CPU VAE, puis Pure CPU
        attempts = [
            ("GPU (params-backend disk + VAE CPU)", ["--params-backend", "disk", "--vae-on-cpu", "--vae-tiling"]),
            ("CPU VAE (fallback VAE)", ["--vae-on-cpu", "--vae-tiling"]),
            ("Pure CPU", ["--backend", "cpu", "--params-backend", "disk"]),
        ]
        for attempt, (mode, extra) in enumerate(attempts):
            print(f"[Inpaint] [{uid}] Tentative {attempt + 1}/{len(attempts)} — {mode}")
            result, log = _run_sd_cli(cmd + extra, work_dir, out_path, uid)
            if result:
                print(f"[Inpaint] [{uid}] OK ({mode})")
                return result
            oom = " [OOM]" if _is_vram_oom(log) else " [echec]"
            print(f"[Inpaint] [{uid}]{oom} ({mode}) → essai suivant")

        print(f"[Inpaint] [{uid}] Echec GPU+CPU — aucun fallback art (P0)")
        raise RuntimeError(f"Inpainting échoué après tentatives GPU et CPU (ou rejeté par l'oracle) — {prompt}")

    finally:
        for p in (img_path, mask_path, ref_path):
            if p:
                try: os.remove(p)
                except Exception: pass


# --- Traitement Multi-Images R3 / FIX1 ----------------------------------------

def build_heuristic_r1_precomposition(img_a: Image.Image, img_b: Image.Image,
                                      mask_img: Image.Image = None,
                                      feather_radius: int = 12) -> tuple:
    """
    Précomposition spatiale PIL R1 pour le mode legacy_heuristic_r1 :
    - Image B reste le canvas / arrière-plan final
    - Détermine la bounding box (masque utilisateur si présent, sinon boîte centrale 25%)
    - Redimensionne Image A de façon strictement homothétique (ratio préservé) pour tenir dans la zone
    - Construit un masque avec adoucissement gaussien (feathering ~12px)
    - Colle/fond Image A dans Image B
    - Garantit : zone hors masque strictement identique à B, pixels de A présents dans la boîte englobante
    Retourne (composite_image: Image.Image, inpaint_mask: Image.Image).
    """
    bw, bh = img_b.size
    canvas_b = img_b.convert("RGB")

    # 1. Détermination du masque et de la bounding box
    has_custom_mask = False
    if mask_img is not None:
        mask_l = mask_img.convert("L").resize((bw, bh), Image.Resampling.NEAREST)
        bin_mask = mask_l.point(lambda p: 255 if p > 64 else 0)
        bbox = bin_mask.getbbox()
        if bbox is not None:
            has_custom_mask = True
            inpaint_mask = bin_mask

    if not has_custom_mask:
        # Masque central historique R1 (25% des marges)
        x0, y0 = int(bw * 0.25), int(bh * 0.25)
        x1, y1 = int(bw * 0.75), int(bh * 0.75)
        bbox = (x0, y0, x1, y1)
        inpaint_mask = Image.new("L", (bw, bh), 0)
        dm = ImageDraw.Draw(inpaint_mask)
        dm.rectangle(bbox, fill=255)

    x0, y0, x1, y1 = bbox
    box_w = max(1, x1 - x0)
    box_h = max(1, y1 - y0)

    # 2. Redimensionnement homothétique d'Image A pour tenir dans la bounding box sans déformation
    aw, ah = img_a.size
    scale = min(box_w / float(aw), box_h / float(ah))
    new_aw = max(1, int(aw * scale))
    new_ah = max(1, int(ah * scale))
    resized_a = img_a.resize((new_aw, new_ah), Image.Resampling.LANCZOS)

    # 3. Positionnement centré dans la bounding box
    pos_x = x0 + (box_w - new_aw) // 2
    pos_y = y0 + (box_h - new_ah) // 2

    # 4. Extraction du canal alpha d'Image A ou création d'un masque opaque
    if resized_a.mode == "RGBA":
        a_alpha = resized_a.split()[3]
        a_rgb = resized_a.convert("RGB")
    else:
        a_alpha = Image.new("L", (new_aw, new_ah), 255)
        a_rgb = resized_a.convert("RGB")

    # 5. Empreinte pleine taille et feathering
    footprint = Image.new("L", (bw, bh), 0)
    footprint.paste(a_alpha, (pos_x, pos_y))

    # Restreindre strictement à la zone inpaint_mask
    footprint = ImageChops.darker(footprint, inpaint_mask)

    if feather_radius > 0:
        feathered_mask = footprint.filter(ImageFilter.GaussianBlur(radius=feather_radius))
        # Garantir que hors du inpaint_mask, l'alpha reste strictement 0 (identique à B)
        feathered_mask = ImageChops.darker(feathered_mask, inpaint_mask)
    else:
        feathered_mask = footprint

    # 6. Composition de A sur B
    placed_a = Image.new("RGB", (bw, bh), (0, 0, 0))
    placed_a.paste(a_rgb, (pos_x, pos_y))

    composite_img = Image.composite(placed_a, canvas_b, feathered_mask)

    return composite_img, inpaint_mask


def detect_face_yolov8(image: Image.Image, sd_cli_path: str, model_path: str, detector_path: str) -> list:
    """
    Exécute une détection faciale réelle par YOLOv8 (face_yolov8n.safetensors) via sd-cli.exe.
    Termine dès que la détection est extraite de stdout (~0.5s).
    Retourne la liste des détections : [{"object": "face", "confidence": float, "bbox": [x1, y1, x2, y2], "area": float}]
    """
    import re
    import subprocess
    import uuid

    if not os.path.isfile(sd_cli_path) or not os.path.isfile(detector_path):
        raise RuntimeError("sd-cli.exe ou face_yolov8n.safetensors introuvable pour la détection faciale.")

    uid = uuid.uuid4().hex[:8]
    tmp_in = os.path.join(SCRIPT_DIR, f"tmp_det_in_{uid}.png")
    tmp_out = os.path.join(SCRIPT_DIR, f"tmp_det_out_{uid}.png")

    try:
        # Assurer 512x512 RGB pour la détection
        img_512 = image.convert("RGB").resize((512, 512), Image.Resampling.LANCZOS)
        img_512.save(tmp_in, format="PNG")

        cmd = [
            sd_cli_path,
            "-M", "adetailer",
            "-m", model_path,
            "-i", tmp_in,
            "--ad-model", detector_path,
            "--steps", "1",
            "-o", tmp_out,
            "-t", "8",
        ]

        vae_file = find_vae_for_sd1x()
        if vae_file:
            cmd += ["--vae", vae_file]

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            cwd=os.path.dirname(sd_cli_path),
        )

        detections = []
        detected_count = None
        t_start = time.time()

        for line in proc.stdout:
            m_cnt = re.search(r"ADetailer detected (\d+) object\(s\)", line)
            if m_cnt:
                detected_count = int(m_cnt.group(1))
                if detected_count == 0:
                    try: proc.kill()
                    except Exception: pass
                    break

            m_det = re.search(
                r"ADetailer detection \d+: object=(\w+), class_id=(\d+), confidence=([0-9.]+), bbox=\[x1=([0-9.]+), y1=([0-9.]+), x2=([0-9.]+), y2=([0-9.]+)\]",
                line
            )
            if m_det:
                obj, cid, conf, x1, y1, x2, y2 = m_det.groups()
                fx1, fy1, fx2, fy2 = float(x1), float(y1), float(x2), float(y2)
                area = max(0.0, fx2 - fx1) * max(0.0, fy2 - fy1)
                detections.append({
                    "object": obj,
                    "class_id": int(cid),
                    "confidence": float(conf),
                    "bbox": [fx1, fy1, fx2, fy2],
                    "area": area,
                })
                if detected_count is not None and len(detections) >= detected_count:
                    try: proc.kill()
                    except Exception: pass
                    break

            if time.time() - t_start > 15.0:
                try: proc.kill()
                except Exception: pass
                break

        try:
            proc.wait(timeout=3)
        except Exception:
            try: proc.kill()
            except Exception: pass

        return detections

    finally:
        for p in (tmp_in, tmp_out):
            if os.path.exists(p):
                try: os.remove(p)
                except Exception: pass



def rgb_to_lab(rgb_arr):
    """Conversion approximative rapide RGB vers LAB en numpy."""
    rgb = rgb_arr.astype(np.float32) / 255.0
    mask = rgb > 0.04045
    rgb[mask] = np.power((rgb[mask] + 0.055) / 1.055, 2.4)
    rgb[~mask] = rgb[~mask] / 12.92

    matrix = np.array([
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041]
    ], dtype=np.float32)
    xyz = np.dot(rgb, matrix.T)

    xyz[:, :, 0] /= 0.95047
    xyz[:, :, 1] /= 1.00000
    xyz[:, :, 2] /= 1.08883

    delta = 6.0 / 29.0
    m = xyz > delta**3
    f_xyz = np.zeros_like(xyz)
    f_xyz[m] = np.power(xyz[m], 1.0 / 3.0)
    f_xyz[~m] = (xyz[~m] / (3 * delta**2)) + (4.0 / 29.0)

    L = (116.0 * f_xyz[:, :, 1]) - 16.0
    A = 500.0 * (f_xyz[:, :, 0] - f_xyz[:, :, 1])
    B = 200.0 * (f_xyz[:, :, 1] - f_xyz[:, :, 2])
    return np.stack([L, A, B], axis=-1)


def lab_to_rgb(lab_arr):
    """Conversion LAB vers RGB uint8."""
    L, A, B = lab_arr[:, :, 0], lab_arr[:, :, 1], lab_arr[:, :, 2]
    fy = (L + 16.0) / 116.0
    fx = fy + (A / 500.0)
    fz = fy - (B / 200.0)

    delta = 6.0 / 29.0
    x = np.where(fx > delta, fx**3, 3 * delta**2 * (fx - 4.0 / 29.0)) * 0.95047
    y = np.where(fy > delta, fy**3, 3 * delta**2 * (fy - 4.0 / 29.0)) * 1.00000
    z = np.where(fz > delta, fz**3, 3 * delta**2 * (fz - 4.0 / 29.0)) * 1.08883

    xyz = np.stack([x, y, z], axis=-1)
    inv_matrix = np.array([
        [ 3.2404542, -1.5371385, -0.4985314],
        [-0.9692660,  1.8760108,  0.0415560],
        [ 0.0556434, -0.2040259,  1.0572252]
    ], dtype=np.float32)
    rgb_lin = np.dot(xyz, inv_matrix.T)

    mask = rgb_lin > 0.0031308
    rgb = np.zeros_like(rgb_lin)
    rgb[mask] = 1.055 * np.power(np.maximum(rgb_lin[mask], 1e-8), 1.0 / 2.4) - 0.055
    rgb[~mask] = 12.92 * rgb_lin[~mask]

    rgb = np.clip(rgb * 255.0, 0, 255).astype(np.uint8)
    return rgb


def transfer_color_reinhard(source_crop_rgb: np.ndarray, target_crop_rgb: np.ndarray) -> np.ndarray:
    """Transfert statistique de distribution de couleur (Reinhard) de la cible vers la source."""
    src_lab = rgb_to_lab(source_crop_rgb)
    tgt_lab = rgb_to_lab(target_crop_rgb)

    matched_lab = np.zeros_like(src_lab)
    for c in range(3):
        src_c = src_lab[:, :, c]
        tgt_c = tgt_lab[:, :, c]
        s_mean, s_std = float(np.mean(src_c)), float(np.std(src_c))
        t_mean, t_std = float(np.mean(tgt_c)), float(np.std(tgt_c))

        if s_std < 1e-5:
            matched_lab[:, :, c] = src_c + (t_mean - s_mean)
        else:
            scale = np.clip(t_std / s_std, 0.5, 1.8)
            matched_lab[:, :, c] = (src_c - s_mean) * scale + t_mean

    return lab_to_rgb(matched_lab)


def score_face_landmarks(pts: np.ndarray) -> float:
    """
    Évalue la cohérence biométrique et anatomique d'un jeu de 478 repères faciaux.
    Pénalise sévèrement les faux positifs (ex: confusion cou/menton, bouche/yeux).
    """
    eye_mid = (pts[33] + pts[263]) / 2.0
    eye_vec = pts[263] - pts[33]
    iod = np.linalg.norm(eye_vec)
    if iod < 10:
        return -1000.0
    ux = eye_vec / iod
    uy = np.array([-ux[1], ux[0]])  # Axe vertical descendant du visage

    y_forehead = np.dot(pts[10] - eye_mid, uy)
    y_nose = np.dot(pts[1] - eye_mid, uy)
    y_mouth = np.dot(pts[0] - eye_mid, uy)
    y_chin = np.dot(pts[152] - eye_mid, uy)

    score = 0.0
    # Le front doit être au-dessus des yeux
    if y_forehead < -0.3 * iod:
        score += 10.0
    else:
        score -= 50.0

    # Le nez doit être sous les yeux
    if 0.2 * iod < y_nose < 0.8 * iod:
        score += 10.0
    else:
        score -= 30.0

    # La bouche doit être sous le nez
    if y_nose + 0.1 * iod < y_mouth < 1.3 * iod:
        score += 10.0
    else:
        score -= 30.0

    # Le menton doit être sous la bouche
    if y_chin > y_mouth + 0.1 * iod:
        score += 10.0
    else:
        score -= 50.0

    # Ratio hauteur / largeur faciale (1.05 à 1.45 pour une tête humaine normale)
    fh = np.linalg.norm(pts[10] - pts[152])
    fw = np.linalg.norm(pts[234] - pts[454])
    ratio = fh / (fw + 1e-4)
    if 1.05 <= ratio <= 1.45:
        score += 20.0
    else:
        score -= abs(ratio - 1.25) * 50.0

    return score


def detect_face_landmarks_robust(img_pil: Image.Image, landmarker) -> np.ndarray:
    """
    Détection multi-échelle robuste des repères faciaux MediaPipe.
    Garantit une détection exacte même sur des images haute résolution plein corps
    ou des cadrages serrés, en éliminant les faux positifs sur le cou ou les vêtements.
    """
    w, h = img_pil.size
    candidates = []

    # 1. Image complète
    regions = [(0, 0, w, h)]

    # 2. Découpes anatomiques prioritaires pour grands formats / personnages verticaux
    if h >= 600:
        regions.append((0, 0, w, int(h * 0.55)))
        regions.append((0, 0, w, int(h * 0.40)))
        regions.append((0, int(h * 0.15), w, int(h * 0.70)))
    if w >= 800 and h >= 600:
        regions.append((0, 0, int(w * 0.70), int(h * 0.60)))
        regions.append((int(w * 0.30), 0, w, int(h * 0.60)))

    for x1, y1, x2, y2 in regions:
        sub_img = img_pil.crop((x1, y1, x2, y2))
        sw, sh = sub_img.size
        mp_sub = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.array(sub_img))
        res = landmarker.detect(mp_sub)
        if res.face_landmarks:
            pts_sub = np.array([[l.x * sw + x1, l.y * sh + y1] for l in res.face_landmarks[0]], dtype=np.float32)
            score = score_face_landmarks(pts_sub)
            candidates.append((score, pts_sub))

    if not candidates:
        return None
    candidates.sort(key=lambda c: c[0], reverse=True)
    return candidates[0][1]


def get_feature_protection_mask(im_fs, pts_b, hb, wb):
    """
    Construit un masque de protection des traits faciaux sensibles de B
    (yeux, sourcils, lèvres, narines, cheveux) pour éviter tout lissage non désiré.
    """
    left_eye_indices = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246, 468, 469, 470, 471, 472]
    right_eye_indices = [362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398, 473, 474, 475, 476, 477]
    eye_mask = np.zeros((hb, wb), dtype=np.uint8)
    cv2.fillConvexPoly(eye_mask, cv2.convexHull(pts_b[left_eye_indices]), 255)
    cv2.fillConvexPoly(eye_mask, cv2.convexHull(pts_b[right_eye_indices]), 255)
    eye_mask = cv2.dilate(eye_mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)))

    brow_mask = np.zeros((hb, wb), dtype=np.uint8)
    left_brow_indices = [70, 63, 105, 66, 107, 55, 65, 52, 53, 46]
    right_brow_indices = [336, 296, 334, 293, 300, 276, 283, 282, 295, 285]
    cv2.fillConvexPoly(brow_mask, cv2.convexHull(pts_b[left_brow_indices]), 255)
    cv2.fillConvexPoly(brow_mask, cv2.convexHull(pts_b[right_brow_indices]), 255)
    brow_mask = cv2.dilate(brow_mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))

    lip_indices = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 308, 324, 318, 402, 317, 14, 87, 178, 88, 95]
    lip_mask = np.zeros((hb, wb), dtype=np.uint8)
    cv2.fillConvexPoly(lip_mask, cv2.convexHull(pts_b[lip_indices]), 255)
    lip_mask = cv2.dilate(lip_mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))

    nostril_indices = [2, 98, 327, 49, 279, 19, 1]
    nostril_mask = np.zeros((hb, wb), dtype=np.uint8)
    cv2.fillConvexPoly(nostril_mask, cv2.convexHull(pts_b[nostril_indices]), 255)
    nostril_mask = cv2.dilate(nostril_mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))

    gray_fs = cv2.cvtColor(im_fs, cv2.COLOR_BGR2GRAY)
    hair_mask = np.zeros((hb, wb), dtype=np.uint8)
    y_min, y_max = pts_b[:, 1].min(), pts_b[:, 1].max()
    x_min, x_max = pts_b[:, 0].min(), pts_b[:, 0].max()
    hair_region = gray_fs[y_min:int(y_min + (y_max - y_min) * 0.4), x_min:x_max]
    if hair_region.size > 0:
        hair_mask[y_min:int(y_min + (y_max - y_min) * 0.4), x_min:x_max] = (hair_region < 78).astype(np.uint8) * 255
        hair_mask = cv2.dilate(hair_mask, cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3)))

    protected_all = cv2.bitwise_or(eye_mask, cv2.bitwise_or(brow_mask, cv2.bitwise_or(lip_mask, cv2.bitwise_or(nostril_mask, hair_mask))))
    protect_f = cv2.GaussianBlur(protected_all.astype(np.float32) / 255.0, (5, 5), 1.0)
    return protect_f


def apply_refinement_05(im_fs, im_b, mask_target, pts_b, protect_f):
    """
    Affinage 05 : Raccord de bord doux par rampe cosinus, séparation fréquentielle bilatérale
    et harmonisation chromatique CIE-LAB dans l'espace cutané.
    """
    hb, wb = im_b.shape[:2]
    dist_in = cv2.distanceTransform(mask_target, cv2.DIST_L2, 5)
    edge_alpha = np.clip(dist_in / 8.0, 0.0, 1.0)
    edge_alpha = 0.5 - 0.5 * np.cos(edge_alpha * np.pi)
    im_edge_blended = im_fs.astype(np.float32) * edge_alpha[:, :, None] + im_b.astype(np.float32) * (1.0 - edge_alpha[:, :, None])

    skin_weight = np.clip(edge_alpha * (1.0 - protect_f), 0.0, 1.0)
    base_bgr = cv2.bilateralFilter(im_edge_blended.astype(np.uint8), d=7, sigmaColor=22, sigmaSpace=12).astype(np.float32)
    detail_bgr = im_edge_blended - base_bgr

    lab_base = cv2.cvtColor(np.clip(base_bgr, 0, 255).astype(np.uint8), cv2.COLOR_BGR2LAB).astype(np.float32)
    lab_b = cv2.cvtColor(im_b, cv2.COLOR_BGR2LAB).astype(np.float32)
    mu_ambient = np.mean(lab_b[mask_target == 0].reshape(-1, 3), axis=0) if np.any(mask_target == 0) else np.array([128, 128, 128])
    if np.any(skin_weight > 0.5):
        mu_face = np.mean(lab_base[skin_weight > 0.5].reshape(-1, 3), axis=0)
        lab_harmonized = lab_base.copy()
        for c in [1, 2]:
            shift_c = (mu_ambient[c] - mu_face[c]) * 0.30
            lab_harmonized[:, :, c] += shift_c * skin_weight
        base_harmonized_bgr = cv2.cvtColor(np.clip(lab_harmonized, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR).astype(np.float32)
    else:
        base_harmonized_bgr = base_bgr.copy()

    im_skin_refined = base_harmonized_bgr + detail_bgr
    final_05 = im_edge_blended * (1.0 - skin_weight[:, :, None]) + im_skin_refined * skin_weight[:, :, None]
    final_05 = np.clip(final_05, 0, 255).astype(np.uint8)
    final_05[mask_target == 0] = im_b[mask_target == 0]
    return final_05, skin_weight


def apply_refinement_06_adaptatif(im_05, im_b, mask_target, pts_b, skin_weight):
    """
    Affinage 06 adaptatif : Analyse du grain cutané cible sous le menton de B (repère 152),
    égalisation spectrale non destructive appliquée uniquement au coeur cutané facial
    (avec marge 0-4px 100% identique à 05 pour préserver la continuité de bord),
    et garde-fou strict avec repli automatique vers 05 si delta(adapt) > delta(05).
    """
    hb, wb = im_b.shape[:2]
    chin = pts_b[152]
    face_h = pts_b[:, 1].max() - pts_b[:, 1].min()
    face_w = pts_b[:, 0].max() - pts_b[:, 0].min()
    y1_neck = min(hb - 10, chin[1] + int(0.05 * face_h))
    y2_neck = min(hb, chin[1] + int(0.35 * face_h))
    x1_neck = max(0, chin[0] - int(0.20 * face_w))
    x2_neck = min(wb, chin[0] + int(0.20 * face_w))

    neck_patch = im_b[y1_neck:y2_neck, x1_neck:x2_neck]
    if neck_patch.size > 0:
        g_neck = cv2.cvtColor(neck_patch, cv2.COLOR_BGR2GRAY).astype(np.float32)
        hp_neck = g_neck - cv2.GaussianBlur(g_neck, (3, 3), 0.8)
        std_target_skin = float(np.std(hp_neck))
    else:
        std_target_skin = 2.0

    def get_skin_noise(im):
        g = cv2.cvtColor(im, cv2.COLOR_BGR2GRAY).astype(np.float32)
        hp = g - cv2.GaussianBlur(g, (3, 3), 0.8)
        sel = skin_weight > 0.5
        return float(np.std(hp[sel])) if np.count_nonzero(sel) > 50 else 0.0

    noise_05 = get_skin_noise(im_05)
    delta_05 = abs(noise_05 - std_target_skin)

    # Core weight : 0 sur la bande périphérique de 4px, rampe douce vers 1.0 à 10px
    # Garantit une invariance absolue de la frontière par rapport à 05 !
    dist_in = cv2.distanceTransform(mask_target, cv2.DIST_L2, 5)
    core_ramp = np.clip((dist_in - 4.0) / 6.0, 0.0, 1.0)
    core_ramp = 0.5 - 0.5 * np.cos(core_ramp * np.pi)
    skin_core = skin_weight * core_ramp

    # Filtrage spectral adaptatif
    if noise_05 > std_target_skin:
        gamma = np.clip((noise_05 - std_target_skin) / (noise_05 + 1e-4), 0.0, 0.40)
        sigma_blur = 0.40 * (gamma / 0.40)
        im_filtered = cv2.GaussianBlur(im_05.astype(np.float32), (0, 0), sigma_blur)
        g_filt = cv2.cvtColor(np.clip(im_filtered, 0, 255).astype(np.uint8), cv2.COLOR_BGR2GRAY).astype(np.float32)
        hp_filt = g_filt - cv2.GaussianBlur(g_filt, (3, 3), 0.8)
        sigma_filt = float(np.std(hp_filt[skin_weight > 0.5])) if np.count_nonzero(skin_weight > 0.5) > 50 else noise_05
        s_inj = np.sqrt(max(0, std_target_skin**2 - sigma_filt**2)) if sigma_filt < std_target_skin else 0.0
    else:
        im_filtered = im_05.astype(np.float32)
        s_inj = np.sqrt(max(0, std_target_skin**2 - noise_05**2))

    np.random.seed(42)
    gb = np.random.normal(0.0, s_inj * 0.75, (hb, wb)).astype(np.float32)
    gg = np.random.normal(0.0, s_inj * 0.82, (hb, wb)).astype(np.float32)
    gr = np.random.normal(0.0, s_inj * 0.90, (hb, wb)).astype(np.float32)
    grain = np.stack([gb, gg, gr], axis=2)

    im_cand = im_filtered + grain * skin_core[:, :, None]

    lab = cv2.cvtColor(np.clip(im_cand, 0, 255).astype(np.uint8), cv2.COLOR_BGR2LAB).astype(np.float32)
    lab[:, :, 2] += 1.5 * skin_core
    im_cand_toned = cv2.cvtColor(np.clip(lab, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR).astype(np.float32)

    # Recombinaison : sur la frontière (skin_core = 0), strictement identique à im_05
    im_06_adapt = im_05.astype(np.float32) * (1.0 - skin_core[:, :, None]) + im_cand_toned * skin_core[:, :, None]
    im_06_adapt = np.clip(im_06_adapt, 0, 255).astype(np.uint8)
    im_06_adapt[mask_target == 0] = im_b[mask_target == 0]

    noise_adapt = get_skin_noise(im_06_adapt)
    delta_adapt = abs(noise_adapt - std_target_skin)

    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
    inner_border = (cv2.bitwise_and(mask_target, cv2.bitwise_not(cv2.erode(mask_target, kernel))) > 0)
    jump_05 = float(np.mean(np.abs(im_05.astype(float) - im_b.astype(float))[inner_border])) if np.any(inner_border) else 0.0
    jump_adapt = float(np.mean(np.abs(im_06_adapt.astype(float) - im_b.astype(float))[inner_border])) if np.any(inner_border) else 0.0

    # Décision du garde-fou adaptatif
    if delta_adapt <= delta_05 and jump_adapt <= jump_05 + 0.02:
        decision = "ACCEPT_06_ADAPTATIF"
    else:
        decision = "FALLBACK_TO_05"
        im_06_adapt = im_05.copy()
        noise_adapt = noise_05
        delta_adapt = delta_05
        jump_adapt = jump_05

    diag_info = {
        "target_skin_std": round(std_target_skin, 3),
        "noise_05": round(noise_05, 3),
        "delta_05": round(delta_05, 3),
        "noise_adapt": round(noise_adapt, 3),
        "delta_adapt": round(delta_adapt, 3),
        "jump_05": round(jump_05, 2),
        "jump_adapt": round(jump_adapt, 2),
        "decision": decision
    }
    return im_06_adapt, diag_info


def process_strict_face_swap(
    img_a: Image.Image,
    img_b: Image.Image,
    strength: float,
    steps: int,
    prompt: str,
    sd_cli_path: str,
    inpaint_file: str,
    detector_file: str,
    meta: dict,
) -> dict:
    """
    Exécution stricte de remplacement du visage (Face Swap R9 - Normalisation Face-Space & Invariance Cadrage).
    - Image A = Source d'identité (visage ou tête)
    - Image B = Personnage cible et scène finale (Canevas de référence invariant)
    Règle absolue : Le corps, les épaules, le buste, la posture et l'échelle générale
    de l'Image B restent 100% inchangés (zéro déformation anamorphique, zéro grossissement).
    Transformation de similarité 2D face-space (sans distorsion non-affine) calée sur
    la géométrie faciale de B (FACE_SCALE_DRIVER = B), garantissant une stricte invariance
    au cadrage de A.
    Supporte les modes "face_only" (défaut recommandé) et "full_head".
    """
    skin_strength = float(meta.get("skin_harmonization_strength", 0.60))
    t_start_strict = time.time()
    
    # Détection du mode de cadrage : "face_only" (défaut) ou "full_head"
    swap_scope = meta.get("swap_scope")
    if not swap_scope:
        p_lower = prompt.lower() if prompt else ""
        if "full_head" in p_lower or "head_swap" in p_lower or "head swap" in p_lower or "tête complète" in p_lower:
            swap_scope = "full_head"
        else:
            swap_scope = "face_only"

    # Recherche du modèle de landmarks MediaPipe
    task_model_path = find_file("face_landmarker.task")
    use_landmark_pipeline = (cv2 is not None and mp_vision is not None and task_model_path is not None)

    if use_landmark_pipeline:
        try:
            # 1. Canevas natif de B préservé sans déformation
            img_a_rgb = img_a.convert("RGB")
            img_b_rgb = img_b.convert("RGB")
            a_bgr = cv2.cvtColor(np.array(img_a_rgb), cv2.COLOR_RGB2BGR)
            b_bgr = cv2.cvtColor(np.array(img_b_rgb), cv2.COLOR_RGB2BGR)
            ha, wa = a_bgr.shape[:2]
            hb, wb = b_bgr.shape[:2]

            # 2. Détection des landmarks faciaux réels MediaPipe (R9 Multi-Scale Robust)
            base_opts = mp_python.BaseOptions(model_asset_path=task_model_path)
            opts = mp_vision.FaceLandmarkerOptions(base_options=base_opts, num_faces=1)
            with mp_vision.FaceLandmarker.create_from_options(opts) as landmarker:
                pts_a = detect_face_landmarks_robust(img_a_rgb, landmarker)
                pts_b = detect_face_landmarks_robust(img_b_rgb, landmarker)

            if pts_a is None:
                raise ValueError("NO_FACE_IN_A: Remplacement strict du visage : aucun repère facial valide détecté dans l'Image A (source identité).")
            if pts_b is None:
                raise ValueError("NO_FACE_IN_B: Remplacement strict du visage : aucun repère facial valide détecté dans l'Image B (personnage cible).")

            # 3. Définition TARGET_FACE_ROI sur B dans ses coordonnées natives
            x_min_b, y_min_b = np.min(pts_b, axis=0)
            x_max_b, y_max_b = np.max(pts_b, axis=0)
            margin_x = (x_max_b - x_min_b) * 0.25
            margin_y = (y_max_b - y_min_b) * 0.25
            target_face_roi = [
                int(max(0, x_min_b - margin_x)),
                int(max(0, y_min_b - margin_y)),
                int(min(wb, x_max_b + margin_x)),
                int(min(hb, y_max_b + margin_y)),
            ]

            # 4. Normalisation Face-Space & Transformation de Similarité A -> B (R9)
            # Échelle 100% pilotée par B (FACE_SCALE_DRIVER = B)
            # Invariance stricte au cadrage / crop de A (zéro déformation non-affine / shear)
            anchor_indices = [
                33, 133, 159, 145,       # Oeil gauche
                362, 263, 386, 374,     # Oeil droit
                1, 4, 19, 94,           # Nez
                10, 151, 9, 8,          # Front / glabelle
                152, 175, 199, 200,     # Menton / base mandibulaire
                234, 127, 162, 21,      # Joue / tempe gauche
                454, 356, 389, 251,     # Joue / tempe droite
                61, 291, 0, 17          # Lèvres et commissures
            ]

            src_anchors = pts_a[anchor_indices]
            dst_anchors = pts_b[anchor_indices]

            M_sim, _ = cv2.estimateAffinePartial2D(src_anchors, dst_anchors)
            if M_sim is None:
                M_sim, _ = cv2.estimateAffine2D(src_anchors, dst_anchors, method=cv2.LMEDS)

            pts_a_norm = cv2.transform(pts_a.reshape(-1, 1, 2), M_sim).reshape(-1, 2)
            warped_norm = cv2.warpAffine(a_bgr, M_sim, (wb, hb), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT)

            # 5. Délimitation anatomique du masque facial R10-V2 (Périmètre ordonné 36 repères)
            FACE_OVAL_ORDER = [
                10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 
                152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109
            ]

            # Masque anatomique de la cible B
            poly_b = pts_b[FACE_OVAL_ORDER].astype(np.int32)
            mask_b = np.zeros((hb, wb), dtype=np.uint8)
            cv2.fillPoly(mask_b, [poly_b], 255)

            # Masque anatomique de la source A dans l'espace normalisé de B
            poly_a = pts_a_norm[FACE_OVAL_ORDER].astype(np.int32)
            mask_a = np.zeros((hb, wb), dtype=np.uint8)
            cv2.fillPoly(mask_a, [poly_a], 255)

            # Domaine réel valide de l'image source A projetée dans le canevas de B
            # Garantit qu'aucun artefact de BORDER_REFLECT n'est échantillonné si A est un crop serré
            corners_a = np.array([[0, 0], [wa, 0], [wa, ha], [0, ha]], dtype=np.float32)
            corners_a_in_b = cv2.transform(corners_a.reshape(-1, 1, 2), M_sim).reshape(-1, 2)
            mask_valid_a = np.zeros((hb, wb), dtype=np.uint8)
            cv2.fillPoly(mask_valid_a, [corners_a_in_b.astype(np.int32)], 255)
            mask_valid_a = cv2.erode(mask_valid_a, cv2.getStructuringElement(cv2.MORPH_RECT, (7, 7)), iterations=1)

            # Intersection anatomique stricte : B inter A inter Domaine_A (invariance aux crops et bordures)
            mask_inter = cv2.bitwise_and(cv2.bitwise_and(mask_b, mask_a), mask_valid_a)

            # Érosion douce pour garantir un raccord 100% intra-cutané
            erode_k = 5 if swap_scope == "face_only" else 7
            mask_target = cv2.erode(mask_inter, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (erode_k, erode_k)), iterations=1)
            # CRUCIAL R10-V2 : Sauvegarde immuable du masque face à la mutation in-place de seamlessClone
            mask_target_clean = mask_target.copy()

            # 6. Élimination préventive des sourcils fantômes de B par inpainting intra-cutané localisé
            # Séparation stricte des coques gauche et droite (aucun pont inter-sourcils bavant sur les tempes)
            # Et restriction absolue de l'inpainting à l'intérieur de mask_target_clean (zéro triangle gris sur la tempe)
            left_brow_indices = [70, 63, 105, 66, 107, 55, 65, 52, 53, 46]
            right_brow_indices = [336, 296, 334, 293, 300, 276, 283, 282, 295, 285]
            brow_mask_b = np.zeros((hb, wb), dtype=np.uint8)
            hull_left = cv2.convexHull(pts_b[left_brow_indices].astype(np.int32))
            hull_right = cv2.convexHull(pts_b[right_brow_indices].astype(np.int32))
            cv2.fillConvexPoly(brow_mask_b, hull_left, 255)
            cv2.fillConvexPoly(brow_mask_b, hull_right, 255)
            brow_mask_b = cv2.dilate(brow_mask_b, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)), iterations=1)
            
            # Restriction stricte à l'intérieur de mask_target_clean, avec marge par rapport à la bordure
            inner_target = cv2.erode(mask_target_clean, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)), iterations=1)
            brow_mask_b = cv2.bitwise_and(brow_mask_b, inner_target)
            b_clean = cv2.inpaint(b_bgr, brow_mask_b, 5, cv2.INPAINT_TELEA) if np.any(brow_mask_b) else b_bgr.copy()

            # 7. Harmonisation colorimétrique globale en espace CIE-LAB (avec exclusion des contrastes lunettes/poils)
            gray_b = cv2.cvtColor(b_bgr, cv2.COLOR_BGR2GRAY)
            gray_w = cv2.cvtColor(warped_norm, cv2.COLOR_BGR2GRAY)
            skin_sel_b = (gray_b >= 65) & (gray_b <= 245) & (mask_target_clean > 0)
            skin_sel_a = (gray_w >= 65) & (gray_w <= 245) & (mask_target_clean > 0)
            if np.count_nonzero(skin_sel_b) < 100 or np.count_nonzero(skin_sel_a) < 100:
                skin_sel_b = mask_target_clean > 0
                skin_sel_a = mask_target_clean > 0

            b_lab = cv2.cvtColor(b_bgr[skin_sel_b].reshape(1, -1, 3), cv2.COLOR_BGR2LAB).reshape(-1, 3).astype(float)
            a_lab = cv2.cvtColor(warped_norm[skin_sel_a].reshape(1, -1, 3), cv2.COLOR_BGR2LAB).reshape(-1, 3).astype(float)

            mu_b, std_b = np.mean(b_lab, axis=0), np.std(b_lab, axis=0)
            mu_a, std_a = np.mean(a_lab, axis=0), np.std(a_lab, axis=0)

            warped_lab = cv2.cvtColor(warped_norm, cv2.COLOR_BGR2LAB).astype(float)
            harm_lab = warped_lab.copy()
            for c in range(3):
                scale_c = np.clip(std_b[c] / (std_a[c] + 1e-4), 0.70, 1.35)
                shifted_c = (warped_lab[:, :, c] - mu_a[c]) * scale_c + mu_b[c]
                harm_lab[:, :, c] = warped_lab[:, :, c] * (1.0 - skin_strength) + shifted_c * skin_strength
            harm_a_bgr = cv2.cvtColor(np.clip(harm_lab, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR)

            # 8. Incrustation par clonage sans couture de Poisson (continuité mathématique de gradient aux frontières)
            x_m, y_m, w_m, h_m = cv2.boundingRect(mask_target_clean)
            center = (int(x_m + w_m / 2), int(y_m + h_m / 2))

            try:
                # IMPORTANT R10-V2 : passer mask_target_clean.copy() car OpenCV seamlessClone altère le masque en place !
                composite_bgr = cv2.seamlessClone(harm_a_bgr, b_clean, mask_target_clean.copy(), center, cv2.NORMAL_CLONE)
            except Exception as e:
                print(f"[StrictFaceSwap] seamlessClone fallback: {e}")
                alpha_soft = cv2.GaussianBlur(mask_target_clean.astype(float) / 255.0, (21, 21), 0)
                alpha_3d = np.stack([alpha_soft] * 3, axis=-1)
                composite_bgr = (harm_a_bgr * alpha_3d + b_clean * (1.0 - alpha_3d)).astype(np.uint8)

            # 9. Post-traitement R10-V2 : Affinages photographiques 05 et 06-adaptatif
            # (Remplacement complet et définitif de l'ancien seuillage sombre heuristique)
            pts_b_int = pts_b.astype(np.int32)
            protect_f = get_feature_protection_mask(composite_bgr, pts_b_int, hb, wb)
            im_05, skin_weight = apply_refinement_05(composite_bgr, b_bgr, mask_target_clean, pts_b_int, protect_f)
            composite_bgr, diag_06 = apply_refinement_06_adaptatif(im_05, b_bgr, mask_target_clean, pts_b_int, skin_weight)
            print(f"[StrictFaceSwap] Post-traitement 06-adaptatif terminé: décision={diag_06.get('decision')} | delta_05={diag_06.get('delta_05')} -> delta_adapt={diag_06.get('delta_adapt')}")

            # Garantie absolue : aucun pixel modifié hors du masque facial anatomique
            composite_bgr[mask_target_clean == 0] = b_bgr[mask_target_clean == 0]
            composite_rgb = cv2.cvtColor(composite_bgr, cv2.COLOR_BGR2RGB)
            final_img = Image.fromarray(composite_rgb)

            # 10. R10-V2 : Pipeline déterministe temps réel sans passe neurale
            buf_out = io.BytesIO()
            final_img.save(buf_out, format="PNG")
            out_b64 = base64.b64encode(buf_out.getvalue()).decode("utf-8")

            total_strict_ms = (time.time() - t_start_strict) * 1000.0
            print("[StrictFaceSwap] R10-V2 Seamless Poisson Blending + 06-adaptatif complete")
            print(f"[StrictFaceSwap] Scale driver: B, target_face_roi={target_face_roi}")
            print("[StrictFaceSwap] Neural inpaint skipped by design")
            print(f"[StrictFaceSwap] total_ms={total_strict_ms:.2f}")

            # Bounding box pour reporting
            x_min_a, y_min_a = np.min(pts_a, axis=0)
            x_max_a, y_max_a = np.max(pts_a, axis=0)

            return {
                "images": [out_b64],
                "pipeline_type": meta.get("pipeline_type", "strict_face_swap"),
                "inpaint_model_used": f"Aucun (R10-V2 Poisson + 06-adaptatif: {diag_06.get('decision')})",
                "refinement_diag": diag_06,
                "ip_adapter_used": None,
                "detector_used": "face_landmarker.task (MediaPipe R10 Multi-Scale Robust)",
                "face_bbox": [round(float(v), 1) for v in [x_min_b, y_min_b, x_max_b, y_max_b]],
                "face_a_bbox": [round(float(v), 1) for v in [x_min_a, y_min_a, x_max_a, y_max_a]],
                "target_face_roi": target_face_roi,
                "face_scale_driver": "B",
                "transform_matrix": [[round(float(v), 6) for v in row] for row in M_sim],
                "capability_detail": meta.get("capability_detail", "R10-V2 Strict Face Swap (Poisson + 06-adaptatif)"),
                "skin_harmonization_strength": skin_strength,
                "swap_scope": swap_scope,
                "info": f"Remplacement strict R10-V2 : Masque anatomique périmétrique sur B ({swap_scope}) + Clonage Poisson sans couture + Harmonisation CIE-LAB (Pipeline déterministe temps réel sans diffusion)",
            }

        except Exception as e:
            print(f"[StrictFaceSwap R7] Avertissement MediaPipe ({e}), bascule vers pipeline géométrique standard...")
            if "NO_FACE" in str(e):
                raise

    # Fallback standard YOLOv8 (au cas où MediaPipe ou OpenCV ne sont pas disponibles)
    img_a_512 = img_a.convert("RGB").resize((512, 512), Image.Resampling.LANCZOS)
    img_b_512 = img_b.convert("RGB").resize((512, 512), Image.Resampling.LANCZOS)

    dets_a = detect_face_yolov8(img_a_512, sd_cli_path, inpaint_file, detector_file)
    if not dets_a:
        raise ValueError("NO_FACE_IN_A: Remplacement strict du visage : aucun visage détecté dans l'Image A (source identité).")
    face_a = max(dets_a, key=lambda d: d["area"])
    bbox_a = face_a["bbox"]

    dets_b = detect_face_yolov8(img_b_512, sd_cli_path, inpaint_file, detector_file)
    if not dets_b:
        raise ValueError("NO_FACE_IN_B: Remplacement strict du visage : aucun visage détecté dans l'Image B (personnage cible).")
    face_b = max(dets_b, key=lambda d: d["area"])
    bbox_b = face_b["bbox"]

    ax1, ay1, ax2, ay2 = bbox_a
    aw, ah = ax2 - ax1, ay2 - ay1
    crop_a = img_a_512.crop((max(0, int(ax1 - aw * 0.12)), max(0, int(ay1 - ah * 0.12)),
                             min(512, int(ax2 + aw * 0.12)), min(512, int(ay2 + ah * 0.12))))

    bx1, by1, bx2, by2 = bbox_b
    bw, bh = bx2 - bx1, by2 - by1
    cb_x1 = max(0, int(bx1 - bw * 0.12))
    cb_y1 = max(0, int(by1 - bh * 0.12))
    cb_x2 = min(512, int(bx2 + bw * 0.12))
    cb_y2 = min(512, int(by2 + bh * 0.12))
    tw = max(16, cb_x2 - cb_x1)
    th = max(16, cb_y2 - cb_y1)

    crop_a_resized = crop_a.resize((tw, th), Image.Resampling.LANCZOS)
    crop_b = img_b_512.crop((cb_x1, cb_y1, cb_x2, cb_y2))
    matched_a_arr = transfer_color_reinhard(np.array(crop_a_resized), np.array(crop_b))
    matched_a_img = Image.fromarray(matched_a_arr)

    feather_mask = Image.new("L", (tw, th), 0)
    draw_f = ImageDraw.Draw(feather_mask)
    draw_f.ellipse([int(tw * 0.05), int(th * 0.05), int(tw * 0.95), int(th * 0.95)], fill=255)
    blur_rad = max(4, int(min(tw, th) * 0.10))
    feather_mask = feather_mask.filter(ImageFilter.GaussianBlur(radius=blur_rad))

    composite_b = img_b_512.copy()
    composite_b.paste(matched_a_img, (cb_x1, cb_y1), feather_mask)

    buf_out = io.BytesIO()
    composite_b.save(buf_out, format="PNG")
    out_b64 = base64.b64encode(buf_out.getvalue()).decode("utf-8")

    return {
        "images": [out_b64],
        "pipeline_type": meta["pipeline_type"],
        "inpaint_model_used": os.path.basename(inpaint_file),
        "ip_adapter_used": None,
        "detector_used": os.path.basename(detector_file),
        "face_bbox": [round(v, 1) for v in bbox_b],
        "face_a_bbox": [round(v, 1) for v in bbox_a],
        "capability_detail": meta["capability_detail"],
        "info": "Remplacement strict du visage (Face Swap YOLOv8 fallback) effectué avec succès",
    }


def process_multi_image(image_a_b64: str, image_b_b64: str, mask_b64: str = "",
                        mode: str = "reference_person_or_object", prompt: str = "",
                        strength: float = 0.75, steps: int = 20, model_hint: str = "") -> dict:
    """
    Restauration et exécution du contrat Multi-Images R3/FIX1 (AUD-IMG-01 / TNR-001).
    Supporte les modes : reference_person_or_object, reference_face, auto_face_detect,
    manual_mask_priority, legacy_heuristic_r1.
    """
    if not image_a_b64 or not image_b_b64:
        raise ValueError("image_a et image_b sont obligatoires pour la composition multi-images")

    try:
        raw_a = base64.b64decode(image_a_b64)
        img_a = Image.open(io.BytesIO(raw_a)).convert("RGBA")
    except Exception as e:
        raise ValueError(f"Image A invalide : {e}")

    try:
        raw_b = base64.b64decode(image_b_b64)
        img_b = Image.open(io.BytesIO(raw_b)).convert("RGBA")
    except Exception as e:
        raise ValueError(f"Image B invalide : {e}")

    # Normalisation des dimensions à 512x512 pour SD 1.5
    # Image B est la scène cible à modifier / inpainter
    # Image A est l'image source / de référence (sujet ou visage)
    img_b_norm = img_b.resize((512, 512), Image.Resampling.LANCZOS)
    img_a_norm = img_a.resize((512, 512), Image.Resampling.LANCZOS)

    buf_b = io.BytesIO()
    img_b_norm.save(buf_b, format="PNG")
    norm_b_b64 = base64.b64encode(buf_b.getvalue()).decode("utf-8")

    buf_a = io.BytesIO()
    img_a_norm.save(buf_a, format="PNG")
    norm_a_b64 = base64.b64encode(buf_a.getvalue()).decode("utf-8")

    # Préparation du masque ciblant Image B (scène cible)
    if mask_b64:
        try:
            raw_m = base64.b64decode(mask_b64)
            mask_img = Image.open(io.BytesIO(raw_m)).convert("L")
            mask_img = mask_img.resize((512, 512), Image.Resampling.NEAREST)
            buf_m = io.BytesIO()
            mask_img.save(buf_m, format="PNG")
            norm_mask_b64 = base64.b64encode(buf_m.getvalue()).decode("utf-8")
        except Exception as e:
            print(f"[Multi-Image] Erreur décodage masque ({e}), génération d'un masque par défaut")
            mask_img = Image.new("L", (512, 512), 0)
            draw = ImageDraw.Draw(mask_img)
            draw.rectangle([128, 128, 384, 384], fill=255)
            buf_m = io.BytesIO()
            mask_img.save(buf_m, format="PNG")
            norm_mask_b64 = base64.b64encode(buf_m.getvalue()).decode("utf-8")
    else:
        # Masque central par défaut sur la scène cible Image B (25% surface centrale)
        mask_img = Image.new("L", (512, 512), 0)
        draw = ImageDraw.Draw(mask_img)
        draw.rectangle([128, 128, 384, 384], fill=255)
        buf_m = io.BytesIO()
        mask_img.save(buf_m, format="PNG")
        norm_mask_b64 = base64.b64encode(buf_m.getvalue()).decode("utf-8")

    mode_metadata = {
        "reference_person_or_object": {
            "pipeline_type": "NATIVE_IP_ADAPTER",
            "ip_adapter_file": "ip-adapter-plus_sd15.safetensors",
            "clip_vision_file": "clip_vision_vit_h.safetensors",
            "detector_used": None,
            "capability_detail": "Composition par transfert de sujet IP-Adapter (pondération sémantique)",
        },
        "reference_face": {
            "pipeline_type": "NATIVE_IP_ADAPTER_FACE",
            "ip_adapter_file": "ip-adapter-plus-face_sd15.safetensors",
            "clip_vision_file": "clip_vision_vit_h.safetensors",
            "detector_used": None,
            "capability_detail": "Transfert de visage avec alignement sans correspondance biométrique stricte",
        },
        "auto_face_detect": {
            "pipeline_type": "AUTO_YOLO_IP_ADAPTER",
            "ip_adapter_file": "ip-adapter-plus-face_sd15.safetensors",
            "clip_vision_file": "clip_vision_vit_h.safetensors",
            "detector_used": "face_yolov8n.safetensors",
            "capability_detail": "Détection automatique de visage YOLOv8 + conditionnement IP-Adapter Face",
        },
        "manual_mask_priority": {
            "pipeline_type": "MANUAL_MASK_INPAINT",
            "ip_adapter_file": None,
            "clip_vision_file": None,
            "detector_used": None,
            "capability_detail": "Inpainting guidé par masque utilisateur explicite",
        },
        "legacy_heuristic_r1": {
            "pipeline_type": "FALLBACK_HEURISTIC",
            "ip_adapter_file": None,
            "clip_vision_file": None,
            "detector_used": None,
            "capability_detail": "Mode heuristique hérité (composition alpha/fusion)",
        },
        "strict_face_swap": {
            "pipeline_type": "STRICT_FACE_SWAP",
            "ip_adapter_file": None,
            "clip_vision_file": None,
            "detector_used": "face_yolov8n.safetensors",
            "capability_detail": "Remplacement strict du visage (Face Swap) avec préservation morphologique haute fidélité",
        },
    }

    meta = mode_metadata.get(mode, mode_metadata["reference_person_or_object"])

    sd_cli = find_file("sd-cli.exe")
    if not sd_cli:
        raise RuntimeError("sd-cli.exe introuvable pour la composition multi-images")

    # Résolution stricte du modèle (Interdiction substitution silencieuse)
    inpaint_file = None
    mtype = None
    if model_hint and model_hint.strip():
        inpaint_file, mtype = resolve_explicit_model(model_hint)
        if not inpaint_file:
            raise RuntimeError(f"MODEL_NOT_FOUND: Le modèle explicitement sélectionné '{model_hint}' est introuvable sur le disque. Aucune substitution silencieuse autorisée.")
    else:
        inpaint_file, mtype = pick_best_model("inpaint")

    if not inpaint_file:
        raise RuntimeError("Aucun modèle inpainting disponible pour la composition multi-images")

    # Contrôle de compatibilité d'architecture avec les adaptateurs IP-Adapter
    is_adapter_mode = mode in ("reference_person_or_object", "reference_face", "auto_face_detect")
    if is_adapter_mode and mtype in ("sdxl", "sd3", "flux", "chroma"):
        raise ValueError(
            f"INCOMPATIBLE_MODEL: Le mode '{mode}' requiert un modèle SD 1.5 pour les adaptateurs IP-Adapter. "
            f"Le modèle sélectionné '{os.path.basename(inpaint_file)}' ({mtype.upper()}) est incompatible."
        )

    detected_face_bbox = None
    detector_used_name = None

    if mode == "strict_face_swap":
        detector_file = find_conditioning_file("face_yolov8n.safetensors")
        if not detector_file:
            raise RuntimeError("DETECTOR_NOT_FOUND: Le modèle de détection 'face_yolov8n.safetensors' est introuvable sur le disque.")

        print("[Multi-Image] Remplacement strict du visage (Face Swap R8 Déterministe)...")
        return process_strict_face_swap(
            img_a=img_a.convert("RGB"),
            img_b=img_b.convert("RGB"),
            strength=strength,
            steps=steps,
            prompt=prompt,
            sd_cli_path=sd_cli,
            inpaint_file=inpaint_file,
            detector_file=detector_file,
            meta=meta,
        )

    elif mode == "auto_face_detect":
        detector_file = find_conditioning_file("face_yolov8n.safetensors")
        if not detector_file:
            raise RuntimeError("DETECTOR_NOT_FOUND: Le modèle de détection 'face_yolov8n.safetensors' est introuvable sur le disque.")

        print(f"[Multi-Image] Détection faciale YOLOv8 sur Image B avec {os.path.basename(detector_file)}...")
        detections = detect_face_yolov8(img_b_norm, sd_cli, inpaint_file, detector_file)

        if not detections:
            raise ValueError("NO_FACE_DETECTED: Visage automatique : aucun visage détecté dans l'image cible.")

        # MULTI_FACE_SELECTION_RULE: Plus grande bbox faciale détectée
        target_face = max(detections, key=lambda d: d["area"])
        bbox = target_face["bbox"]
        conf = target_face["confidence"]
        detected_face_bbox = [round(v, 1) for v in bbox]
        detector_used_name = os.path.basename(detector_file)
        print(f"[Multi-Image] Visage détecté : bbox={bbox}, conf={conf:.3f} ({len(detections)} visage(s) trouvé(s))")

        # Construction du masque automatique depuis la bbox faciale avec marge 15% et feathering
        w, h = 512, 512
        x1, y1, x2, y2 = bbox
        bw = x2 - x1
        bh = y2 - y1
        pad_x = bw * 0.15
        pad_y = bh * 0.15
        mx1 = max(0, int(x1 - pad_x))
        my1 = max(0, int(y1 - pad_y))
        mx2 = min(w, int(x2 + pad_x))
        my2 = min(h, int(y2 + pad_y))

        auto_mask_img = Image.new("L", (w, h), 0)
        draw_m = ImageDraw.Draw(auto_mask_img)
        draw_m.rectangle([mx1, my1, mx2, my2], fill=255)
        auto_mask_feathered = auto_mask_img.filter(ImageFilter.GaussianBlur(radius=8))

        buf_fm = io.BytesIO()
        auto_mask_feathered.save(buf_fm, format="PNG")
        norm_mask_b64 = base64.b64encode(buf_fm.getvalue()).decode("utf-8")

        ip_adapter_path = find_conditioning_file(meta["ip_adapter_file"]) if meta.get("ip_adapter_file") else None
        clip_vision_path = find_conditioning_file(meta["clip_vision_file"]) if meta.get("clip_vision_file") else None
        ref_b64 = norm_a_b64 if (ip_adapter_path and clip_vision_path) else None

    elif mode == "legacy_heuristic_r1":
        # Mode R1 : Précomposition spatiale PIL A+B sans adaptateur
        composite_img, final_mask_img = build_heuristic_r1_precomposition(
            img_a=img_a,
            img_b=img_b_norm,
            mask_img=mask_img,
            feather_radius=12,
        )
        buf_comp = io.BytesIO()
        composite_img.save(buf_comp, format="PNG")
        norm_b_b64 = base64.b64encode(buf_comp.getvalue()).decode("utf-8")

        buf_fm = io.BytesIO()
        final_mask_img.save(buf_fm, format="PNG")
        norm_mask_b64 = base64.b64encode(buf_fm.getvalue()).decode("utf-8")

        ip_adapter_path = None
        clip_vision_path = None
        ref_b64 = None
    else:
        ip_adapter_path = find_conditioning_file(meta["ip_adapter_file"]) if meta.get("ip_adapter_file") else None
        clip_vision_path = find_conditioning_file(meta["clip_vision_file"]) if meta.get("clip_vision_file") else None
        ref_b64 = norm_a_b64 if (ip_adapter_path and clip_vision_path) else None

    # Exécution de l'inpainting sur Image B (ou composite R1) avec conditionnement éventuel
    out_bytes = inpaint_image(
        norm_b_b64,
        norm_mask_b64,
        prompt or "high quality composition",
        strength=strength,
        steps=steps,
        model_hint=inpaint_file,
        ip_adapter_file=ip_adapter_path,
        clip_vision_file=clip_vision_path,
        ref_image_b64=ref_b64,
    )

    out_b64 = base64.b64encode(out_bytes).decode("utf-8")
    return {
        "images": [out_b64],
        "pipeline_type": meta["pipeline_type"],
        "inpaint_model_used": os.path.basename(inpaint_file),
        "ip_adapter_used": os.path.basename(ip_adapter_path) if ip_adapter_path else None,
        "detector_used": detector_used_name if mode == "auto_face_detect" else meta["detector_used"],
        "face_bbox": detected_face_bbox,
        "capability_detail": meta["capability_detail"],
        "info": f"Multi-Image {meta['pipeline_type']} généré avec succès",
    }


# --- Serveur HTTP -------------------------------------------------------------

class SdRequestHandler(BaseHTTPRequestHandler):
    def _send_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")

    def do_OPTIONS(self):
        self.send_response(200)
        self._send_cors_headers()
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self._send_cors_headers()
        refresh = "refresh=true" in self.path or "/refresh" in self.path
        # P2 — endpoint sélecteur UI : liste structurée par type (inpaint / génération)
        if self.path.startswith("/v1/models/image"):
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            mdls = get_models(force_refresh=refresh)
            resp = []
            for mtype, paths in mdls.items():
                for p in paths:
                    name = os.path.basename(p)
                    resp.append({
                        "name": name,
                        "type": mtype,
                        "is_inpainting": mtype == "inpaint",
                    })
            self.wfile.write(json.dumps(resp).encode("utf-8"))
        elif self.path == "/" or self.path == "/v1" or self.path.startswith("/v1/models"):
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            mdls = get_models(force_refresh=refresh)
            names = [os.path.basename(p) for paths in mdls.values() for p in paths]
            default_file, default_type = pick_best_model(force_refresh=refresh)
            resp = {
                "status": "ok",
                "service": "CrisperWeaver Multi-Model Neural Image Server",
                "models": names if names else ["(aucun modele trouve)"],
                "default_model": os.path.basename(default_file) if default_file else None,
                "default_type": default_type,
            }
            self.wfile.write(json.dumps(resp).encode("utf-8"))
        elif "/sdapi/v1/sd-models" in self.path:
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            mdls = get_models(force_refresh=refresh)
            resp = []
            for mtype, paths in mdls.items():
                for p in paths:
                    name = os.path.basename(p)
                    resp.append({"title": name, "model_name": name, "type": mtype})
            self.wfile.write(json.dumps(resp).encode("utf-8"))
        elif self.path.startswith("/inpaint/models"):
            # Liste des modèles inpainting disponibles (rétrocompatibilité)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            mdls = get_models(force_refresh=refresh)
            inpaint_paths = mdls.get("inpaint", [])
            resp = [os.path.basename(p) for p in inpaint_paths]
            self.wfile.write(json.dumps(resp).encode("utf-8"))
        else:
            self.end_headers()
            self.wfile.write(b"CrisperWeaver Neural Image Server Running")


    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length) if content_length > 0 else b""

        if "/interrupt" in self.path or "/cancel" in self.path:
            interrupt_active_generation()
            body = json.dumps({"status": "interrupted"}).encode("utf-8")
            self.send_response(200)
            self._send_cors_headers()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # ── Endpoint Multi-Images R3 / FIX1 ────────────────────────────────────
        if "/edit/multi-image" in self.path:
            try:
                body = json.loads(post_data.decode("utf-8"))
                img_a_b64 = body.get("image_a", "")
                img_b_b64 = body.get("image_b", "")
                mask_b64  = body.get("mask", "")
                mode      = body.get("mode", "reference_person_or_object")
                prompt    = body.get("prompt", "")
                strength  = float(body.get("strength", 0.75))
                steps     = int(body.get("steps", 20))
                model_h   = body.get("model", "")

                result = process_multi_image(img_a_b64, img_b_b64, mask_b64, mode, prompt, strength, steps, model_h)
                self.send_response(200)
                self._send_cors_headers()
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.end_headers()
                self.wfile.write(json.dumps(result, ensure_ascii=False).encode("utf-8"))
            except Exception as e:
                self.send_response(500)
                self._send_cors_headers()
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e), "status": "error"}).encode("utf-8"))
                print(f"[Multi-Image] ERREUR : {e}")
            return

        # ── Endpoint inpainting ────────────────────────────────────────────────
        if "/inpaint" in self.path:
            try:
                body = json.loads(post_data.decode("utf-8"))
                image_b64  = body.get("image", "")
                mask_b64   = body.get("mask", "")
                prompt     = body.get("prompt", "high quality photo")
                strength   = float(body.get("strength", 0.75))
                steps      = int(body.get("steps", 20))
                model_hint = body.get("model", "")
                print(f"[Inpaint] Requete : \"{prompt}\" (strength={strength}, model='{model_hint or 'auto'}')")
                raw_bytes = inpaint_image(image_b64, mask_b64, prompt, strength, steps, model_hint)
                b64_result = base64.b64encode(raw_bytes).decode("utf-8")
                self.send_response(200)
                self._send_cors_headers()
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({
                    "images": [b64_result],
                    "info": "CrisperWeaver Inpainting",
                }).encode("utf-8"))
            except Exception as e:
                self.send_response(500)
                self._send_cors_headers()
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode("utf-8"))
                print(f"[Inpaint] ERREUR : {e}")
            return

        # ── Génération normale ─────────────────────────────────────────────────
        prompt = "Artwork"
        model_name = ""
        width = 512
        height = 512
        try:
            body = json.loads(post_data.decode("utf-8"))
            prompt = body.get("prompt", "Artwork")
            model_name = body.get("model", "")
            width = int(body.get("width", 512))
            height = int(body.get("height", 512))
        except Exception:
            pass

        print(f"[Image Server] Requete recue : \"{prompt}\" (hint : '{model_name}', demande : {width}x{height})")
        try:
            raw_bytes, actual_w, actual_h, is_norm = generate_real_neural_image(prompt, model_name, width, height)
        except Exception as e:
            err_msg = str(e)
            print(f"[Image Server] ERREUR : {err_msg}")
            code = 499 if ("interrompu" in err_msg.lower() or "annulé" in err_msg.lower()) else 500
            self.send_response(code)
            self._send_cors_headers()
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": err_msg, "status": "error"}).encode("utf-8"))
            return

        b64_str = base64.b64encode(raw_bytes).decode("utf-8")

        self.send_response(200)
        self._send_cors_headers()
        self.send_header("Content-Type", "application/json")
        self.end_headers()

        if "/images/generations" in self.path:
            resp_obj = {"created": int(time.time()), "data": [{"b64_json": b64_str}], "size": f"{actual_w}x{actual_h}"}
        else:
            resp_obj = {
                "images": [b64_str],
                "parameters": {
                    "prompt": prompt,
                    "model": model_name,
                    "width": actual_w,
                    "height": actual_h,
                    "requested_width": width,
                    "requested_height": height,
                    "normalized": is_norm,
                },
                "info": "Generated by CrisperWeaver Multi-Model Neural Engine",
            }
        self.wfile.write(json.dumps(resp_obj).encode("utf-8"))
        norm_txt = f" [normalise depuis {width}x{height}]" if is_norm else ""
        print(f"[Image Server] [OK] Image transmise avec succes ! ({actual_w}x{actual_h}){norm_txt}")


def main():
    parser = argparse.ArgumentParser(description="CrisperWeaver Multi-Model Image Server")
    parser.add_argument("--port", type=int, default=7860, help="Port (default 7860)")
    args = parser.parse_args()

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), SdRequestHandler)
    print("=" * 60)
    print(f" Serveur Multi-Modeles Text-to-Image CrisperWeaver")
    print(f" Ecoute active sur : http://127.0.0.1:{args.port}")
    print("=" * 60)

    default_file, default_type = pick_best_model()
    if default_file:
        print(f" Modele par defaut : [{default_type.upper()}] {os.path.basename(default_file)}")
    else:
        print(f" ATTENTION : Aucun modele trouve.")
        print(f"  Placez un .gguf dans : {os.path.join(SCRIPT_DIR, 'models', 'Stable-diffusion')}")
    print("=" * 60)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.server_close()


if __name__ == "__main__":
    main()
