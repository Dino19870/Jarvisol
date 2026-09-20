@echo off
title Serveur d'Images Local - CrisperWeaver (Portable)
cd /d "%~dp0"
echo =======================================================
echo Serveur Text-to-Image Local Portable pour CrisperWeaver
echo Endpoint API : http://127.0.0.1:7860
echo Dossier Modeles : %~dp0models\Stable-diffusion
echo =======================================================

REM Priorite 1 : executable autonome (aucun Python requis)
if exist "%~dp0sd_server.exe" (
    echo Demarrage du serveur d'images [sd_server.exe] sur le port 7860...
    "%~dp0sd_server.exe" --port 7860
    goto :end
)

REM Priorite 2 : script Python (necessite Python installe)
if exist "%~dp0sd_server.py" (
    echo Demarrage du serveur d'images [Python] sur le port 7860...
    python "%~dp0sd_server.py" --port 7860
    goto :end
)

REM Priorite 3 : AUTOMATIC1111 / Forge WebUI
if exist "%~dp0webui.bat" (
    call "%~dp0webui.bat" --api --port 7860 --nowebui --xformers --ckpt-dir "%~dp0models\Stable-diffusion"
    goto :end
)

echo ERREUR : sd_server.exe, sd_server.py et webui.bat sont introuvables dans :
echo %~dp0
pause
:end
