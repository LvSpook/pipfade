@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pipfade.ps1" -Reset
timeout /t 3 >nul
