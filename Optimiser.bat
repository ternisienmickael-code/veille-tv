@echo off
rem Double-clique sur ce fichier pour lancer l'optimisation du PC.
rem Il se relance tout seul en administrateur si besoin.
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimiser.ps1"
echo.
pause
