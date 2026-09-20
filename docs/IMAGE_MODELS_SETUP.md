# Guide d'Installation et Configuration des Modèles d'Images (Jarvisol)

Ce document fournit la documentation complète, les spécifications techniques, la matrice de compatibilité et les instructions de téléchargement pour l'ensemble des modèles d'intelligence artificielle utilisés par le sous-système de génération et d'édition d'images de Jarvisol.

---

## 1. Principes Fondamentaux

- **Aucun poids binaire dans le dépôt Git** : Conformément à la politique de reproductibilité légère de Jarvisol, les fichiers de modèles (`*.safetensors`, `*.gguf`, `*.bin`, `*.pt`, `*.onnx`) ne sont **jamais** versionnés dans GitHub.
- **Intégrité Cryptographique SHA-256** : Chaque modèle dispose d'une empreinte cryptographique SHA-256 canonique contrôlée avant activation.
- **Structure de Répertoire Standardisée** : Le runtime de production charge les modèles depuis le dossier racine `models/`.
- **Automatisation via Script** : Le script PowerShell `scripts/download_image_models.ps1` automatise le téléchargement, la vérification des empreintes et l'installation par packs logiques sans écrasement destructif.

---

## 2. Matrice de Compatibilité et Routage des Architectures

Le backend d'imagerie de Jarvisol (`sd_server.py` et son binaire `sd_server.exe`) repose sur le moteur d'inférence C++ accéléré Vulkan `sd-cli.exe`. Différentes familles de modèles sont utilisées pour des cas d'usage distincts :

| Famille / Architecture | Exemples de Modèles | Text2Img | Inpainting Simple | IP-Adapter (Général) | IP-Adapter (Visage) | Détection Auto Face (YOLOv8) | Masque Manuel |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **SD 1.5 Inpainting** | `Realistic_Vision_V6.0_NV_B1_inpainting_fp16`, `stable-diffusion-v1-5-inpainting-Q4_0` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **DiT Flash / Fast** | `chroma-unlocked-v46-flash-Q4_0`, `flux1-schnell-Q4_K_S`, `sd3.5_large_turbo-q4_0` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **SDXL Checkpoints** | `dreamshaperXL_lightningDPMSDE`, `realvisxlV50_v50LightningBakedvae`, `juggernautXL_ragnarok` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **SDXL Pony** | `CyberRealisticPony_V18.0_F16` | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |

> [!IMPORTANT]
> **Règle d'incompatibilité absolue IP-Adapter & Auto Face** :  
> Les fonctionnalités de composition multi-images basées sur **IP-Adapter** (`reference_person_or_object`, `reference_face`) et la **détection automatique de visage** (`auto_face_detect`) sont entraînées spécifiquement sur l'espace latent **Stable Diffusion 1.5**.  
> Le backend `sd_server.py` applique un contrôle strict à la réception de la requête : toute tentative d'utiliser un modèle SDXL, SD 3.5, FLUX ou Chroma avec un adaptateur d'image lève immédiatement une erreur `HTTP 400 (INCOMPATIBLE_MODEL)` pour éviter toute dégradation ou crash du serveur.

---

## 3. Packs Logiques de Téléchargement

Pour éviter de télécharger l'intégralité des ~70 Go de modèles lorsque seul un cas d'usage précis est ciblé, Jarvisol organise les modèles en **5 packs logiques** :

### 3.1 Pack `IMAGE_BASIC` (~7.94 Go / 3 fichiers)
Idéal pour démarrer rapidement la génération de texte vers image ultra-rapide (inférence en 8 passes).
- `models/Stable-diffusion/chroma-unlocked-v46-flash-Q4_0.gguf` (5.06 Go)
- `models/Stable-diffusion/ae.safetensors` (320 Mo)
- `models/Stable-diffusion/t5xxl_q4_k.gguf` (2.56 Go)

### 3.2 Pack `IMAGE_INPAINT` (~2.30 Go / 2 fichiers)
Permet d'activer la retouche et la repeinte de zones masquées sur une image existante.
- `models/Stable-diffusion/Realistic_Vision_V6.0_NV_B1_inpainting_fp16.safetensors` (1.99 Go)
- `models/Stable-diffusion/vae-ft-mse-840000-ema-pruned.safetensors` (319 Mo)

### 3.3 Pack `IMAGE_MULTI_SD15` (~4.84 Go / 5 fichiers)
Permet la composition multi-images (Image A + Image B) et l'injection de références d'objets ou de visages via IP-Adapter.
- Contient l'intégralité du pack `IMAGE_INPAINT` (2.30 Go)
- `models/image_conditioning/clip_vision/clip_vision_vit_h.safetensors` (2.35 Go)
- `models/image_conditioning/ip_adapter/ip-adapter-plus_sd15.safetensors` (93.6 Mo)
- `models/image_conditioning/ip_adapter/ip-adapter-plus-face_sd15.safetensors` (93.6 Mo)

### 3.4 Pack `IMAGE_AUTO_FACE` (~4.85 Go / 6 fichiers)
Ajoute la détection automatique de visages par réseau neuronal ultra-léger YOLOv8n pour le ciblage et la restauration sans tracé manuel de masque.
- Contient l'intégralité du pack `IMAGE_MULTI_SD15` (4.84 Go)
- `models/image_conditioning/detectors/face_yolov8n.safetensors` (5.75 Mo)

### 3.5 Pack `IMAGE_FULL` (~70.79 Go / 19 fichiers)
Suite complète de tous les 19 modèles de production certifiés (SDXL, Pony, FLUX.1, SD 3.5, Chroma, Inpainting haute précision FP32 et GGUF, VAEs et encodeurs de texte).

---

## 4. Organisation de l'Arborescence Disque

Les fichiers doivent être positionnés exactement dans les sous-dossiers suivants à la racine de Jarvisol (ou dans le dossier pointé par `sd_server`) :

```
Jarvisol/
├── models/
│   ├── Stable-diffusion/
│   │   ├── chroma-unlocked-v46-flash-Q4_0.gguf
│   │   ├── ae.safetensors
│   │   ├── t5xxl_q4_k.gguf
│   │   ├── clip_l.safetensors
│   │   ├── clip_g.safetensors
│   │   ├── flux1-schnell-Q4_K_S.gguf
│   │   ├── sd3.5_large_turbo-q4_0.gguf
│   │   ├── dreamshaperXL_lightningDPMSDE.safetensors
│   │   ├── realvisxlV50_v50LightningBakedvae.safetensors
│   │   ├── juggernautXL_ragnarok.safetensors
│   │   ├── CyberRealisticPony_V18.0_F16.safetensors
│   │   ├── Realistic_Vision_V6.0_NV_B1_inpainting_fp16.safetensors
│   │   ├── Realistic_Vision_V6.0_NV_B1_inpainting.safetensors
│   │   ├── stable-diffusion-v1-5-inpainting-Q4_0.gguf
│   │   └── vae-ft-mse-840000-ema-pruned.safetensors
│   └── image_conditioning/
│       ├── clip_vision/
│       │   └── clip_vision_vit_h.safetensors
│       ├── ip_adapter/
│       │   ├── ip-adapter-plus_sd15.safetensors
│       │   └── ip-adapter-plus-face_sd15.safetensors
│       └── detectors/
│           └── face_yolov8n.safetensors
```

---

## 5. Utilisation du Script Automatisé `download_image_models.ps1`

Le script PowerShell situé dans `scripts/download_image_models.ps1` prend en charge le téléchargement robuste avec reprise sur incident, contrôle d'empreinte SHA-256 bit-à-bit et renommage atomique (`.part` $\rightarrow$ fichier final).

### 5.1 Lister les packs et modèles disponibles
```powershell
.\scripts\download_image_models.ps1 -List
```

### 5.2 Simuler le téléchargement d'un pack (`-DryRun`)
```powershell
.\scripts\download_image_models.ps1 -Pack IMAGE_AUTO_FACE -DryRun
```

### 5.3 Télécharger un pack spécifique
```powershell
# Pour la composition multi-images et détection visage :
.\scripts\download_image_models.ps1 -Pack IMAGE_AUTO_FACE

# Pour la génération rapide texte vers image :
.\scripts\download_image_models.ps1 -Pack IMAGE_BASIC
```

### 5.4 Télécharger un modèle individuel
```powershell
.\scripts\download_image_models.ps1 -Model clip_vision_vit_h
```

### 5.5 Spécifier un dossier de destination personnalisé
```powershell
.\scripts\download_image_models.ps1 -Pack IMAGE_BASIC -Destination "D:\Jarvisol_Release"
```

---

## 6. Répertoire Canonique des 19 Modèles (Liens Directs et Empreintes SHA-256)

| Fichier | Emplacement Relatif | Taille (octets) | Empreinte SHA-256 | URL Source Officielle | Licence |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `chroma-unlocked-v46-flash-Q4_0.gguf` | `models/Stable-diffusion/` | 5 432 053 920 | `3B114C0B32145C3E725BA72B571FC0641748672EDA789596E882DB24FB77AD16` | [HuggingFace](https://huggingface.co/silveroxides/Chroma-GGUF/resolve/main/chroma-unlocked-v46-flash/chroma-unlocked-v46-flash-Q4_0.gguf) | Apache-2.0 |
| `ae.safetensors` | `models/Stable-diffusion/` | 335 304 388 | `AFC8E28272CD15DB3919BACDB6918CE9C1ED22E96CB12C4D5ED0FBA823529E38` | [HuggingFace](https://huggingface.co/receptektas/black-forest-labs-ae_safetensors/resolve/main/ae.safetensors) | Apache-2.0 |
| `t5xxl_q4_k.gguf` | `models/Stable-diffusion/` | 2 752 844 256 | `B235E9A108CCC1803C576464E937CF5EC4D8EB34D83776E5199450400D4E0BCB` | [HuggingFace](https://huggingface.co/Green-Sky/flux.1-schnell-GGUF/resolve/main/t5xxl_q4_k.gguf) | Apache-2.0 |
| `clip_l.safetensors` | `models/Stable-diffusion/` | 246 144 152 | `660C6F5B1ABAE9DC498AC2D21E1347D2ABDB0CF6C0C0C8576CD796491D9A6CDD` | [HuggingFace](https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors) | MIT |
| `clip_g.safetensors` | `models/Stable-diffusion/` | 1 389 382 176 | `EC310DF2AF79C318E24D20511B601A591CA8CD4F1FCE1D8DFF822A356BCDB1F4` | [HuggingFace](https://huggingface.co/Comfy-Org/stable-diffusion-3.5-fp8/resolve/main/text_encoders/clip_g.safetensors) | Stability Community |
| `flux1-schnell-Q4_K_S.gguf` | `models/Stable-diffusion/` | 6 783 943 712 | `4FD16477B3A5296D0CF722C4B92A9FD7F30D09AC7495826E4465D8DE9C9FD973` | [HuggingFace](https://huggingface.co/city96/FLUX.1-schnell-gguf/resolve/main/flux1-schnell-Q4_K_S.gguf) | Apache-2.0 |
| `sd3.5_large_turbo-q4_0.gguf` | `models/Stable-diffusion/` | 4 772 054 752 | `5F924F492535FFAEC48359B7FE6E1A621EED16FB8DE4E1B408132D90B1039382` | [HuggingFace](https://huggingface.co/calcuis/sd3.5-large-turbo/resolve/main/sd3.5_large_turbo-q4_0.gguf) | Stability Community |
| `dreamshaperXL_lightningDPMSDE.safetensors` | `models/Stable-diffusion/` | 6 939 220 250 | `FDBE56354B8F876B736F24D3AD867ECD4140C019F57642EC8DDD878088D44F64` | [Civitai](https://civitai.com/api/download/models/354657) | Civitai Permissive |
| `realvisxlV50_v50LightningBakedvae.safetensors` | `models/Stable-diffusion/` | 6 938 065 512 | `FABCADD9330DCC4F9702063428D40B9D4D07168D8ACEFC819B8D1D9DB466B3EC` | [Civitai](https://civitai.com/api/download/models/361593) | Civitai Permissive |
| `juggernautXL_ragnarok.safetensors` | `models/Stable-diffusion/` | 7 105 350 162 | `DD08FA32F98D05A2443CA1419E46DF1575A0811F6E3B246D9DD47FF20F5EB66A` | [Civitai](https://civitai.com/api/download/models/782002) | Civitai Permissive |
| `CyberRealisticPony_V18.0_F16.safetensors` | `models/Stable-diffusion/` | 6 938 041 288 | `1D580C1C3F3612FA4DB88AF65372255582D5509CA0B28F85387273368301941B` | [Civitai](https://civitai.com/api/download/models/482329) | Civitai Permissive |
| `Realistic_Vision_V6.0_NV_B1_inpainting_fp16.safetensors` | `models/Stable-diffusion/` | 2 136 906 350 | `D939CBDBCE19A9D8837794ACD06EF8DB1AD4A2F2BCF1418432D897EAC98F1AFD` | [HuggingFace](https://huggingface.co/SG161222/Realistic_Vision_V6.0_B1_noVAE/resolve/main/Realistic_Vision_V6.0_NV_B1_inpainting_fp16.safetensors) | OpenRAIL-M |
| `Realistic_Vision_V6.0_NV_B1_inpainting.safetensors` | `models/Stable-diffusion/` | 4 265 203 868 | `E9C575DBBE237EA889E14C41F953FC9FB311439A88B15BB2E789B0630AE45EFE` | [HuggingFace](https://huggingface.co/SG161222/Realistic_Vision_V6.0_B1_noVAE/resolve/main/Realistic_Vision_V6.0_NV_B1_inpainting.safetensors) | OpenRAIL-M |
| `stable-diffusion-v1-5-inpainting-Q4_0.gguf` | `models/Stable-diffusion/` | 1 747 219 584 | `D157CE24483F0C999062DA140EACEBE8F3ED015E652723E31F6D39119B800C16` | [HuggingFace](https://huggingface.co/gpustack/stable-diffusion-v1-5-inpainting-GGUF/resolve/main/stable-diffusion-v1-5-inpainting-Q4_0.gguf) | OpenRAIL-M |
| `vae-ft-mse-840000-ema-pruned.safetensors` | `models/Stable-diffusion/` | 334 641 190 | `735E4C3A447A3255760D7F86845F09F937809BAA529C17370D83E4C3758F3C75` | [HuggingFace](https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors) | OpenRAIL-M |
| `clip_vision_vit_h.safetensors` | `models/image_conditioning/clip_vision/` | 2 528 373 448 | `6CA9667DA1CA9E0B0F75E46BB030F7E011F44F86CBFB8D5A36590FCD7507B030` | [HuggingFace](https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors) | Apache-2.0 |
| `ip-adapter-plus_sd15.safetensors` | `models/image_conditioning/ip_adapter/` | 98 183 288 | `A1C250BE40455CC61A43DA1201EC3F1EDAEA71214865FB47F57927E06CBE4996` | [HuggingFace](https://huggingface.co/h94/IP-Adapter/resolve/main/models/ip-adapter-plus_sd15.safetensors) | Apache-2.0 |
| `ip-adapter-plus-face_sd15.safetensors` | `models/image_conditioning/ip_adapter/` | 98 183 288 | `1C9EDC21AF6F737DC1D6E0E734190E976CFACF802D6B024B77AA3BE922F7569B` | [HuggingFace](https://huggingface.co/h94/IP-Adapter/resolve/main/models/ip-adapter-plus-face_sd15.safetensors) | Apache-2.0 |
| `face_yolov8n.safetensors` | `models/image_conditioning/detectors/` | 6 033 980 | `CFA9840E2E6B82A48D644AF2924823E5EB26EF4333A90F840CC4F7DC49087FD7` | [HuggingFace](https://huggingface.co/exeterminal/adetailer-yolov8-safetensors/resolve/main/face_yolov8n.safetensors) | AGPL-3.0 |

---

## 7. Vérification Manuelle des Empreintes SHA-256

Si vous téléchargez un modèle manuellement avec votre navigateur ou un outil tiers (`curl`, `wget`, `aria2c`), vous pouvez vérifier son intégrité en PowerShell :

```powershell
Get-FileHash -Algorithm SHA256 "models/image_conditioning/clip_vision/clip_vision_vit_h.safetensors"
```

L'empreinte retournée doit correspondre strictement à la valeur canonique listée dans le tableau ci-dessus et dans `docs/image_models_manifest.json`.
