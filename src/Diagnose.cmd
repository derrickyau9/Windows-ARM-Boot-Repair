@echo off
setlocal
title Windows ARM Boot Repair - Diagnose
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-ArmBoot.ps1" -Mode Diagnose %*
set "repairCode=%errorlevel%"
echo.
echo Diagnosis exit code: %repairCode%
pause
exit /b %repairCode%
