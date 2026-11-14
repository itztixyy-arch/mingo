@echo off
rem Build the Mingo ISO on Windows. Double-click, or run:  build.bat
rem Needs WSL with Ubuntu (one-time setup, admin PowerShell:  wsl --install -d Ubuntu).
rem Result: out\mingo.iso
setlocal
set DISTRO=Ubuntu
cd /d "%~dp0"

where wsl >nul 2>&1
if errorlevel 1 goto nowsl
wsl -d %DISTRO% -u root -- true >nul 2>&1
if errorlevel 1 goto nodistro

for /f "delims=" %%p in ('wsl -d %DISTRO% -u root -- wslpath -a "%~dp0."') do set "WP=%%p"
if not defined WP goto nopath

if /i "%~1"=="check" (
  echo WSL %DISTRO% ready. Project folder in WSL: %WP%
  exit /b 0
)

echo Building Mingo in WSL (%DISTRO%). This takes about 10 minutes and downloads about 1 GB.
echo.
wsl -d %DISTRO% -u root -- bash "%WP%/build.sh"
if errorlevel 1 (
  echo.
  echo BUILD FAILED - see the messages above.
  goto end
)
echo.
echo Done: %~dp0out\mingo.iso
echo Write it to a 4 GB+ USB stick with balenaEtcher or Rufus.
goto end

:nowsl
echo WSL is not installed. Open PowerShell as administrator and run:
echo     wsl --install -d %DISTRO%
echo Restart if asked, finish the Ubuntu setup, then run build.bat again.
goto end

:nodistro
echo WSL is installed but the %DISTRO% distribution is missing or not set up. In PowerShell run:
echo     wsl --install -d %DISTRO%
echo Finish the Ubuntu setup (create a user), then run build.bat again.
goto end

:nopath
echo Could not translate this folder to a WSL path: %~dp0
goto end

:end
if "%~1"=="" pause
endlocal
