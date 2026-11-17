@echo off
rem Full system paths: cmd searches the current folder before PATH, so a bare
rem "powershell.exe" could pick up a planted executable sitting next to this file.
rem RemoteSigned (this process only): local scripts run, but a copy that arrived
rem from the internet/email must be signed or explicitly unblocked first.
rem conhost --headless keeps PowerShell's console (and the Windows Terminal tab) out of sight.
start "" "%SystemRoot%\System32\conhost.exe" --headless "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File "%~dp0CameraHAL_MeetingTimer.ps1"
