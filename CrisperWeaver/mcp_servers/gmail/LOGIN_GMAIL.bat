@echo off
set GMAIL_OAUTH_PATH=%~dp0gcp-oauth.keys.json
set GMAIL_CREDENTIALS_PATH=%~dp0credentials.json
echo Ouverture du navigateur pour autoriser Gmail via MCP (si besoin)...
cmd /c npx -y @monsoft/mcp-gmail auth
echo Termine. Vous pouvez relancer Jarvisol.
pause
