# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-window speaker timer for the CameraHAL weekly meeting. It is one PowerShell script (`CameraHAL_MeetingTimer.ps1`, WinForms) plus a `.bat` launcher. Target runtime is **Windows PowerShell 5.1** as shipped with Windows 10/11; nothing may require installing anything (no PowerShell 7 syntax such as `??`, `?.`, ternary, `&&`).

The user-facing README is in Korean. Code comments and commit messages are in English.

## Commands

There is no build or lint step.

- Test the time model (no Pester, nothing to install; exit code = number of failures):
  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\TimeModel.Tests.ps1
  ```
  It lifts every top-level function out of the script with the PowerShell parser (the window is never built), shadows `Get-Date` with a fake clock and swaps `$script:Sw` for a stopwatch double. So keep time logic in top-level functions, read the clock only through argument-less `Get-Date` and `$script:Sw`, and add a scenario there whenever the sharing rules change.

- Test native buttons, key events, settings and dock layouts:
  ```
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\tests\Ui.Tests.ps1
  ```
  Optional `-RenderDirectory <path>` writes preview PNGs. The test uses an isolated temporary configuration and injects native control events. Live desktop pointer gestures require a separate manual check.

- Run: double-click `CameraHAL_MeetingTimer.bat`, or from a shell:
  ```
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\CameraHAL_MeetingTimer.ps1
  ```
  `-STA` is required: WinForms needs a single-threaded apartment.
- Syntax check without launching the UI:
  ```
  $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$PWD\CameraHAL_MeetingTimer.ps1",[ref]$null,[ref]$e); $e
  ```
- Release zips come from `git archive`; `.gitattributes` marks repo housekeeping files and this file `export-ignore`, so the zip holds only the `.bat`, the `.ps1` and the README.

## Architecture (CameraHAL_MeetingTimer.ps1)

The script runs top to bottom and ends in `$form.ShowDialog()`. Sections are marked with `# ---------------- name ----------------` comments.

1. **Inline C# (`Add-Type`)**: `MtNative` (P/Invoke: `FlashWindowEx`, `SetProcessDPIAware`, `DwmSetWindowAttribute` for the dark title bar, foreground check, rounded-rect path), `MtCanvas` (double-buffered panel), `MtButton` (custom-painted native Button with keyboard focus, accessibility and dialog-button support). The main form intercepts Space to toggle the timer regardless of the focused button. Guarded by `if (-not ('MtButton' -as [type]))` because a type cannot be re-added in the same session.
2. **DPI scaling**: every pixel size goes through `S <px>`; fonts through `FK`/`FKM` (Korean) and `FN` (numerals). New layout code must use these, not raw pixels.
3. **State** lives in `$script:` variables: `People` (array of `New-Person` objects: `Used`, `Budget`, `Started`, alert flags `W2`/`W1`/`Zero`/`Over`), `Idx` (current speaker), `Sw` (one `Stopwatch` for the current speaker only), `End` (meeting end time), `Plan` (the first plan), `MinShare` (60 s), `ThemeName`, `BarEdge`.
4. **Time-sharing model** (the core logic):
   - A speaker's elapsed time = their committed `Used` + `Sw.Elapsed` if they are current. `Commit-Current` folds the stopwatch into `Used` and resets it; call it before changing `Idx`.
   - `Started = false` means "not locked yet". `Get-Preview` computes the share for unlocked speakers: (meeting time left − current locked speaker's remaining budget) / number of unlocked speakers from `Idx` onward, rounded down to whole seconds, with the `MinShare` floor before the meeting deadline. It returns zero after the deadline. The arithmetic lives in `Calc-Share`; `Get-Pending` supplies the reserved time and unlocked count. Unstarted previews follow the clock every second.
   - `Lock-Budget` fixes the current speaker's budget the moment they start. New starts after the deadline require confirmation and lock zero seconds, recording overtime without inventing extra time. `Started` distinguishes that locked zero from an unlocked share. The first call also records `Plan`, which the strip compares each share against. `Reset-Plan` recomputes it when end time or count changes.
   - `Test-Overbooked` is true when `MinShare` for everyone still to come no longer fits before the end time; the strip then shows `종료 시각 초과 예상`.
   - `Get-Phase` derives display level (`normal`/`notice`/`critical`/`over`) at 30% and 10% of the locked budget remaining, without fixed-second caps. `Get-ProgressColor` applies matching colors and pulse behavior to the main progress segments and horizontal/vertical presenter progress. Pausing freezes the pulse.
5. **Render loop**: a 200 ms `Windows.Forms.Timer` calls `Check-Alerts` then `Refresh-All`. It refreshes the strip, timer, button states and title. The two-row bottom band contains native start, next, undo, settings, presenter entry and theme buttons. All support Tab and Enter. The main next button is hidden while paused. Presenter next is disabled while paused to keep its controls in a stable position.
6. **Settings**: `Show-Settings` builds a light modal form with native controls. Its time-only picker uses `Resolve-EndTime` to preserve an unchanged deadline, including a past one. Edited past times mean tomorrow, with a visible label. Opening settings must preserve existing speaker count. Enter saves and Escape cancels. Finishing the last speaker returns directly to a fresh meeting.
7. **Undo** (button or Ctrl+Z): `Go-Next` and `Reset-Current` call `Save-Undo` first (a copy of `People`, `Idx`, `End`, `Plan`, and clock state). `Undo-Last` restores it and assigns time since the snapshot to the original speaker if running. One level, including a reset on speaker 1. Count/end-time changes clear it. Unrelated preference changes preserve it. Reset requires confirmation.
8. **Default end** (`Get-NextHour`): the next full hour, or the one after when it is less than 10 minutes away.
9. **Presenter bar** (entry button or `B`, `Set-BarMode`): borderless, always on top, bottom dock by default. `Get-BarBounds` centers a compact bar on the selected monitor edge inside WorkingArea. `Update-BarBounds` widens it at warning levels and avoids repositioning while dragging. Dragging empty stage space uses mouse capture, then `Dock-Bar` chooses the nearest edge on the pointer's screen. Top/bottom layouts are horizontal, left/right layouts vertical. `Paint-Bar` reserves space for native icon buttons with text accessible names and tooltips. `MtButton.Glyph` draws their play/pause, next/stop, undo and window symbols. Leaving restores `NormalBounds`, `NormalMin` and `TopMostPref`. `Bar` and `BarEdge` are persisted.

## Constraints to preserve

- **`config.json` is untrusted input.** `Load-Config` caps size at 4 KB, requires a JSON object, and type/range-checks every field. The speaker count is saved as `Speakers`; `Count` is still read for older configs. `Theme` accepts exactly `light` or `dark`; `Bar` accepts a JSON boolean; `BarEdge` accepts exactly `top`, `bottom`, `left` or `right`, defaulting to `bottom`.
- **Launcher security** (`.bat`): calls `conhost.exe` and `powershell.exe` by full `%SystemRoot%` path (avoids binary planting from the current folder), uses process-scoped `-ExecutionPolicy RemoteSigned`, and `conhost --headless` to hide the console. The script undoes the hidden-window launch in `form.add_Shown`.
- The minimum window width is measured, not fixed: `Get-MinClientWidth` takes the widest of the top strip, bottom row, header and coaching lines (`$script:Msg*`). Keep those texts short, and update the measurement when you add something to a row.
- README promises no network access, admin rights, registry writes, or downloads.
- `.bat`, `.ps1`, `.md` must keep CRLF line endings (enforced by `.gitattributes`). The `.ps1` starts with a UTF-8 BOM, which PowerShell 5.1 needs to read the Korean strings correctly; keep it.
- Visual style follows the HP-inspired DESIGN.md (getdesign.md/hp): white canvas, `#1a1a1a` ink, single accent `#024ad8`, 4px radius buttons, 1px hairlines. Colors are named by role (`Paper`, `Ink`, `Strip`, `Accent`, `Crit`, ...) in two tables, `$Themes.light` and `$Themes.dark` (dark follows getdesign.md/raycast); `$C` is the active one and `Set-Theme` swaps it. Never hardcode a hue name or hex in painting code: add a role to both tables. The settings dialog is pinned to `$Themes.light` (native controls cannot be themed) and passes that table to `New-Button`.
- Keyboard shortcuts (Space, N/→, R, Ctrl+Z, S, M, D, B, Esc in the bar) are documented in README; update it when they change.
