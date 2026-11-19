@echo off
rem LiquidHUD launcher - just double-click this file
start "" /min powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LiquidHUD.ps1"
