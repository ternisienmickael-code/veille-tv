@echo off
rem Double-clique sur ce fichier pour ouvrir l'application PC Tout-en-Un.
rem Il se relance tout seul en administrateur si besoin.
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Tout_En_Un.ps1"
exit
