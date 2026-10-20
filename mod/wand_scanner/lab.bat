@echo off
rem Lab session: backs up your saves, runs Noita with lab settings, restores the saves when Noita closes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lab.ps1" %*
pause
