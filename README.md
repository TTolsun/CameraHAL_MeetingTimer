# CameraHAL_MeetingTimer

A small always-on-top speaker timer for the weekly CameraHAL meeting. It splits
the remaining meeting time evenly across the speakers and makes overruns
visible to everyone.

Runs on Windows 10/11 with the built-in Windows PowerShell 5.1. Nothing to install.

## Run

Double-click `CameraHAL_MeetingTimer.bat`.

The window opens in the bottom-right corner of the screen.

## How it works

- **Meeting end** defaults to the next full hour after launch
  (start at 14:05, end at 15:00). Change it in **Settings**.
- **Speakers**: enter only the number of speakers. The time left until the
  meeting end is split evenly among everyone who has not started yet.
- Each speaker's share is **locked when they start**. If someone runs over,
  the people still waiting get less time.
- Display escalates as time runs out: black digits, then blue near the end,
  then red, then a flashing red screen with the overtime (`+01:20`).
- If time runs out while the window is minimized or behind other windows,
  its **taskbar button flashes** until the window is brought back.
- After the last speaker, **Finish** shows each speaker's used / allotted /
  overtime and can copy the result to the clipboard.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `Space` | Start / pause |
| `N` or `→` | Next speaker |
| `P` or `←` | Previous speaker |
| `R` | Reset the current speaker's time |
| `S` | Settings |
| `M` | Sound on/off |

## Files

| File | Purpose |
|---|---|
| `CameraHAL_MeetingTimer.bat` | Launcher (hides the PowerShell console) |
| `CameraHAL_MeetingTimer.ps1` | The timer (WinForms UI) |
| `config.json` | Saved settings, created on first run (not tracked by git) |

## Security notes

- No network access, no admin rights, no registry changes, no downloads.
- The launcher calls `conhost.exe` and `powershell.exe` by full system path,
  so a planted executable in the same folder cannot be picked up instead.
- PowerShell runs with `-ExecutionPolicy RemoteSigned` for this process only.
  A copy received by email or download is blocked until it is signed or
  explicitly unblocked after review:

  ```powershell
  Unblock-File .\CameraHAL_MeetingTimer.ps1
  ```

- `config.json` is read as untrusted data: size-capped, JSON object only,
  every field type- and range-checked, defaults on anything unexpected.

## Design

Visual style follows the HP-inspired DESIGN.md at
[getdesign.md/hp](https://getdesign.md/hp/design-md): white canvas, `#1a1a1a`
ink, a single `#024ad8` accent, 4px buttons, 1px hairlines.
