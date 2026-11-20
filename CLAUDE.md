# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-window speaker timer for weekly meetings. The Windows app in `windows/` contains its WinForms entry point, time model, and BAT launcher. The Chrome extension lives in `chrome-extension/` and loads its own time model before the UI. Target runtime is **Windows PowerShell 5.1** as shipped with Windows 10/11; nothing may require installing anything (no PowerShell 7 syntax such as `??`, `?.`, ternary, `&&`).

The user-facing README is in Korean. Code comments and commit messages are in English.

## Commands

The runtime sources require no compilation.

- Test the time model (no Pester, nothing to install; exit code = number of failures):
  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\TimeModel.Tests.ps1
  ```
  It loads `windows/TimeModel.ps1` and lifts the top-level functions from the entry point with the PowerShell parser (the window is never built), shadows `Get-Date` with a fake clock and swaps `$script:Sw` for a stopwatch double. So keep time logic in top-level functions, read the clock only through argument-less `Get-Date` and `$script:Sw`, and add a scenario there whenever the sharing rules change.

- Test native buttons, key events, settings and presenter bar placement:
  ```
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\tests\Ui.Tests.ps1
  ```
  Optional `-RenderDirectory <path>` writes preview PNGs. The test uses an isolated temporary configuration and injects native control events. Live desktop pointer gestures require a separate manual check.

- Run: double-click `windows/MeetingTimer.bat`, or from a shell:
  ```
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\windows\MeetingTimer.ps1
  ```
  `-STA` is required: WinForms needs a single-threaded apartment.
- Syntax check without launching the UI:
  ```
  $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$PWD\windows\MeetingTimer.ps1",[ref]$null,[ref]$e); $e
  ```
- Run `scripts/Build-Release.ps1` to package the BAT and PowerShell script together and the unpacked `chrome-extension/` separately. A version tag prepares a draft release with both tested ZIPs.

## Architecture (MeetingTimer.ps1)

The script runs top to bottom and ends in `$form.ShowDialog()`. Sections are marked with `# ---------------- name ----------------` comments.

1. **Inline C# (`Add-Type`)**: `MtNative` (`SetProcessDPIAware`, `DwmSetWindowAttribute` for the dark title bar, rounded-rect path), `MtCanvas` (double-buffered panel), `MtButton` (custom-painted native Button with keyboard focus, accessibility and dialog-button support). The main form intercepts Space to toggle the timer regardless of the focused button. Guarded by `if (-not ('MtButton' -as [type]))` because a type cannot be re-added in the same session.
2. **DPI scaling**: every pixel size goes through `S <px>`; fonts through `FK`/`FKM` (Korean) and `FN` (numerals). New layout code must use these, not raw pixels.
3. **State** lives in `$script:` variables: `People` (array of `New-Person` objects: `Used`, `Budget`, `Started`), `Idx` (current speaker), `Sw` (one `Stopwatch` for the current speaker only), `End` (meeting end time), `Plan` (the first plan), `MinShare` (60 s), `ThemeName`, `BarMode`.
4. **Time-sharing model** (the core logic):
   - A speaker's elapsed time = their committed `Used` + `Sw.Elapsed` if they are current. `Commit-Current` folds the stopwatch into `Used` and resets it; call it before changing `Idx`.
   - `Started = false` means "not locked yet". `Get-Preview` computes the share for unlocked speakers: (meeting time left − current locked speaker's remaining budget) / number of unlocked speakers from `Idx` onward, rounded down to whole seconds, with the `MinShare` floor before the meeting deadline. It returns zero after the deadline. The arithmetic lives in `Calc-Share`; `Get-Pending` supplies the reserved time and unlocked count. Unstarted previews follow the clock every second.
   - `Lock-Budget` fixes the current speaker's budget the moment they start. New starts after the deadline require confirmation and lock zero seconds, recording overtime without inventing extra time. `Started` distinguishes that locked zero from an unlocked share. The first call also records `Plan`, which the strip compares each share against. Saving a changed end time or count starts a fresh meeting with an unlocked plan.
   - `Test-Overbooked` is true when `MinShare` for everyone still to come no longer fits before the end time; the strip then shows `종료 시각 초과 예상`.
   - `Get-Phase` derives the remaining time, display state and whether the overtime digits have reached the 15-second highlight threshold. Both layouts show factual remaining-time text once 30% of the locked budget or one minute remains and keep time indicators steady.
5. **Render loop**: a `Windows.Forms.Timer` calls `Refresh-All` at 200 ms intervals to refresh the strip, timer, button states and title. `Get-SpeakerWindow` lays out up to five consecutive numbers in the bar and `Paint-BarSpeakers` highlights the current speaker. The two-row bottom band contains native start, next, undo, settings, presenter entry and theme buttons. All support Tab and Enter. The main next button is hidden while paused. Presenter next is disabled while paused to keep its controls in a stable position.
6. **Settings**: `Show-Settings` builds a light modal form with native controls. Its time-only picker uses `Resolve-EndTime` to preserve an unchanged deadline, including a past one. Edited past times mean tomorrow, with a visible label. Draft edits preserve the live meeting. A changed count or deadline must fit the one-minute minimum for every speaker in the new meeting. Saving a valid change resets the timer and all speaker records, while a preference-only save preserves the session. Enter saves and Escape cancels. Finishing the last speaker returns directly to a fresh meeting.
7. **Undo** (button or Ctrl+Z): `Go-Next` and `Reset-Current` call `Save-Undo` first (a copy of `People`, `Idx`, `End`, `Plan`, and clock state). `Undo-Last` restores it and assigns time since the snapshot to the original speaker if running. One level, including a reset on speaker 1. Count/end-time changes clear it. Unrelated preference changes preserve it. Reset requires confirmation.
8. **Default end** (`Get-NextHour`): the next full hour, or the one after when it is less than 10 minutes away.
9. **Presenter bar** (entry button or `B`, `Set-BarMode`): a borderless, always-on-top horizontal bar. Entering keeps the normal window's location and width. Narrow windows use two rows. Dragging empty stage space uses mouse capture and keeps the final location on release. `Paint-Bar` reserves space for native icon buttons with accessible text names and no hover tooltips. `MtButton.Glyph` draws their play/pause, next/stop, undo and window symbols. Leaving restores `NormalBounds`, `NormalMin` and `TopMostPref`. The `Bar` setting restores the mode at startup. Legacy `BarEdge` values are ignored.

## Constraints to preserve

- **`config.json` is untrusted input.** `Load-Config` caps size at 4 KB, requires a JSON object, and type/range-checks the fields it reads. The speaker count is saved as `Speakers`. `Count` is still read for older configs. `Theme` accepts exactly `light` or `dark`. `Bar` accepts a JSON boolean.
- **Launcher security** (`.bat`): calls `conhost.exe` and `powershell.exe` by full `%SystemRoot%` path (avoids binary planting from the current folder), uses process-scoped `-ExecutionPolicy RemoteSigned`, and `conhost --headless` to hide the console. The script undoes the hidden-window launch in `form.add_Shown`.
- The minimum window width is measured, not fixed: `Get-MinClientWidth` takes the widest of the top strip, bottom row, header and status lines (`$script:Msg*`). Keep those texts short, and update the measurement when you add something to a row.
- README promises no network access, admin rights, registry writes, or downloads.
- `.bat`, `.ps1`, `.md` must keep CRLF line endings (enforced by `.gitattributes`). The `.ps1` starts with a UTF-8 BOM, which PowerShell 5.1 needs to read the Korean strings correctly; keep it.
- Visual style follows the HP-inspired DESIGN.md (getdesign.md/hp): white canvas, `#1a1a1a` ink, single accent `#024ad8`, 4px radius buttons, 1px hairlines. Colors are named by role (`Paper`, `Ink`, `Strip`, `Accent`, `Crit`, ...) in two tables, `$Themes.light` and `$Themes.dark` (dark follows getdesign.md/raycast); `$C` is the active one and `Set-Theme` swaps it. Never hardcode a hue name or hex in painting code: add a role to both tables. The settings dialog is pinned to `$Themes.light` (native controls cannot be themed) and passes that table to `New-Button`.
- Keyboard shortcuts (Space, N/→, R, Ctrl+Z, S, D, B, Esc in the bar) are documented in README; update it when they change.
