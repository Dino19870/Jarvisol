"""
CrisperWeaver Memory Server — Mémoire persistante inter-sessions + Projets actifs
==================================================================================
Port : 7862
Stockage : memory/memory_store.json  (faits & sessions)
           memory/projects_store.json (projets actifs)

Endpoints mémoire
-----------------
GET  /health
GET  /memory/recall?q=<query>&n=5
GET  /memory/facts | /memory/sessions | /memory/stats
POST /memory/save | /memory/extract | /memory/forget
DELETE /memory/clear

Endpoints projets
-----------------
GET  /projects              -> liste tous les projets
GET  /projects/context      -> contexte formaté pour injection dans system prompt
POST /projects/save         -> créer ou mettre à jour un projet  {id?, name, status, description, tech_stack, notes, path}
POST /projects/delete       -> supprimer un projet               {id}
"""

import argparse
import json
import os
import re
import sys
import time
import uuid
import urllib.request
import urllib.error
import shutil
import threading
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# ── Répertoire de base (PyInstaller --onefile compatible) ──────────────────────
if getattr(sys, "frozen", False):
    SCRIPT_DIR = os.path.dirname(os.path.abspath(sys.executable))
else:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

MEMORY_DIR     = os.path.join(SCRIPT_DIR, "memory")
MEMORY_FILE    = os.path.join(MEMORY_DIR, "memory_store.json")
PROJECTS_FILE  = os.path.join(MEMORY_DIR, "projects_store.json")
FILES_FILE     = os.path.join(MEMORY_DIR, "files_store.json")
MCP_FILE       = os.path.join(MEMORY_DIR, "mcp_store.json")

_STORE_LOCK = threading.RLock()


def _quarantine_corrupted_file(file_path: str):
    """Met en quarantaine un fichier corrompu pour empêcher la destruction silencieuse de données récupérables."""
    if os.path.exists(file_path):
        ts = int(time.time())
        q_path = f"{file_path}.bak_corrupt_{ts}"
        try:
            shutil.copy2(file_path, q_path)
            print(f"[Memory] FICHIER CORROMPU ISOLÉ EN QUARANTAINE : {q_path}")
        except Exception as e:
            print(f"[Memory] Erreur mise en quarantaine {file_path} : {e}")


def _atomic_json_save(file_path: str, data) -> None:
    """Sauvegarde atomique via fichier temporaire (.tmp) et renommage pour éviter toute troncature 0-octet."""
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    tmp_path = f"{file_path}.tmp_{uuid.uuid4().hex[:8]}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, file_path)


# ── Gestion bibliothèque MCP personnalisés ────────────────────────────────────

def load_mcps() -> list:
    with _STORE_LOCK:
        os.makedirs(MEMORY_DIR, exist_ok=True)
        if os.path.exists(MCP_FILE):
            try:
                with open(MCP_FILE, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                print(f"[Memory/MCP] Erreur lecture : {e}")
                _quarantine_corrupted_file(MCP_FILE)
        return []


def save_mcps(mcps: list) -> None:
    with _STORE_LOCK:
        _atomic_json_save(MCP_FILE, mcps)


def upsert_mcp(data: dict) -> dict:
    """Crée ou met à jour un MCP custom. Retourne l'entrée sauvegardée."""
    mcps = load_mcps()
    mcp_id = data.get("id", "").strip()
    now = datetime.now().isoformat()
    entry = {
        "id":               mcp_id or uuid.uuid4().hex[:12],
        "name":             data.get("name", "").strip(),
        "icon":             data.get("icon", "🔧").strip(),
        "type":             data.get("type", "prompt").strip(),    # prompt | http | script
        "trigger":          data.get("trigger", "always").strip(), # always | keyword | manual
        "keywords":         data.get("keywords", []),
        "enabled":          bool(data.get("enabled", True)),
        "source":           data.get("source", "user").strip(),    # user | imported
        # type=prompt
        "system_injection": data.get("system_injection", "").strip(),
        # type=http
        "endpoint":         data.get("endpoint", "").strip(),
        "method":           data.get("method", "POST").strip(),
        "body_template":    data.get("body_template", "").strip(),
        "response_path":    data.get("response_path", "").strip(),
        # type=script
        "script_path":      data.get("script_path", "").strip(),
        "args_template":    data.get("args_template", []),
        "created":          now,
        "updated":          now,
    }
    if mcp_id:
        for i, m in enumerate(mcps):
            if m.get("id") == mcp_id:
                entry["created"] = m.get("created", now)
                mcps[i] = entry
                save_mcps(mcps)
                print(f"[Memory/MCP] Mis a jour : {entry['name']}")
                return entry
    mcps.append(entry)
    save_mcps(mcps)
    print(f"[Memory/MCP] Nouveau MCP : {entry['name']} (type={entry['type']})")
    return entry


def delete_mcp(mcp_id: str) -> bool:
    mcps = load_mcps()
    before = len(mcps)
    mcps = [m for m in mcps if m.get("id") != mcp_id]
    if len(mcps) < before:
        save_mcps(mcps)
        return True
    return False


def toggle_mcp(mcp_id: str, enabled: bool) -> bool:
    mcps = load_mcps()
    for m in mcps:
        if m.get("id") == mcp_id:
            m["enabled"] = enabled
            m["updated"] = datetime.now().isoformat()
            save_mcps(mcps)
            return True
    return False


def mcp_prompts_context() -> str:
    """Retourne le contexte des MCPs type=prompt actifs, pour injection dans le system prompt."""
    mcps = load_mcps()
    enabled_prompts = [
        m for m in mcps
        if m.get("enabled") and m.get("type") == "prompt" and m.get("system_injection", "").strip()
    ]
    if not enabled_prompts:
        return ""
    parts = []
    for m in enabled_prompts:
        icon = m.get("icon", "🔧")
        name = m.get("name", "MCP")
        injection = m.get("system_injection", "").strip()
        parts.append(f"### {icon} {name}\n{injection}")
    return "## 🔧 OUTILS MCP PERSONNALISÉS (contexte actif)\n\n" + "\n\n".join(parts)


# ── Gestion des fichiers & chemins importants ──────────────────────────────────

_TYPE_ICONS = {"file": "📄", "directory": "📁", "url": "🌐", "other": "📌"}


def load_files() -> list:
    """Charge la liste des fichiers importants depuis files_store.json."""
    with _STORE_LOCK:
        os.makedirs(MEMORY_DIR, exist_ok=True)
        if os.path.exists(FILES_FILE):
            try:
                with open(FILES_FILE, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                print(f"[Memory/Files] Erreur lecture : {e}")
                _quarantine_corrupted_file(FILES_FILE)
        return []


def save_files(files: list) -> None:
    with _STORE_LOCK:
        _atomic_json_save(FILES_FILE, files)


def upsert_file(data: dict) -> dict:
    """Crée ou met à jour une entrée de fichier. Retourne l'entrée sauvegardée."""
    files = load_files()
    file_id = data.get("id", "").strip()
    now = datetime.now().isoformat()

    entry = {
        "id":          file_id or uuid.uuid4().hex[:12],
        "label":       data.get("label", "").strip(),
        "path":        data.get("path", "").strip(),
        "description": data.get("description", "").strip(),
        "project":     data.get("project", "").strip(),   # nom du projet associé (optionnel)
        "type":        data.get("type", "file").strip(),   # file | directory | url | other
        "created":     now,
        "updated":     now,
    }

    if file_id:
        for i, f in enumerate(files):
            if f.get("id") == file_id:
                entry["created"] = f.get("created", now)
                files[i] = entry
                save_files(files)
                print(f"[Memory/Files] Mis a jour : {entry['label']}")
                return entry

    files.append(entry)
    save_files(files)
    print(f"[Memory/Files] Nouveau fichier : {entry['label']} → {entry['path']}")
    return entry


def delete_file_entry(file_id: str) -> bool:
    files = load_files()
    before = len(files)
    files = [f for f in files if f.get("id") != file_id]
    if len(files) < before:
        save_files(files)
        return True
    return False


def files_context_string() -> str:
    """
    Retourne les fichiers importants formatés en liste compacte pour injection
    dans le system prompt. Groupés par projet si disponible.
    """
    files = load_files()
    if not files:
        return ""

    lines = [
        "## 📁 FICHIERS & CHEMINS IMPORTANTS",
        "Utilise ces chemins directement dans tes réponses sans demander à l'utilisateur.\n",
    ]

    # Grouper par projet
    by_project: dict = {}
    for f in files:
        proj = f.get("project", "") or "Général"
        by_project.setdefault(proj, []).append(f)

    for proj, entries in sorted(by_project.items()):
        if len(by_project) > 1:
            lines.append(f"**{proj}**")
        for e in entries:
            icon = _TYPE_ICONS.get(e.get("type", "file"), "📌")
            label = e.get("label", "")
            path  = e.get("path", "")
            desc  = e.get("description", "")
            line  = f"  {icon} [{label}] {path}"
            if desc:
                line += f" — {desc}"
            lines.append(line)
        lines.append("")

    return "\n".join(lines).strip()


# ── Gestion des projets actifs ─────────────────────────────────────────────────

_STATUS_LABELS = {"actif": "🟢 Actif", "pause": "🟡 En pause", "termine": "⚫ Terminé"}


def load_projects() -> list:
    """Charge la liste des projets depuis projects_store.json."""
    with _STORE_LOCK:
        os.makedirs(MEMORY_DIR, exist_ok=True)
        if os.path.exists(PROJECTS_FILE):
            try:
                with open(PROJECTS_FILE, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                print(f"[Memory/Projects] Erreur lecture : {e}")
                _quarantine_corrupted_file(PROJECTS_FILE)
        return []


def save_projects(projects: list) -> None:
    with _STORE_LOCK:
        _atomic_json_save(PROJECTS_FILE, projects)


def upsert_project(data: dict) -> dict:
    """Crée ou met à jour un projet. Retourne le projet sauvegardé."""
    projects = load_projects()
    project_id = data.get("id", "").strip()

    now = datetime.now().isoformat()
    project = {
        "id":          project_id or uuid.uuid4().hex[:12],
        "name":        data.get("name", "Projet sans nom").strip(),
        "status":      data.get("status", "actif").strip(),      # actif | pause | termine
        "description": data.get("description", "").strip(),
        "tech_stack":  data.get("tech_stack", "").strip(),
        "notes":       data.get("notes", "").strip(),
        "path":        data.get("path", "").strip(),
        "created":     now,
        "updated":     now,
    }

    if project_id:
        # Mise à jour : cherche l'existant et préserve created
        for i, p in enumerate(projects):
            if p.get("id") == project_id:
                project["created"] = p.get("created", now)
                projects[i] = project
                save_projects(projects)
                print(f"[Memory/Projects] Mis a jour : {project['name']}")
                return project
    # Nouveau projet
    projects.append(project)
    save_projects(projects)
    print(f"[Memory/Projects] Nouveau projet : {project['name']}")
    return project


def delete_project(project_id: str) -> bool:
    projects = load_projects()
    before = len(projects)
    projects = [p for p in projects if p.get("id") != project_id]
    if len(projects) < before:
        save_projects(projects)
        return True
    return False


def project_context_string() -> str:
    """
    Retourne une chaîne formatée décrivant les projets actifs et en pause,
    prête à être injectée dans le system prompt.
    Ignore les projets terminés (status == 'termine').
    """
    projects = load_projects()
    visible = [p for p in projects if p.get("status", "actif") != "termine"]
    if not visible:
        return ""

    lines = ["## 📂 PROJETS ACTIFS DE L'UTILISATEUR"]
    lines.append("L'utilisateur travaille sur les projets suivants. Utilise ces informations pour contextualiser tes réponses sans demander de recontextualisation.\n")

    for p in visible:
        status_label = _STATUS_LABELS.get(p.get("status", "actif"), p.get("status", ""))
        lines.append(f"### {p['name']}  [{status_label}]")
        if p.get("tech_stack"):
            lines.append(f"**Technologies** : {p['tech_stack']}")
        if p.get("path"):
            lines.append(f"**Chemin** : {p['path']}")
        if p.get("description"):
            lines.append(f"**Description** : {p['description']}")
        if p.get("notes"):
            lines.append(f"**Notes** : {p['notes']}")
        lines.append("")

    return "\n".join(lines).strip()


# ── Gestion des correctifs & leçons apprises ──────────────────────────────────

def corrections_context_string() -> str:
    """
    Retourne tous les faits de catégorie 'correction' formatés en liste compacte,
    prêts à être injectés dans le system prompt.
    """
    store = load_store() if False else None  # lazy import — on appelle load_store directement
    # load_store défini plus bas ; on charge ici sans dépendance circulaire
    import json as _json
    os.makedirs(MEMORY_DIR, exist_ok=True)
    facts_all = []
    if os.path.exists(MEMORY_FILE):
        try:
            with open(MEMORY_FILE, "r", encoding="utf-8") as f:
                data = _json.load(f)
            facts_all = data.get("facts", [])
        except Exception:
            pass
    corrections = [f for f in facts_all if f.get("category") == "correction"]
    if not corrections:
        return ""
    lines = [
        "## 📋 CORRECTIFS & PIÈGES CONNUS",
        "Ces correctifs ont été identifiés lors de sessions précédentes. "
        "Vérifie ces points AVANT de proposer une solution :\n",
    ]
    for c in corrections:
        lines.append(f"• {c['content']}")
    return "\n".join(lines)


def _parse_lessons_md(md_text: str) -> list:
    """
    Parse un fichier lessons_learned.md structuré (sections ##) en corrections individuelles.
    Chaque section ## devient un fait correction avec titre + contenu condensé.
    Retourne une liste de dict {title, content, tags}.
    """
    corrections = []
    # Diviser par les sections de niveau ##
    raw_sections = re.split(r'\n(?=## )', "\n" + md_text)

    for section in raw_sections:
        lines = [l.rstrip() for l in section.split('\n') if l.strip()]
        if not lines:
            continue
        # Chercher la ligne titre ## ...
        title_line = next((l for l in lines if l.startswith('## ')), None)
        if not title_line:
            continue
        title = re.sub(r'^##\s+\d+[\.\d]*\s*', '', title_line).strip()
        if not title:
            continue

        # Extraire les bullets et paragraphes clés (sans les sous-titres ### ni les blocs code)
        key_points = []
        in_code = False
        for line in lines:
            if line.startswith('```'):
                in_code = not in_code
                continue
            if in_code or line.startswith('## ') or line.startswith('### '):
                continue
            # Garder bullets et phrases **Solution** / **Problème**
            clean = re.sub(r'\*\*(.*?)\*\*', r'\1', line)  # supprimer gras
            clean = re.sub(r'`(.*?)`', r'\1', clean)         # supprimer inline code
            clean = clean.lstrip('*-• ').strip()
            if len(clean) > 20:
                key_points.append(clean)
            if len(key_points) >= 3:
                break

        if not key_points:
            continue

        # Contenu condensé : titre + 1-3 points clés
        summary = f"[{title[:50]}] " + " | ".join(key_points[:2])
        if len(summary) > 500:
            summary = summary[:497] + "…"

        corrections.append({
            "title": title,
            "content": summary,
            "tags": ["windev", "wlangage"],
        })

    return corrections


def import_lessons_md(file_path: str) -> dict:
    """
    Lit un fichier lessons_learned.md et importe chaque section comme un fait 'correction'.
    Retourne un dict {status, imported, skipped, errors}.
    """
    if not os.path.exists(file_path):
        return {"status": "error", "message": f"Fichier introuvable : {file_path}"}
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            md_text = f.read()
    except Exception as e:
        return {"status": "error", "message": f"Erreur lecture : {e}"}

    parsed = _parse_lessons_md(md_text)
    imported = 0
    for c in parsed:
        fid = save_fact(c["content"], "correction", f"import:{os.path.basename(file_path)}")
        if fid:
            imported += 1

    return {
        "status": "ok",
        "imported": imported,
        "skipped": len(parsed) - imported,
        "total_parsed": len(parsed),
        "file": file_path,
    }


# ── Structure de base ──────────────────────────────────────────────────────────

def _empty_store() -> dict:
    return {"version": 1, "facts": [], "sessions": []}


def load_store() -> dict:
    with _STORE_LOCK:
        os.makedirs(MEMORY_DIR, exist_ok=True)
        if os.path.exists(MEMORY_FILE):
            try:
                with open(MEMORY_FILE, "r", encoding="utf-8") as f:
                    data = json.load(f)
                data.setdefault("facts", [])
                data.setdefault("sessions", [])
                return data
            except Exception as e:
                print(f"[Memory] Avertissement lecture store : {e}")
                _quarantine_corrupted_file(MEMORY_FILE)
        return _empty_store()


def save_store(store: dict) -> None:
    with _STORE_LOCK:
        _atomic_json_save(MEMORY_FILE, store)


# ── Moteur de recherche textuelle ─────────────────────────────────────────────

_STOPS = {
    "les", "des", "une", "pour", "dans", "sur", "avec", "son", "ses", "qui",
    "que", "est", "pas", "par", "plus", "aux", "mais", "car", "donc", "tres",
    "aussi", "bien", "tout", "etre", "avoir", "faire", "the", "and", "for",
    "that", "this", "with", "from", "but", "are", "was", "has", "not", "its",
}


def _tokenize(text: str) -> list:
    words = re.findall(r'\b[a-z]{3,}\b', text.lower())
    return [w for w in words if w not in _STOPS]


def _relevance_score(query_tokens: list, text: str) -> float:
    if not query_tokens:
        return 0.0
    text_tokens = set(_tokenize(text))
    if not text_tokens:
        return 0.0
    return sum(1 for t in query_tokens if t in text_tokens) / len(query_tokens)


def recall(query: str, n: int = 5) -> list:
    with _STORE_LOCK:
        store = load_store()
        q_tokens = _tokenize(query)
        if not q_tokens:
            return [f["content"] for f in store["facts"][-n:]]

        scored = []
        for fact in store["facts"]:
            s = _relevance_score(q_tokens, fact["content"])
            if s > 0:
                scored.append((s, fact["content"]))
        for sess in store["sessions"]:
            summary = sess.get("summary", "")
            if summary:
                s = _relevance_score(q_tokens, summary) * 0.7
                if s > 0:
                    scored.append((s, f"[Session {sess.get('date','?')}] {summary}"))

        scored.sort(key=lambda x: x[0], reverse=True)
        return [text for _, text in scored[:n]]


# ── Sauvegarde d'un fait ──────────────────────────────────────────────────────

def save_fact(content: str, category: str = "general", source: str = "user") -> str:
    content = content.strip()
    if not content:
        return ""
    with _STORE_LOCK:
        store = load_store()
        q_tokens = set(_tokenize(content))

        # Déduplication : si chevauchement > 80%, mise à jour plutôt qu'ajout
        for existing in store["facts"]:
            ex_tokens = set(_tokenize(existing["content"]))
            overlap = len(q_tokens & ex_tokens) / max(len(q_tokens), 1)
            if overlap > 0.8:
                existing["content"] = content
                existing["updated"] = datetime.now().isoformat()
                existing["source"] = source
                save_store(store)
                print(f"[Memory] Fait mis a jour (doublon) : {content[:60]}")
                return existing["id"]

        fact = {
            "id": uuid.uuid4().hex[:12],
            "content": content,
            "category": category,
            "source": source,
            "created": datetime.now().isoformat(),
            "updated": datetime.now().isoformat(),
        }
        store["facts"].append(fact)
        if len(store["facts"]) > 500:          # FIFO : max 500 faits
            store["facts"] = store["facts"][-500:]
        save_store(store)
        print(f"[Memory] Nouveau fait [{category}] : {content[:60]}")
        return fact["id"]


# ── Extraction LLM ────────────────────────────────────────────────────────────

_EXTRACTION_SYSTEM = """Tu es un extracteur de memoire pour un assistant IA. Analyse la conversation et extrait les faits importants a memoriser a long terme.

REGLES :
1. Faits durables uniquement (preferences, projets, decisions techniques, corrections importantes)
2. Ignore les details ephemeres et les erreurs anecdotiques
3. Chaque fait = UNE phrase complete, autonome et comprehensible sans contexte
4. Maximum 8 faits par conversation
5. Categories: preference | project | technical | correction | person | other

Reponds UNIQUEMENT avec du JSON valide, sans texte avant ni apres :
{
  "facts": [
    {"content": "phrase complete decrivant le fait memorable", "category": "categorie"},
    ...
  ],
  "session_summary": "resume de 2-3 phrases de cette session"
}"""


def extract_and_save(conversation: str, llm_endpoint: str, model: str = "") -> dict:
    conv_truncated = conversation[:6000]
    if len(conversation) > 6000:
        conv_truncated += "\n\n[... conversation tronquee a 6000 caracteres ...]"

    payload = json.dumps({
        "model": model or "local-model",
        "messages": [
            {"role": "system", "content": _EXTRACTION_SYSTEM},
            {"role": "user", "content": f"Conversation a analyser :\n\n{conv_truncated}"},
        ],
        "temperature": 0.15,
        "max_tokens": 1024,
    }).encode("utf-8")

    url = llm_endpoint.rstrip("/") + "/chat/completions"
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            result = json.loads(resp.read().decode("utf-8"))
            content = result["choices"][0]["message"]["content"].strip()
    except urllib.error.URLError as e:
        return {"status": "error", "message": f"LLM injoignable ({url}) : {e}"}
    except Exception as e:
        return {"status": "error", "message": f"Erreur requete LLM : {e}"}

    # Nettoyage des balises ```json``` que certains LLMs ajoutent
    content = re.sub(r'^```(?:json)?\s*', '', content)
    content = re.sub(r'\s*```$', '', content.strip())

    try:
        extracted = json.loads(content)
    except json.JSONDecodeError as e:
        return {"status": "error", "message": f"JSON invalide : {e}\nReponse: {content[:300]}"}

    saved_facts = []
    for f in extracted.get("facts", []):
        text = f.get("content", "").strip()
        if text:
            fid = save_fact(text, f.get("category", "general"), "llm_extraction")
            saved_facts.append({"id": fid, "content": text, "category": f.get("category", "general")})

    summary = extracted.get("session_summary", "").strip()
    if summary:
        store = load_store()
        store["sessions"].append({
            "id": uuid.uuid4().hex[:12],
            "date": datetime.now().strftime("%Y-%m-%d"),
            "timestamp": datetime.now().isoformat(),
            "summary": summary,
            "facts_count": len(saved_facts),
        })
        if len(store["sessions"]) > 200:    # FIFO : max 200 sessions
            store["sessions"] = store["sessions"][-200:]
        save_store(store)

    print(f"[Memory] Extraction OK : {len(saved_facts)} faits — {summary[:80]}")
    return {"status": "ok", "facts_saved": len(saved_facts), "facts": saved_facts, "summary": summary}


# ── Serveur HTTP ──────────────────────────────────────────────────────────────

class MemoryHandler(BaseHTTPRequestHandler):

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")

    def _send_json(self, data: dict, status: int = 200):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        if self.command != "GET":
            print(f"[Memory] {self.command} {self.path}")

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        path   = parsed.path

        if path in ("/", "/health"):
            store = load_store()
            self._send_json({"status": "ok", "service": "CrisperWeaver Memory Server",
                             "facts": len(store["facts"]), "sessions": len(store["sessions"])})

        elif path == "/memory/recall":
            q = params.get("q", [""])[0]
            n = min(int(params.get("n", ["5"])[0]), 20)
            self._send_json({"query": q, "results": recall(q, n)})

        elif path == "/memory/facts":
            store = load_store()
            facts = sorted(store["facts"], key=lambda f: f.get("updated", ""), reverse=True)
            self._send_json({"facts": facts, "count": len(facts)})

        elif path == "/memory/sessions":
            store = load_store()
            self._send_json({"sessions": list(reversed(store["sessions"][-20:])),
                             "total": len(store["sessions"])})

        elif path == "/memory/stats":
            store = load_store()
            cats: dict = {}
            for f in store["facts"]:
                c = f.get("category", "general")
                cats[c] = cats.get(c, 0) + 1
            size_kb = os.path.getsize(MEMORY_FILE) // 1024 if os.path.exists(MEMORY_FILE) else 0
            self._send_json({"total_facts": len(store["facts"]),
                             "total_sessions": len(store["sessions"]),
                             "categories": cats, "storage_kb": size_kb})

        # ── Endpoints projets ──────────────────────────────────────────────────
        elif path == "/projects":
            projects = load_projects()
            self._send_json({"projects": projects, "count": len(projects)})

        elif path == "/projects/context":
            ctx = project_context_string()
            self._send_json({"context": ctx, "has_projects": bool(ctx)})

        # ── Endpoints correctifs ───────────────────────────────────────────────
        elif path == "/corrections":
            store = load_store()
            corrections = [f for f in store["facts"] if f.get("category") == "correction"]
            corrections.sort(key=lambda f: f.get("updated", ""), reverse=True)
            self._send_json({"corrections": corrections, "count": len(corrections)})

        elif path == "/corrections/context":
            ctx = corrections_context_string()
            self._send_json({"context": ctx, "has_corrections": bool(ctx)})

        # ── Endpoints fichiers & chemins ───────────────────────────────────────
        elif path == "/files":
            files = load_files()
            self._send_json({"files": files, "count": len(files)})

        elif path == "/files/context":
            ctx = files_context_string()
            self._send_json({"context": ctx, "has_files": bool(ctx)})

        # ── Endpoints bibliothèque MCP ─────────────────────────────────────────
        elif path == "/mcps":
            mcps = load_mcps()
            self._send_json({"mcps": mcps, "count": len(mcps)})

        elif path == "/mcps/context":
            ctx = mcp_prompts_context()
            self._send_json({"context": ctx, "has_mcps": bool(ctx)})

        else:
            self._send_json({"error": f"Endpoint inconnu : {path}"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            self._send_json({"error": "Body JSON invalide"}, 400)
            return

        path = urlparse(self.path).path

        if path == "/memory/save":
            text = body.get("text", "").strip()
            if not text:
                self._send_json({"error": "Champ 'text' requis"}, 400)
                return
            fid = save_fact(text, body.get("category", "general"), body.get("source", "user"))
            self._send_json({"status": "ok", "id": fid, "content": text})

        elif path == "/memory/extract":
            conv = body.get("conversation", "").strip()
            if not conv:
                self._send_json({"error": "Champ 'conversation' requis"}, 400)
                return
            endpoint = body.get("endpoint", "http://localhost:1234/v1")
            model    = body.get("model", "")
            result   = extract_and_save(conv, endpoint, model)
            self._send_json(result, 200 if result["status"] == "ok" else 500)

        elif path == "/memory/forget":
            fact_id = body.get("id", "").strip()
            if not fact_id:
                self._send_json({"error": "Champ 'id' requis"}, 400)
                return
            store  = load_store()
            before = len(store["facts"])
            store["facts"] = [f for f in store["facts"] if f.get("id") != fact_id]
            save_store(store)
            if len(store["facts"]) == before:
                self._send_json({"status": "not_found", "id": fact_id}, 404)
            else:
                self._send_json({"status": "ok", "id": fact_id})

        # ── Endpoints projets ──────────────────────────────────────────────────
        elif path == "/projects/save":
            name = body.get("name", "").strip()
            if not name:
                self._send_json({"error": "Champ 'name' requis"}, 400)
                return
            project = upsert_project(body)
            self._send_json({"status": "ok", "project": project})

        elif path == "/projects/delete":
            pid = body.get("id", "").strip()
            if not pid:
                self._send_json({"error": "Champ 'id' requis"}, 400)
                return
            ok = delete_project(pid)
            self._send_json({"status": "ok" if ok else "not_found", "id": pid},
                            200 if ok else 404)

        # ── Endpoints correctifs ───────────────────────────────────────────────
        elif path == "/corrections/save":
            # Sauvegarde directe d'un correctif  {text, source?}
            text = body.get("text", "").strip()
            if not text:
                self._send_json({"error": "Champ 'text' requis"}, 400)
                return
            fid = save_fact(text, "correction", body.get("source", "user"))
            self._send_json({"status": "ok", "id": fid, "content": text})

        elif path == "/corrections/import":
            # Importer un fichier lessons_learned.md  {path?}
            default_path = os.path.join(os.path.dirname(SCRIPT_DIR), "AgentFolder", "lessons_learned.md")
            file_path = body.get("path", default_path).strip()
            print(f"[Memory/Corrections] Import depuis : {file_path}")
            result = import_lessons_md(file_path)
            self._send_json(result, 200 if result["status"] == "ok" else 400)

        elif path == "/corrections/delete":
            fact_id = body.get("id", "").strip()
            if not fact_id:
                self._send_json({"error": "Champ 'id' requis"}, 400)
                return
            store = load_store()
            before = len(store["facts"])
            store["facts"] = [f for f in store["facts"]
                              if not (f.get("id") == fact_id and f.get("category") == "correction")]
            save_store(store)
            ok = len(store["facts"]) < before
            self._send_json({"status": "ok" if ok else "not_found", "id": fact_id},
                            200 if ok else 404)

        # ── Endpoints fichiers & chemins ───────────────────────────────────────
        elif path == "/files/save":
            label = body.get("label", "").strip()
            path_ = body.get("path", "").strip()
            if not label or not path_:
                self._send_json({"error": "Champs 'label' et 'path' requis"}, 400)
                return
            entry = upsert_file(body)
            self._send_json({"status": "ok", "file": entry})

        elif path == "/files/delete":
            fid = body.get("id", "").strip()
            if not fid:
                self._send_json({"error": "Champ 'id' requis"}, 400)
                return
            ok = delete_file_entry(fid)
            self._send_json({"status": "ok" if ok else "not_found", "id": fid},
                            200 if ok else 404)

        # ── Endpoints bibliothèque MCP ─────────────────────────────────────────
        elif path == "/mcps/save":
            name = body.get("name", "").strip()
            mcp_type = body.get("type", "").strip()
            if not name or not mcp_type:
                self._send_json({"error": "Champs 'name' et 'type' requis"}, 400)
                return
            entry = upsert_mcp(body)
            self._send_json({"status": "ok", "mcp": entry})

        elif path == "/mcps/delete":
            mcp_id = body.get("id", "").strip()
            if not mcp_id:
                self._send_json({"error": "Champ 'id' requis"}, 400)
                return
            ok = delete_mcp(mcp_id)
            self._send_json({"status": "ok" if ok else "not_found", "id": mcp_id},
                            200 if ok else 404)

        elif path == "/mcps/toggle":
            mcp_id = body.get("id", "").strip()
            enabled = bool(body.get("enabled", True))
            if not mcp_id:
                self._send_json({"error": "Champ 'id' requis"}, 400)
                return
            ok = toggle_mcp(mcp_id, enabled)
            self._send_json({"status": "ok" if ok else "not_found",
                             "id": mcp_id, "enabled": enabled},
                            200 if ok else 404)

        else:
            self._send_json({"error": f"Endpoint inconnu : {path}"}, 404)

    def do_DELETE(self):
        if urlparse(self.path).path == "/memory/clear":
            save_store(_empty_store())
            print("[Memory] Memoire entierement effacee.")
            self._send_json({"status": "ok", "message": "Memoire effacee."})
        else:
            self._send_json({"error": "Endpoint inconnu"}, 404)


# ── Point d'entrée ────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=7862)
    args = parser.parse_args()

    os.makedirs(MEMORY_DIR, exist_ok=True)
    store = load_store()

    httpd = HTTPServer(("127.0.0.1", args.port), MemoryHandler)
    print("=" * 60)
    print("  CrisperWeaver Memory Server")
    print(f"  Ecoute   : http://127.0.0.1:{args.port}")
    print(f"  Faits    : {len(store['facts'])}")
    print(f"  Sessions : {len(store['sessions'])}")
    print(f"  Fichier  : {MEMORY_FILE}")
    print("=" * 60)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.server_close()
        print("[Memory] Serveur arrete.")


if __name__ == "__main__":
    main()
