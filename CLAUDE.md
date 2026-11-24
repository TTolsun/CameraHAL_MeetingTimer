# CLAUDE.md

Developer guide for the Windows timer and Chrome extension.

## What this is

A single-window speaker timer for weekly meetings. The Windows app in `windows/` contains its WinForms entry point, time model, and BAT launcher. The Chrome extension lives in `chrome-extension/` and loads its own time model before the UI. Target runtime is **Windows PowerShell 5.1** as shipped with Windows 10/11; nothing may require installing anything (no PowerShell 7 syntax such as `??`, `?.`, ternary, `&&`).

The user-facing README is in Korean. Code comments and commit messages are in English.

| Task | Windows | Chrome |
|---|---|---|
| Change allocation | [TimeModel.ps1](windows/TimeModel.ps1) (`Calc-Share`, `Lock-Budget`) | [time-model.js](chrome-extension/time-model.js) (`allocation`, `startSpeaker`) |
| Find regression tests | [TimeModel.Tests.ps1](tests/TimeModel.Tests.ps1) and [Ui.Tests.ps1](tests/Ui.Tests.ps1) | [chrome-model.test.mjs](tests/chrome-model.test.mjs) and [chrome-ui.test.mjs](tests/chrome-ui.test.mjs) |
| Edit the presenter bar | [MeetingTimer.ps1](windows/MeetingTimer.ps1) (`Set-BarMode`, `Paint-Bar`) | [timer.js](chrome-extension/timer.js) (`openBar`, `render`) and [timer.css](chrome-extension/timer.css) |

## Commands

The runtime sources require no compilation.

- Test the Windows time model with stock PowerShell 5.1. The exit code is the number of failed checks.
  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\TimeModel.Tests.ps1
  ```
  The test loads `windows/TimeModel.ps1` directly. A fake `Get-Date` and a stopwatch double share one clock. Keep transition approval in scriptblocks that return a Boolean so tests can verify both outcomes.

- Test native buttons, key events, settings and presenter bar placement.
  ```
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\tests\Ui.Tests.ps1
  ```
  Optional `-RenderDirectory <path>` writes preview PNGs. The test uses an isolated temporary configuration and injects native control events. Live desktop pointer gestures require a separate manual check.

- Test the Chrome model with Node.js 24.
  ```
  node --test .\tests\chrome-model.test.mjs
  ```
  The test loads `chrome-extension/time-model.js` directly. The extension runs it as a browser script.

- Test the Chrome popup and presenter bar. Point `CHROME_FOR_TESTING` to the Chrome for Testing executable.
  ```
  node --test .\tests\chrome-ui.test.mjs
  ```
  The popup assertions freeze the wall clock while driving the normal controls. The presenter bar checks use a live browser window.

- Double-click `windows/MeetingTimer.bat` or run it from a shell.
  ```
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\windows\MeetingTimer.ps1
  ```
  `-STA` is required: WinForms needs a single-threaded apartment.
- Parse the WinForms entry point without launching it.
  ```
  $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$PWD\windows\MeetingTimer.ps1",[ref]$null,[ref]$e); $e
  ```
- Run `scripts/Build-Release.ps1` to package the Windows launcher, UI and model together and the unpacked `chrome-extension/` separately. A version tag prepares a draft release with both tested ZIPs.

## Windows architecture

`MeetingTimer.ps1` initializes WinForms, loads `TimeModel.ps1`, and opens the form with `$form.ShowDialog()`. Button and shortcut handlers pass modal confirmation callbacks into the model and refresh the form after a transition succeeds.

1. **Inline C# (`Add-Type`)**: `MtNative` (`SetProcessDPIAware`, `DwmSetWindowAttribute` for the dark title bar, rounded-rect path), `MtCanvas` (double-buffered panel), `MtButton` (custom-painted native Button with keyboard focus, accessibility and dialog-button support). The main form intercepts Space to toggle the timer regardless of the focused button. Guarded by `if (-not ('MtButton' -as [type]))` because a type cannot be re-added in the same session.
2. **DPI scaling**: every pixel size goes through `S <px>`; fonts through `FK`/`FKM` (Korean) and `FN` (numerals). New layout code must use these, not raw pixels.
3. **State** lives in `$script:` variables: `People` (array of `New-Person` objects: `Used`, `Budget`, `Started`), `Idx` (current speaker), `Sw` (one `Stopwatch` for the current speaker only), `End` (meeting end time), `Plan` (the first plan), `MinShare` (60 s), `ThemeName`, `BarMode`.
4. **Time-sharing model** (the core logic):
   - A speaker's elapsed time is their committed `Used` plus `Sw.Elapsed` while they are current. `Move-ToNextSpeaker` saves elapsed time and resets the stopwatch before changing `Idx`.
   - `Started = false` means "not locked yet". `Get-Preview` computes the share for unlocked speakers: (meeting time left − current locked speaker's remaining budget) / number of unlocked speakers from `Idx` onward, rounded down to whole seconds, with the `MinShare` floor before the meeting deadline. It returns zero after the deadline. The arithmetic lives in `Calc-Share`; `Get-Pending` supplies the reserved time and unlocked count. Unstarted previews follow the clock every second.
   - `Lock-Budget` fixes the current speaker's budget the moment they start. New starts after the deadline require confirmation and lock zero seconds, recording overtime without inventing extra time. `Started` distinguishes that locked zero from an unlocked share. The first start also records `Plan` from the even split before applying the minimum. With 90 seconds and two speakers, Windows records a 45-second plan and allocates 60 seconds. Saving a changed end time or count starts a fresh meeting with an unlocked plan.
   - `Test-Overbooked` is true when the remaining speakers cannot each get `MinShare` before the deadline. The strip shows `May run past end time` or `May run over` depending on the available width.
   - `Get-Phase` derives the remaining time, display state and whether the overtime digits have reached the 15-second highlight threshold. Both layouts show factual remaining-time text once 30% of the locked budget or one minute remains and keep time indicators steady.
5. **Render loop**: a `Windows.Forms.Timer` calls `Refresh-All` at 200 ms intervals to refresh the strip, timer, button states and title. `Get-SpeakerWindow` lays out up to five consecutive numbers in the bar and `Paint-BarSpeakers` highlights the current speaker. The two-row bottom band contains native start, next, undo, settings and theme buttons. All support Tab and Enter. The main next button is hidden while paused. Presenter next is disabled while paused to keep its controls in a stable position.
6. **Settings**: `Show-Settings` builds a light modal form with native controls. Its time-only picker uses `Resolve-EndTime` to preserve an unchanged deadline, including a past one. Edited past times mean tomorrow, with a visible label. Draft edits preserve the live meeting. A changed count or deadline must fit the one-minute minimum for every speaker in the new meeting. Saving a valid change resets the timer and all speaker records, while a preference-only save preserves the session. Enter saves and Escape cancels. Finishing the last speaker returns directly to a fresh meeting.
7. **Undo** (button or Ctrl+Z): `Move-ToNextSpeaker` and `Clear-CurrentSpeaker` call `Save-Undo` first (a copy of `People`, `Idx`, `End`, `Plan`, and clock state). `Restore-PreviousTurn` restores it and assigns time since the snapshot to the original speaker if running. One level, including a reset on speaker 1. Count/end-time changes clear it. Unrelated preference changes preserve it. Reset requires confirmation.
8. **Default end** (`Get-NextHour`): the next full hour, or the one after when it is less than 10 minutes away.
9. **Presenter bar** (title-bar minimize or `B`, `Set-BarMode`): an always-on-top horizontal tool window. Entering keeps the normal window's location and width. Narrow windows use two rows. Dragging empty stage space uses mouse capture and keeps the final location on release. `Paint-Bar` reserves space for native icon buttons with accessible text names and no hover tooltips. `MtButton.Glyph` draws their play/pause, next/stop and undo symbols. Maximizing the bar restores `NormalSize`, `NormalMin` and `TopMostPref` at the bar's current location. Closing the bar exits the timer. The `Bar` setting restores the mode at startup. Legacy `BarEdge` values are ignored.

## Chrome architecture

`index.html` loads `time-model.js` before `timer.js`. The model uses milliseconds. `startSpeaker` locks the allocation, records the first plan and starts the clock. Chrome records the first allocation as its plan. With 90 seconds and two speakers, the plan and allocation are both 60 seconds. `timer.js` owns confirmations, settings, session storage and rendering in the popup and presenter bar.

## Constraints to preserve

- **`config.json` is untrusted input.** `Load-Config` caps size at 4 KB, requires a JSON object, and type/range-checks the fields it reads. The speaker count is saved as `Speakers`. `Count` is still read for older configs. `Theme` accepts exactly `light` or `dark`. `Bar` accepts a JSON boolean.
- **Launcher security** (`.bat`): calls `conhost.exe` and `powershell.exe` by full `%SystemRoot%` path (avoids binary planting from the current folder), uses process-scoped `-ExecutionPolicy RemoteSigned`, and `conhost --headless` to hide the console. The script undoes the hidden-window launch in `form.add_Shown`.
- The minimum window width is measured, not fixed: `Get-MinClientWidth` takes the widest of the top strip, bottom row, header and status lines (`$script:Msg*`). Keep those texts short, and update the measurement when you add something to a row.
- README promises no network access, admin rights, registry writes, or downloads.
- `.bat`, `.ps1`, `.md` must keep CRLF line endings (enforced by `.gitattributes`). The `.ps1` starts with a UTF-8 BOM, which PowerShell 5.1 needs to read the Korean strings correctly; keep it.
- Visual style follows the HP-inspired DESIGN.md (getdesign.md/hp): white canvas, `#1a1a1a` ink, single accent `#024ad8`, 4px radius buttons, 1px hairlines. Colors are named by role (`Paper`, `Ink`, `Strip`, `Accent`, `Crit`, ...) in two tables, `$Themes.light` and `$Themes.dark` (dark follows getdesign.md/raycast); `$C` is the active one and `Set-Theme` swaps it. Never hardcode a hue name or hex in painting code: add a role to both tables. The settings dialog is pinned to `$Themes.light` (native controls cannot be themed) and passes that table to `New-Button`.
- Keyboard shortcuts (Space, N/→, R, Ctrl+Z, S, D, B, Esc in the bar) are documented in README; update it when they change.
