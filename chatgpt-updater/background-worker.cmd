@echo off
setlocal
set "SCRIPT=%~dp0background-worker.ps1"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
