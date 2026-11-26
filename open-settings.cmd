@echo off
rem ============================================================
rem  DSH Task Alert - open the settings window
rem
rem  Why this file exists:
rem    The settings window lives inside the resident PowerShell helper
rem    process. That helper is normally started by the DSH plugin, but if
rem    it is not running yet, or the global hotkey is taken by another
rem    program, double-clicking this file opens settings directly.
rem
rem  Note: keep this file pure ASCII. cmd.exe reads batch files with the
rem  OEM code page; non-ASCII bytes inside a .cmd are parsed as garbage
rem  commands (that is what "garbled text is not recognized" means).
rem ============================================================
setlocal
set "PS1=%~dp0assets\toast.ps1"
set "CFG=%USERPROFILE%\.dsh\task-alert\settings.json"

if not exist "%PS1%" (
  echo [ERROR] helper script not found:
  echo         %PS1%
  pause
  exit /b 1
)

start "" /min pwsh.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%PS1%" -SettingsPath "%CFG%" -SettingsOnly
