@echo off
setlocal
title Windows ARM Boot Repair - Interactive
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-ArmBoot.ps1" -Mode Interactive %*
set "repairCode=%errorlevel%"
echo.
echo Repair process exit code: %repairCode%
pause
exit /b %repairCode%
