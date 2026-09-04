@echo off
setlocal enabledelayedexpansion
title Sentinal Copier Relay (public)
cd /d "%~dp0"

echo.
echo  Starting the Sentinal Copier relay on a public address...
echo.

REM ---- find a Python interpreter -------------------------------------
set PY=
where py >nul 2>&1 && set PY=py
if not defined PY where python >nul 2>&1 && set PY=python
if not defined PY where python3 >nul 2>&1 && set PY=python3

if not defined PY (
  echo  ============================================================
  echo   Python is not installed on this PC.
  echo  ============================================================
  echo.
  echo   1. Download it from   https://www.python.org/downloads/
  echo   2. On the FIRST installer screen, tick
  echo        "Add python.exe to PATH"
  echo      That box is easy to miss and nothing works without it.
  echo   3. Run this file again.
  echo.
  pause
  exit /b 1
)

REM ---- cloudflared: one file, no account ------------------------------
if not exist cloudflared.exe (
  where cloudflared >nul 2>&1
  if errorlevel 1 (
    echo  ============================================================
    echo   cloudflared is missing.
    echo  ============================================================
    echo.
    echo   It is a single file and needs no account:
    echo.
    echo     https://github.com/cloudflare/cloudflared/releases/latest
    echo.
    echo   1. Download  cloudflared-windows-amd64.exe
    echo   2. Rename it to  cloudflared.exe
    echo   3. Put it in THIS folder, next to this file
    echo   4. Run this file again.
    echo.
    pause
    exit /b 1
  )
)

%PY% start_public.py

echo.
echo  The relay stopped. Scroll up for the reason.
pause
