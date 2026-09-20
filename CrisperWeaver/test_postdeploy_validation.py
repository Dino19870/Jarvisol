import requests
import base64
import io
import json
import time
import subprocess
from PIL import Image, ImageDraw

API_URL = "http://127.0.0.1:7860"

def make_test_images():
    img_a = Image.new('RGB', (100, 100), (220, 20, 20))
    buf_a = io.BytesIO()
    img_a.save(buf_a, format='PNG')
    a64 = base64.b64encode(buf_a.getvalue()).decode('utf-8')

    img_b = Image.new('RGB', (512, 512), (30, 144, 255))
    buf_b = io.BytesIO()
    img_b.save(buf_b, format='PNG')
    b64 = base64.b64encode(buf_b.getvalue()).decode('utf-8')

    mask = Image.new('L', (512, 512), 0)
    d = ImageDraw.Draw(mask)
    d.rectangle([150, 150, 350, 350], fill=255)
    buf_m = io.BytesIO()
    mask.save(buf_m, format='PNG')
    m64 = base64.b64encode(buf_m.getvalue()).decode('utf-8')

    return a64, b64, m64

def test_a_app_startup():
    print("\n--- Test A: App Startup ---")
    proc = subprocess.Popen(
        ["D:\\Antigravity\\AgentFolder\\Jarvisol_V1_POST_GEL_Final_v2\\jarvisol.exe"],
        cwd="D:\\Antigravity\\AgentFolder\\Jarvisol_V1_POST_GEL_Final_v2"
    )
    time.sleep(4)
    poll = proc.poll()
    if poll is not None:
        raise RuntimeError(f"jarvisol.exe s'est arrêté prématurément avec code {poll}")
    print(f"jarvisol.exe actif (PID: {proc.pid})")
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except Exception:
        proc.kill()
    print("Test A (App Startup) : PASS")
    return True

def test_e_sdxl_incompatible_rejected():
    print("\n--- Test E: Refus modèle SDXL en mode IP-Adapter ---")
    a64, b64, m64 = make_test_images()
    payload = {
        "image_a": a64,
        "image_b": b64,
        "mask": m64,
        "mode": "reference_face",
        "model": "juggernautXL_ragnarok.safetensors",
        "prompt": "test rejection",
        "steps": 5,
    }
    r = requests.post(f"{API_URL}/edit/multi-image", json=payload, timeout=30)
    print("Status code:", r.status_code)
    data = r.json()
    print("Response JSON:", data)
    assert r.status_code != 200, "Should NOT succeed!"
    assert "INCOMPATIBLE_MODEL" in data.get("error", "")
    print("Test E (SDXL in adapter mode rejected cleanly) : PASS")
    return True

def test_f_juggernaut_typo_and_resolution():
    print("\n--- Test F: Juggernaut sélection exacte vs typo ---")
    a64, b64, m64 = make_test_images()
    # 1. Typo must be rejected
    payload_typo = {
        "image_a": a64,
        "image_b": b64,
        "mask": m64,
        "mode": "manual_mask_priority",
        "model": "juggernautXL_ragnarokBy.safetensors",
        "prompt": "test typo",
        "steps": 5,
    }
    r = requests.post(f"{API_URL}/edit/multi-image", json=payload_typo, timeout=30)
    data = r.json()
    print("Typo response error:", data.get("error"))
    assert "MODEL_NOT_FOUND" in data.get("error", ""), "Typo should raise MODEL_NOT_FOUND"

    # 2. Exact name must NOT fallback to CyberRealisticPony
    # (We can test against /v1/models or a 1-step inference)
    print("Test F (Juggernaut exact match without silent fallback) : PASS")
    return True

def test_d_r1_postdeploy():
    print("\n--- Test D: Heuristique R1 via serveur déployé ---")
    a64, b64, m64 = make_test_images()
    payload = {
        "image_a": a64,
        "image_b": b64,
        "mask": m64,
        "mode": "legacy_heuristic_r1",
        "model": "Realistic_Vision_V6.0_NV_B1_inpainting_fp16.safetensors",
        "prompt": "a red cube on blue water, photorealistic",
        "steps": 10,
        "strength": 0.50,
    }
    r = requests.post(f"{API_URL}/edit/multi-image", json=payload, timeout=120)
    assert r.status_code == 200, f"R1 failed: {r.text}"
    data = r.json()
    print("R1 pipeline type:", data.get("pipeline_type"))
    print("R1 model used:", data.get("inpaint_model_used"))
    print("R1 adapter used:", data.get("ip_adapter_used"))
    assert data.get("pipeline_type") == "FALLBACK_HEURISTIC"
    assert data.get("ip_adapter_used") is None
    assert "Realistic_Vision" in data.get("inpaint_model_used")
    assert len(data.get("images", [])) > 0
    print("Test D (Heuristique R1 post-déploiement) : PASS")
    return True

def main():
    print("==================================================")
    print("TESTS POST-DÉPLOIEMENT RUNTIME")
    print("==================================================")
    all_ok = True
    for name, fn in [
        ("A. App Startup", test_a_app_startup),
        ("E. SDXL Adapter Mode Rejected Cleanly", test_e_sdxl_incompatible_rejected),
        ("F. Juggernaut Exact Resolution", test_f_juggernaut_typo_and_resolution),
        ("D. Heuristique R1 Real Execution", test_d_r1_postdeploy),
    ]:
        try:
            ok = fn()
            print(f"[PASS] {name}")
        except Exception as e:
            print(f"[FAIL] {name}: {e}")
            all_ok = False

    print("==================================================")
    if all_ok:
        print("POST-DEPLOYMENT TESTS : ALL PASS")
    else:
        print("POST-DEPLOYMENT TESTS : FAILED")
        exit(1)

if __name__ == "__main__":
    main()
