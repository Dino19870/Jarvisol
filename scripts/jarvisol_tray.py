"""
jarvisol_tray.py — Lanceur système tray pour Memory Server et SD Server
Conforme CORR-LOT-002 (Ownership strict, Mutex scoped par racine portable, zéro console parasite).
"""
import sys, os, time, threading, subprocess, socket, urllib.request, hashlib
import ctypes
from ctypes import wintypes
from PIL import Image, ImageDraw, ImageFont
import pystray
from pystray import MenuItem as item

# ── Résolution de la vraie racine portable (PyInstaller onefile compatible) ──
if getattr(sys, "frozen", False):
    SCRIPT_DIR = os.path.dirname(os.path.abspath(sys.executable))
else:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

MEM_EXE = os.path.join(SCRIPT_DIR, "memory_server.exe")
SD_EXE  = os.path.join(SCRIPT_DIR, "sd_server.exe")

procs = {"memory": None, "sd": None}
starting = {"memory": False, "sd": False}
_global_mutex_handle = None

# ── Mutex Scoped par Racine Portable ──────────────────────────────────────────
def acquire_scoped_mutex(root_dir: str):
    """
    Garantit une instance unique par racine portable tout en permettant
    à deux installations portables distinctes d'avoir chacune leur tray.
    """
    global _global_mutex_handle
    norm_root = os.path.abspath(root_dir).lower().replace("/", "\\").rstrip("\\")
    h = hashlib.sha256(norm_root.encode("utf-8")).hexdigest()[:16]
    mutex_name = f"JarvisolTray_{h}"

    kernel32 = ctypes.windll.kernel32
    CreateMutexW = kernel32.CreateMutexW
    CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
    CreateMutexW.restype = wintypes.HANDLE
    GetLastError = kernel32.GetLastError
    GetLastError.restype = wintypes.DWORD

    ERROR_ALREADY_EXISTS = 183
    handle = CreateMutexW(None, True, mutex_name)
    if GetLastError() == ERROR_ALREADY_EXISTS:
        if handle:
            kernel32.CloseHandle(handle)
        return False, mutex_name
    _global_mutex_handle = handle
    return True, mutex_name

# ── Détection d'état réseau et santé ───────────────────────────────────────────
def is_port_in_use(port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.3)
    try:
        s.connect(("127.0.0.1", port))
        s.close()
        return True
    except:
        return False

def is_url_healthy(url: str, keyword: str = "") -> bool:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "JarvisolTray/1.0"})
        with urllib.request.urlopen(req, timeout=0.8) as resp:
            if resp.status == 200:
                if keyword:
                    body = resp.read().decode("utf-8", errors="ignore")
                    return keyword in body
                return True
    except:
        pass
    return False

def get_server_state(key: str) -> str:
    """
    Retourne l'état technique réel :
    STOPPED | STARTING | RUNNING_OWNED | RUNNING_EXTERNAL | CONFLICT_UNHEALTHY
    """
    p = procs.get(key)
    p_alive = (p is not None and p.poll() is None)

    if key == "memory":
        port = 7862
        url = "http://127.0.0.1:7862/health"
        is_healthy = is_url_healthy(url, "Memory Server") or is_url_healthy("http://127.0.0.1:7862/memory/stats")
    else:
        port = 7860
        url = "http://127.0.0.1:7860/"
        is_healthy = is_url_healthy(url, "Neural Image Server") or is_url_healthy("http://127.0.0.1:7860/v1")

    if is_healthy:
        if p_alive:
            starting[key] = False
            return "RUNNING_OWNED"
        else:
            return "RUNNING_EXTERNAL"
    else:
        if is_port_in_use(port):
            return "CONFLICT_UNHEALTHY"
        if starting.get(key, False):
            if p_alive:
                return "STARTING"
            else:
                starting[key] = False
                procs[key] = None
                return "STOPPED"
        return "STOPPED"

# ── Icône tray dynamique ──────────────────────────────────────────────────────
def make_icon(color=(180,20,20)):
    sz = 64
    img = Image.new("RGBA", (sz,sz), (0,0,0,0))
    d   = ImageDraw.Draw(img)
    d.ellipse([2,2,sz-3,sz-3], fill=color)
    d.ellipse([4,4,sz-5,sz-5], fill=tuple(min(255,c+20) for c in color))
    ring = max(1, sz//16)
    d.ellipse([ring,ring,sz-ring-1,sz-ring-1], outline=(220,165,0,255), width=max(1,sz//20))
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 28)
    except:
        font = ImageFont.load_default()
    bbox = d.textbbox((0,0), "J", font=font)
    tw, th = bbox[2]-bbox[0], bbox[3]-bbox[1]
    x = (sz-tw)//2 - bbox[0]
    y = (sz-th)//2 - bbox[1]
    d.text((x+2,y+2), "J", font=font, fill=(100,50,0,180))
    d.text((x,y), "J", font=font, fill=(255,200,0,255))
    return img

def status_icon():
    mem_st = get_server_state("memory")
    sd_st  = get_server_state("sd")
    mem_up = mem_st in ("RUNNING_OWNED", "RUNNING_EXTERNAL")
    sd_up  = sd_st in ("RUNNING_OWNED", "RUNNING_EXTERNAL")

    if mem_up and sd_up:
        return make_icon((30,140,30))
    if mem_up or sd_up or mem_st == "STARTING" or sd_st == "STARTING":
        return make_icon((200,120,0))
    return make_icon((180,20,20))

# ── Lancement et Arrêt Sécurisés (Ownership Fail-Closed) ───────────────────────
def start_server(key: str, exe_path: str):
    st = get_server_state(key)
    if st in ("RUNNING_OWNED", "RUNNING_EXTERNAL"):
        return
    if st == "CONFLICT_UNHEALTHY":
        return
    if not os.path.exists(exe_path):
        return

    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 0  # SW_HIDE
    CREATE_NO_WINDOW = 0x08000000

    env = os.environ.copy()
    env["PATH"] = os.path.join(SCRIPT_DIR, "sd_vulkan") + os.pathsep + env.get("PATH","")

    try:
        proc = subprocess.Popen([exe_path], startupinfo=si, env=env,
                                creationflags=CREATE_NO_WINDOW,
                                close_fds=True)
        procs[key] = proc
        starting[key] = True

        def poll_readiness():
            for _ in range(20):
                time.sleep(0.5)
                if get_server_state(key) == "RUNNING_OWNED":
                    starting[key] = False
                    return
            starting[key] = False
        threading.Thread(target=poll_readiness, daemon=True).start()
    except Exception as e:
        procs[key] = None
        starting[key] = False

def stop_server(key: str):
    st = get_server_state(key)
    p = procs.get(key)
    if st == "RUNNING_OWNED" and p is not None:
        target_pid = p.pid
        try:
            subprocess.run(["taskkill", "/PID", str(target_pid), "/T", "/F"],
                           capture_output=True, timeout=5)
        except:
            try: p.terminate()
            except: pass
        procs[key] = None
        starting[key] = False
    elif st == "RUNNING_EXTERNAL":
        pass
    else:
        procs[key] = None
        starting[key] = False

# ── Callbacks menu ───────────────────────────────────────────────────────────
def on_start_memory(icon, item):
    start_server("memory", MEM_EXE)
    icon.icon = status_icon()

def on_stop_memory(icon, item):
    stop_server("memory")
    icon.icon = status_icon()

def on_start_sd(icon, item):
    start_server("sd", SD_EXE)
    icon.icon = status_icon()

def on_stop_sd(icon, item):
    stop_server("sd")
    icon.icon = status_icon()

def on_quit(icon, item):
    if get_server_state("memory") == "RUNNING_OWNED":
        stop_server("memory")
    if get_server_state("sd") == "RUNNING_OWNED":
        stop_server("sd")
    icon.stop()

# ── Libellés dynamiques ───────────────────────────────────────────────────────
def get_mem_title(_=None):
    st = get_server_state("memory")
    if st == "RUNNING_OWNED":
        return f"Memory Server:  ✅ Détenu (PID {procs['memory'].pid})"
    if st == "RUNNING_EXTERNAL":
        return "Memory Server:  🌐 Externe (Non géré)"
    if st == "CONFLICT_UNHEALTHY":
        return "Memory Server:  ⚠️ Conflit (Port 7862 occupé)"
    if st == "STARTING":
        return "Memory Server:  ⏳ Démarrage..."
    return "Memory Server:  ❌ Arrêté"

def get_sd_title(_=None):
    st = get_server_state("sd")
    if st == "RUNNING_OWNED":
        return f"SD Server:      ✅ Détenu (PID {procs['sd'].pid})"
    if st == "RUNNING_EXTERNAL":
        return "SD Server:      🌐 Externe (Non géré)"
    if st == "CONFLICT_UNHEALTHY":
        return "SD Server:      ⚠️ Conflit (Port 7860 occupé)"
    if st == "STARTING":
        return "SD Server:      ⏳ Démarrage..."
    return "SD Server:      ❌ Arrêté"

# ── Mise à jour périodique ───────────────────────────────────────────────────
def updater(icon):
    while True:
        time.sleep(3)
        try:
            icon.icon  = status_icon()
            icon.title = (
                f"Jarvisol Servers\n"
                f"{get_mem_title()}\n"
                f"{get_sd_title()}"
            )
        except Exception:
            break

# ── Point d'Entrée Principal ─────────────────────────────────────────────────
def main():
    ok, mutex_name = acquire_scoped_mutex(SCRIPT_DIR)
    if not ok:
        # Sortie immédiate sans message bloquant
        os._exit(0)

    start_server("memory", MEM_EXE)
    start_server("sd",     SD_EXE)

    icon = pystray.Icon(
        name="jarvisol",
        icon=status_icon(),
        title="Jarvisol Servers",
        menu=pystray.Menu(
            item(get_mem_title, lambda icon, _: None, enabled=False),
            item("  ▶ Démarrer Memory", on_start_memory, enabled=lambda _: get_server_state("memory") == "STOPPED"),
            item("  ■ Arrêter Memory",  on_stop_memory,  enabled=lambda _: get_server_state("memory") == "RUNNING_OWNED"),
            pystray.Menu.SEPARATOR,
            item(get_sd_title,  lambda icon, _: None, enabled=False),
            item("  ▶ Démarrer SD",     on_start_sd,     enabled=lambda _: get_server_state("sd") == "STOPPED"),
            item("  ■ Arrêter SD",      on_stop_sd,      enabled=lambda _: get_server_state("sd") == "RUNNING_OWNED"),
            pystray.Menu.SEPARATOR,
            item("❌ Quitter les serveurs", on_quit),
        )
    )
    threading.Thread(target=updater, args=(icon,), daemon=True).start()
    icon.run()

if __name__ == "__main__":
    main()
