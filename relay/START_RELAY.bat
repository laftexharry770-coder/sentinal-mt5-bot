@echo off
setlocal enabledelayedexpansion
title Sentinal Copier Relay
cd /d "%~dp0"

echo.
echo  Starting the Sentinal Copier relay...
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

REM ---- key: reuse the saved one, or make one the first time ----------
if not exist relay_key.txt (
  %PY% -c "import secrets;open('relay_key.txt','w').write(secrets.token_urlsafe(24))"
  echo  A new relay key was generated and saved in relay_key.txt
  echo.
)
set /p KEY=<relay_key.txt

REM ---- this PC's LAN address, for the other machines ------------------
set IP=
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4"') do (
  if not defined IP set IP=%%a
)
set IP=%IP: =%
if not defined IP set IP=127.0.0.1

echo  ============================================================
echo   Sentinal Copier Relay
echo  ============================================================
echo.
echo   Control panel:  http://%IP%:8787/
echo   Relay key:      %KEY%
echo.
echo   Paste these into the MASTER and every SLAVE EA:
echo.
echo     InpTransport = TRANSPORT_HTTP
echo     InpRelayUrl  = http://%IP%:8787
echo     InpRelayKey  = %KEY%
echo.
echo   Then in EACH terminal:
echo     Tools ^> Options ^> Expert Advisors
echo     tick "Allow WebRequest for listed URL"
echo     add   http://%IP%:8787
echo.
echo   Leave this window open. Closing it stops the relay.
echo  ============================================================
echo.

%PY% copier_relay.py --key %KEY% --port 8787

echo.
echo  The relay stopped. Scroll up for the reason.
pause
