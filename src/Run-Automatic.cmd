@echo off
setlocal
title Windows ARM Boot Repair - Automatic
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-ArmBoot.ps1" -Mode Automatic %*
exit /b %errorlevel%
