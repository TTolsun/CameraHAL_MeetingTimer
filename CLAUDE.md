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

1. **Inline C# (`Add-Type`)**: `MtNative` (P/Invoke: `FlashWindowEx`, `SetProcessDPIAware`, `DwmSetWindowAttribute` for the dark title bar, foreground check, rounded-rect path), `MtCanvas` (double-buffered panel), `MtButton` (custom-painted, **non-selectable** button so Space/N always reach the form's `KeyDown` handler instead of activating a focused button). Guarded by `if (-not ('MtButton' -as [type]))` because a type cannot be re-added in the same session.
2. **DPI scaling**: every pixel size goes through `S <px>`; fonts through `FK`/`FKM` (Korean) and `FN` (numerals). New layout code must use these, not raw pixels.
3. **State** lives in `$script:` variables: `People` (array of `New-Person` objects: `Used`, `Budget`, alert flags `W2`/`W1`/`Zero`/`Over`), `Idx` (current speaker), `Sw` (one `Stopwatch` for the current speaker only), `End` (meeting end time), `Plan` (the first plan, see below), `MinShare` (60 s), `ThemeName`.
4. **Time-sharing model** (the core logic):
   - A speaker's elapsed time = their committed `Used` + `Sw.Elapsed` if they are current. `Commit-Current` folds the stopwatch into `Used` and resets it; call it before changing `Idx`.
   - `Budget = 0` means "not locked yet". `Get-Preview` computes the share for unlocked speakers: (meeting time left − current locked speaker's remaining budget) / number of unlocked speakers from `Idx` onward, rounded down to whole seconds, never below `MinShare`. The arithmetic lives in the pure `Calc-Share`; `Get-Pending` supplies the reserved time and the unlocked count. It is re-evaluated on every tick, so a speaker who has not started yet sees the share follow the clock second by second.
   - `Lock-Budget` fixes the current speaker's budget (min `MinShare`, 60 s) the moment they start. So overruns shrink only the shares of people who have not started. The first call also records `Plan` (the share before any minimum), which the top strip compares each speaker's share against; `Reset-Plan` recomputes it when the end time or speaker count changes.
   - `Test-Overbooked` is true when `MinShare` for everyone still to come no longer fits before the end time; the strip then shows `종료 시각 초과 예상`.
   - `Get-Phase` derives display level (`normal`/`notice`/`critical`/`over`) with thresholds that scale for short budgets (`min(120, 30%)`, `min(60, 15%)`).
5. **Render loop**: a 200 ms `Windows.Forms.Timer` calls `Check-Alerts` (sounds, one-shot flags, taskbar flash every 30 s of overtime when the window is in the background) then `Refresh-All`, which invalidates the custom-painted `$strip` (top bar: clock, plan change, end time), `$stage` (big timer), and updates button text, the visibility of the Next/finish button (shown only while the clock runs; Go-Next ignores N/→ otherwise) and the window title (title doubles as the taskbar label while minimized). `$band` (bottom row) paints the sun/moon/gear icons itself; they are not controls, so `Get-IconRects` and the `$band` mouse handlers hit-test them by hand.
6. **Dialogs**: `Show-Settings` builds a modal form inline. Finishing the last speaker has no summary dialog; `Go-Next` calls `Start-Over` to begin a fresh meeting.
7. **Undo** (Ctrl+Z): `Go-Next` and `Reset-Current` call `Save-Undo` first (a copy of `People`, `Idx`, `End`, `Plan`, and whether the clock ran). `Undo-Last` restores it and, if the clock was running, gives the time since then to the restored speaker. One level only; saving settings clears it. On speaker 1 it does nothing (`Test-UndoAllowed`), except to undo a finish (`Kind = finish`), which lands there. This replaces a confirmation dialog on purpose: nothing interrupts the meeting, but a mis-pressed N/→ is recoverable.
8. **Default end** (`Get-NextHour`): the next full hour, or the one after when it is less than 10 minutes away.

## Constraints to preserve

- **`config.json` is untrusted input.** `Load-Config` caps size at 4 KB, requires a JSON object, and type/range-checks every field, falling back to defaults. Keep that pattern for any new field. The speaker count is saved as `Speakers`, not `Count`, because `.Count` is a built-in PowerShell property; `Count` is still read for older configs. `Theme` is accepted only as exactly `light` or `dark`.
- **Launcher security** (`.bat`): calls `conhost.exe` and `powershell.exe` by full `%SystemRoot%` path (avoids binary planting from the current folder), uses process-scoped `-ExecutionPolicy RemoteSigned`, and `conhost --headless` to hide the console. The script undoes the hidden-window launch in `form.add_Shown`.
- The minimum window width is measured, not fixed: `Get-MinClientWidth` takes the widest of the top strip, bottom row, header and coaching lines (`$script:Msg*`). Keep those texts short, and update the measurement when you add something to a row.
- README promises no network access, admin rights, registry writes, or downloads.
- `.bat`, `.ps1`, `.md` must keep CRLF line endings (enforced by `.gitattributes`). The `.ps1` starts with a UTF-8 BOM, which PowerShell 5.1 needs to read the Korean strings correctly; keep it.
- Visual style follows the HP-inspired DESIGN.md (getdesign.md/hp): white canvas, `#1a1a1a` ink, single accent `#024ad8`, 4px radius buttons, 1px hairlines. Colors are named by role (`Paper`, `Ink`, `Strip`, `Accent`, `Crit`, ...) in two tables, `$Themes.light` and `$Themes.dark` (dark follows getdesign.md/raycast); `$C` is the active one and `Set-Theme` swaps it. Never hardcode a hue name or hex in painting code: add a role to both tables. The settings dialog is pinned to `$Themes.light` (native controls cannot be themed) and passes that table to `New-Button`.
- Keyboard shortcuts (Space, N/→, R, Ctrl+Z, S, M, D) are documented in README; update it when they change.
