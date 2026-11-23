@echo off
rem Double-click to put the Tama Bridge firmware on an ESP32 plugged in with USB.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash.ps1"
