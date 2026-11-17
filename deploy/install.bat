@echo off
rem Double-click to install L16 Studio on a connected Light L16.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
