@echo off
rem Start pipfade without leaving a console window behind.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File','\"%~dp0pipfade.ps1\"' -WindowStyle Hidden"
if errorlevel 1 pause
