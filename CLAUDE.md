# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-window speaker timer for the CameraHAL weekly meeting. It is one PowerShell script (`CameraHAL_MeetingTimer.ps1`, WinForms) plus a `.bat` launcher. Target runtime is **Windows PowerShell 5.1** as shipped with Windows 10/11; nothing may require installing anything (no PowerShell 7 syntax such as `??`, `?.`, ternary, `&&`).

The user-facing README is in Korean. Code comments and commit messages are in English.

## Commands

There is no build, lint, or test suite.

- Run: double-click `CameraHAL_MeetingTimer.bat`, or from a shell:
  ```
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\CameraHAL_MeetingTimer.ps1
  ```
  `-STA` keeps the WinForms runtime in its supported apartment mode.
- Syntax check without launching the UI:
  ```
  $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$PWD\CameraHAL_MeetingTimer.ps1",[ref]$null,[ref]$e); $e
  ```
- Release zips come from `git archive`; `.gitattributes` marks repo housekeeping files `export-ignore`.

## Architecture (CameraHAL_MeetingTimer.ps1)

The script runs top to bottom and ends in `$form.ShowDialog()`. Sections are marked with `# ---------------- name ----------------` comments.

1. **Inline C# (`Add-Type`)**: `MtNative` (P/Invoke: `FlashWindowEx`, `SetProcessDPIAware`, foreground check, rounded-rect path), `MtCanvas` (double-buffered panel), `MtButton` (custom-painted native Button with keyboard focus, accessibility, and dialog-button support). The main form intercepts Space to toggle the timer regardless of the focused button. Guarded by `if (-not ('MtButton' -as [type]))` because a type cannot be re-added in the same session.
2. **DPI scaling**: every pixel size goes through `S <px>`; fonts through `FK`/`FKM` (Korean) and `FN` (numerals). New layout code must use these, not raw pixels.
3. **State** lives in `$script:` variables: `People` (array of `New-Person` objects: `Used`, `Budget`, `Started`, alert flags `W2`/`W1`/`Zero`/`Over`), `Idx` (current speaker), `Sw` (one `Stopwatch` for the current speaker only), `End` (meeting end time), `UndoSwitch` (one transition snapshot).
4. **Time-sharing model** (the core logic):
   - A speaker's elapsed time = their committed `Used` + `Sw.Elapsed` if they are current. `Commit-Current` folds the stopwatch into `Used` and resets it; call it before changing `Idx`.
   - `Started = false` means "not locked yet". `Get-Preview` computes the share for unlocked speakers: (meeting time left − current locked speaker's remaining budget) / number of unlocked speakers from `Idx` onward, rounded down to 10 s.
   - `Lock-Budget` fixes the current speaker's budget the moment they start. A zero-second budget remains locked, so continuing after the deadline records overtime without creating extra time. New starts with no allocation require confirmation.
   - `Get-Phase` derives display level (`normal`/`notice`/`critical`/`over`) with thresholds that scale for short budgets (`min(120, 30%)`, `min(60, 15%)`).
5. **Render loop**: a 200 ms `Windows.Forms.Timer` calls `Check-Alerts` (sounds, one-shot flags, taskbar flash every 30 s of overtime when the window is in the background) then `Refresh-All`, which invalidates the custom-painted `$strip` (top bar), `$stage` (big timer), and updates button text and the window title (title doubles as the taskbar label while minimized).
6. **Settings**: `Show-Settings` builds a modal form inline. Settings uses a time-only picker and preserves an unchanged deadline. An edited time earlier than now means tomorrow and is labeled accordingly. Finishing the last speaker returns to a fresh meeting. Undo restores the most recent transition, finish, or reset, including its deadline and clock state.

## Constraints to preserve

- **`config.json` is untrusted input.** `Load-Config` caps size at 4 KB, requires a JSON object, and type/range-checks every field, falling back to defaults. Keep that pattern for any new field. The speaker count is saved as `Speakers`, not `Count`, because `.Count` is a built-in PowerShell property; `Count` is still read for older configs.
- **Launcher security** (`.bat`): calls `conhost.exe` and `powershell.exe` by full `%SystemRoot%` path (avoids binary planting from the current folder), uses process-scoped `-ExecutionPolicy RemoteSigned`, and `conhost --headless` to hide the console. The script undoes the hidden-window launch in `form.add_Shown`.
- README promises no network access, admin rights, registry writes, or downloads.
- `.bat`, `.ps1`, `.md` must keep CRLF line endings (enforced by `.gitattributes`). The `.ps1` starts with a UTF-8 BOM, which PowerShell 5.1 needs to read the Korean strings correctly; keep it.
- Visual style follows the HP-inspired DESIGN.md (getdesign.md/hp): white canvas, `#1a1a1a` ink, single accent `#024ad8`, 4px radius buttons, 1px hairlines. Colors come from the `$C` palette.
- Keyboard shortcuts (Space, N/→, Ctrl+Z, R, S, M, and dialog shortcuts) are documented in README; update it when they change.
