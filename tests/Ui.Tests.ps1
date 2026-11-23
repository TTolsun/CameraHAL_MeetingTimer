# Native control and layout regressions. Run with Windows PowerShell 5.1 -STA.
param([string]$RenderDirectory = '')
$ErrorActionPreference = 'Stop'
if ($RenderDirectory) { [void][IO.Directory]::CreateDirectory($RenderDirectory) }
$repo = Split-Path -Parent $PSScriptRoot
$windows = Join-Path $repo 'windows'
$source = [IO.File]::ReadAllText((Join-Path $windows 'MeetingTimer.ps1'))
$bootstrap = $source.Substring(0, $source.IndexOf('# ---------------- start ----------------'))
$bootstrap = $bootstrap.Replace('$dlg.ShowDialog($form)', '(Invoke-TestDialog $dlg)')
# Feed screen coordinates to the real handlers without moving the desktop cursor.
$bootstrap = $bootstrap.Replace('[Windows.Forms.Cursor]::Position', '$script:TestCursorPosition')
$bootstrap = $bootstrap.Replace('$notice.ShowDialog($script:SetDlg)', '(Invoke-TestNotice $notice)')
$testDirectory = Join-Path $repo ('.ui-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$bootstrapPath = Join-Path $testDirectory 'Application.ps1'
[IO.File]::WriteAllText($bootstrapPath, $bootstrap, (New-Object Text.UTF8Encoding $true))
$modelPath = Join-Path $testDirectory 'TimeModel.ps1'
Copy-Item -LiteralPath (Join-Path $windows 'TimeModel.ps1') -Destination $modelPath
. $bootstrapPath
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Reflection;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public static class TimerTestInput {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")]
    static extern IntPtr GetDlgItem(IntPtr hwnd, int id);
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")]
    static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr wparam, IntPtr lparam);
    public static void AnswerConfirmation(bool yes) {
        var timer = new Timer { Interval = 50 };
        timer.Tick += delegate {
            IntPtr dialog = FindWindow("#32770", "New meeting");
            uint pid;
            GetWindowThreadProcessId(dialog, out pid);
            if (pid != System.Diagnostics.Process.GetCurrentProcess().Id) return;
            timer.Stop(); timer.Dispose();
            PostMessage(GetDlgItem(dialog, yes ? 6 : 7), 0x00F5, IntPtr.Zero, IntPtr.Zero);
        };
        timer.Start();
    }
    public static KeyEventArgs Key(Control control, Keys key) {
        KeyEventArgs args = new KeyEventArgs(key);
        typeof(Control).GetMethod("OnKeyDown", BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(control, new object[] { args });
        return args;
    }
    public static bool SendKey(Control control, Keys key) {
        Message msg = Message.Create(control.Handle, 0x0100, (IntPtr)(int)key, IntPtr.Zero);
        PreProcessControlState state = control.PreProcessControlMessage(ref msg);
        if (key != Keys.Right) return state == PreProcessControlState.MessageProcessed;
        if (state != PreProcessControlState.MessageNeeded) return false;

        // Reproduce the WinForms dispatch step after preprocessing identifies an input key.
        return (bool)typeof(Control).GetMethod("ProcessKeyMessage", BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(control, new object[] { msg });
    }
    public static void DialogKey(Form form, Keys key) {
        typeof(Form).GetMethod("ProcessDialogKey", BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(form, new object[] { key });
    }
    public static void Paint(Control control) {
        using (Bitmap bitmap = new Bitmap(control.Width, control.Height))
        using (Graphics graphics = Graphics.FromImage(bitmap))
        using (PaintEventArgs args = new PaintEventArgs(graphics, control.ClientRectangle)) {
            typeof(Control).GetMethod("OnPaint", BindingFlags.Instance | BindingFlags.NonPublic)
                .Invoke(control, new object[] { args });
        }
    }
    public static void Click(Control control) {
        typeof(Control).GetMethod("OnClick", BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(control, new object[] { EventArgs.Empty });
    }
    public static void Mouse(Control control, string phase) {
        MouseEventArgs args = new MouseEventArgs(MouseButtons.Left, 1, 0, 0, 0);
        typeof(Control).GetMethod("OnMouse" + phase, BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(control, new object[] { args });
    }
}
'@
$script:Checks = 0
function Assert($condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:Checks++
}
function Fresh([int]$count = 6) {
    $script:Cfg.Count = $count
    $script:Undo = $null
    Start-Over
    $script:End = (Get-Date).AddMinutes(40)
}
function Invoke-TestNotice($notice) {
    $notice.Show()
    try {
        $body = $notice.Controls['Reason']
        $script:NoticeReason = $body.Text
        Assert ($body.Bottom -lt $notice.AcceptButton.Top) 'The explanation fits above the action'
        if ($RenderDirectory -and $body.Text -match 'Speaker count: 6.*at least 6 min') { Save-DialogRender $notice 'schedule-notice' }
        $notice.AcceptButton.PerformClick()
    } finally { $notice.Close() }
}
function Invoke-TestDialog($dialog) {
    $dialog.Show()
    try {
        Assert ($dialog.Controls['MeetingEnd'].CustomFormat -eq 'HH:mm') 'End picker must remain time-only'
        Assert ($dialog.AcceptButton.TabStop -and $dialog.CancelButton.TabStop) 'Dialog actions need keyboard focus'
        switch ($script:DialogCase) {
            'Restart' {
                $restart = $dialog.Controls | Where-Object Text -eq 'New meeting'
                [TimerTestInput]::AnswerConfirmation($false)
                $restart.PerformClick()
                Assert ($dialog.Visible -and $script:Idx -eq 1) 'Declining restart keeps the meeting and settings open'
                [TimerTestInput]::AnswerConfirmation($true)
                $restart.PerformClick()
                Assert ($dialog.DialogResult -eq 'OK') 'Confirming restart applies the new meeting'
            }
            'Unrelated' {
                Assert ($dialog.Controls['SpeakerCount'].Value -eq 6) 'Opening past-deadline settings must preserve speaker count'
                $alwaysOnTop = @($dialog.Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] })
                Assert ($alwaysOnTop.Count -eq 1 -and $alwaysOnTop[0].Text -notmatch 'sound') 'Settings offer only the existing always-on-top checkbox'
                $before = $alwaysOnTop[0].Checked
                [TimerTestInput]::Click($alwaysOnTop[0])
                Assert ($alwaysOnTop[0].Checked -ne $before) 'Clicking always-on-top toggles the preference'
                [TimerTestInput]::DialogKey($dialog, [Windows.Forms.Keys]::Enter)
                Assert ($dialog.DialogResult -eq 'OK') 'Enter must save settings'
            }
            'NextDay' {
                $dialog.Controls['MeetingEnd'].Value = $script:PickedEnd
                Assert ($script:SetEndLabel.Text.Contains('tomorrow')) 'Next-day rollover needs a visible label'
                if ($RenderDirectory) { Save-DialogRender $dialog 'settings' }
                [TimerTestInput]::DialogKey($dialog, [Windows.Forms.Keys]::Enter)
            }
            'Limits' {
                $count = $dialog.Controls['SpeakerCount']
                $picker = $dialog.Controls['MeetingEnd']
                $picker.Value = (Get-Date).AddMinutes(3)
                Assert ($count.Value -eq 6 -and $count.Minimum -eq 1) 'Shortening the deadline keeps entered count editable'
                $script:NoticeReason = ''
                [TimerTestInput]::DialogKey($dialog, [Windows.Forms.Keys]::Enter)
                Assert ($script:NoticeReason -match 'Speaker count: 6.*at least 6 min' -and $dialog.DialogResult -eq 'None') 'Saving an impossible end explains the requirement and leaves settings open'
                Assert ($script:Idx -eq 3 -and $script:Sw.IsRunning -and $script:People.Count -eq 6) 'Invalid save preserves the live meeting'
                $count.Value = 2
                $script:NoticeReason = ''
                $count.UpButton()
                Assert ($count.Value -eq 2 -and $script:NoticeReason -match 'Speaker count: 3.*at least 3 min') 'A blocked spinner increment gives the reason without changing the count'
                $count.Value = 8
                $script:NoticeReason = ''
                $dialog.AcceptButton.PerformClick()
                Assert ($count.Value -eq 8 -and $dialog.DialogResult -eq 'None' -and $script:NoticeReason -match 'Speaker count: 8.*at least 8 min') 'An over-budget typed count is explained at save without clamping'
                $count.Text = '51'
                $script:NoticeReason = ''
                $dialog.AcceptButton.PerformClick()
                Assert ($count.Value -eq 51 -and $script:NoticeReason -match 'up to 50 speakers' -and $dialog.DialogResult -eq 'None') 'Typed counts over fifty receive a specific notice'
                $count.Value = 1
                $count.UpButton()
                Assert ($count.Value -eq 2) 'A permitted spinner increment succeeds'
                $count.DownButton()
                Assert ($count.Value -eq 1) 'Spinner decrement lowers the head count'
                $count.UpButton()
                $script:SavedEnd = $script:SetProposedEnd
                $dialog.AcceptButton.PerformClick()
            }
            'CountOnly' {
                $dialog.Controls['SpeakerCount'].Value = 2
                $dialog.AcceptButton.PerformClick()
            }
            'Cancel' {
                $dialog.Controls['MeetingEnd'].Value = (Get-Date).AddHours(2)
                $dialog.CancelButton.PerformClick()
                Assert ($dialog.DialogResult -eq 'Cancel') 'Cancel button discards the draft'
            }
        }
        $dialog.DialogResult
    } finally { if (-not $dialog.IsDisposed) { $dialog.Close() } }
}
function Save-DialogRender($dialog, [string]$name) {
    $bitmap = New-Object Drawing.Bitmap($dialog.Width, $dialog.Height)
    try {
        $dialog.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
        $bitmap.Save((Join-Path $RenderDirectory ($name + '.png')), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
}
function Save-MainRender([string]$name) {
    $form.PerformLayout()
    Layout-Band
    Layout-BarControls
    Refresh-All
    $bitmap = New-Object Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $panels = if ($script:BarMode) { @($stage) } else { @($strip, $stage, $band) }
        foreach ($panel in $panels) {
            $part = New-Object Drawing.Bitmap($panel.Width, $panel.Height)
            $partGraphics = [Drawing.Graphics]::FromImage($part)
            try {
                if ($panel -eq $stage) { Paint-Stage $partGraphics }
                elseif ($panel -eq $strip) { Paint-Strip $partGraphics }
                else { Paint-Band $partGraphics }
                $graphics.DrawImageUnscaled($part, $panel.Left, $panel.Top)
            } finally { $partGraphics.Dispose(); $part.Dispose() }
        }
        $buttons = if ($script:BarMode) { $barButtons } else { $normalButtons }
        foreach ($button in $buttons) {
            if ($button -eq $btnNext -and -not $script:Sw.IsRunning) { continue }
            $rect = New-Object Drawing.Rectangle(($button.Parent.Left + $button.Left), ($button.Parent.Top + $button.Top), $button.Width, $button.Height)
            $button.DrawToBitmap($bitmap, $rect)
        }
        $bitmap.Save((Join-Path $RenderDirectory ($name + '.png')), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
try {
    Assert ($PSVersionTable.PSVersion.Major -eq 5) 'Use Windows PowerShell 5.1'
    Assert ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') 'Use -STA for native controls'
    Set-Theme 'light'
    Fresh
    foreach ($button in ($normalButtons + $barButtons)) {
        Assert ($button -is [Windows.Forms.IButtonControl] -and $button.TabStop) 'Actions must use keyboard-accessible native buttons'
    }
    Assert ($btnBar.Text -eq 'Presenter bar' -and $btnBarBack.Text -eq 'Main window') 'Mode controls need explicit labels'
    Assert ($btnBar.Glyph -eq 'presenter-bar') 'Presenter entry is rendered as an icon'
    $initialBounds = $form.Bounds
    $initialTopMost = $script:TopMostPref
    $script:TopMostPref = $false
    $form.TopMost = $false
    $form.Width = $form.MinimumSize.Width
    Place-Corner
    $workingArea = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    # Initialize the paint handlers before exposing the window to synchronous native messages.
    foreach ($panel in @($strip, $stage, $band)) { [TimerTestInput]::Paint($panel) }
    $form.Show()
    $btnDark.PerformClick()
    Assert ($script:ThemeName -eq 'dark') 'Moon selects the dark theme'
    $btnLight.PerformClick()
    Assert ($script:ThemeName -eq 'light') 'Sun selects the light theme'
    Fresh 2
    $btnRun.PerformClick()
    $btnRun.PerformClick()
    Assert (-not $script:Sw.IsRunning -and -not $btnNext.Visible) 'Pause hides Next'
    $btnRun.PerformClick()
    $btnNext.PerformClick()
    Assert ($script:Idx -eq 1 -and $btnNext.Text -eq 'Finish') 'Next reaches the final speaker'
    $btnNext.PerformClick()
    $btnUndo.PerformClick()
    Assert ($script:Idx -eq 1 -and $script:Sw.IsRunning) 'Undo after Finish restores the running speaker'
    $script:DialogCase = 'Restart'
    $btnSet.PerformClick()
    Assert ($script:Idx -eq 0 -and -not $script:Sw.IsRunning) 'Confirmed restart returns to speaker one'
    Fresh
    $normalBounds = $form.Bounds
    [TimerTestInput]::Click($btnBar)
    Assert $script:BarMode 'Bar button enters presenter mode'
    Assert ($stage.BackColor -eq $C.Strip) 'Presenter button corners match the bar'
    Assert ($form.Location -eq $normalBounds.Location -and $form.Width -eq $normalBounds.Width) 'Bar entry keeps the normal location and minimum width at a screen edge'
    Assert ($form.Height -lt $normalBounds.Height -and $form.Width -gt $form.Height) 'Bar entry reduces the height and remains horizontal'
    Assert ($form.TopMost -and -not (Load-Config).TopMost) 'Presenter mode stays on top without saving it as the normal preference'
    Assert ($form.Height -eq (S 88)) 'A narrow horizontal bar reserves a second row'
    foreach ($button in $barButtons) {
        Assert ($button.Top -ge (S 42) -and $stage.ClientRectangle.Contains($button.Bounds)) 'Minimum-width bar buttons stay below the clock and within the window'
        Assert (-not [string]::IsNullOrEmpty($button.Glyph)) 'Presenter actions have icons and retain native text for accessibility'
    }
    [TimerTestInput]::Paint($stage)
    if ($RenderDirectory) { Save-MainRender 'narrow-horizontal' }
    $centerX = [int](($workingArea.Left + $workingArea.Right - $form.Width) / 2)
    $centerY = [int](($workingArea.Top + $workingArea.Bottom - $form.Height) / 2)
    $originalBounds = $form.Bounds
    $script:TestCursorPosition = New-Object Drawing.Point(($form.Left + (S 20)), ($form.Top + (S 20)))
    [TimerTestInput]::Mouse($stage, 'Down')
    [TimerTestInput]::Mouse($stage, 'Move')
    [TimerTestInput]::Mouse($stage, 'Up')
    Assert ($null -eq $script:BarDrag -and $form.Bounds -eq $originalBounds) 'Clicking the bar leaves it in place'
    foreach ($drop in @(
        @($centerX, $centerY, 'center'),
        @($centerX, $workingArea.Top, 'top'),
        @($workingArea.Left, $centerY, 'left'),
        @(($workingArea.Right - $form.Width), $centerY, 'right'),
        @($centerX, ($workingArea.Bottom - $form.Height), 'bottom'))) {
        $script:TestCursorPosition = New-Object Drawing.Point(($form.Left + (S 20)), ($form.Top + (S 20)))
        [TimerTestInput]::Mouse($stage, 'Down')
        Assert ($null -ne $script:BarDrag -and -not $script:BarDrag.Moving) 'Mouse down records the drag origin'
        $script:TestCursorPosition = New-Object Drawing.Point(($drop[0] + (S 20)), ($drop[1] + (S 20)))
        $expectedBounds = New-Object Drawing.Rectangle($drop[0], $drop[1], $originalBounds.Width, $originalBounds.Height)
        [TimerTestInput]::Mouse($stage, 'Move')
        Assert ($script:BarDrag.Moving -and $form.Bounds -eq $expectedBounds) 'Bar follows the simulated pointer during drag'
        [TimerTestInput]::Mouse($stage, 'Up')
        Assert ($null -eq $script:BarDrag -and -not $stage.Capture) 'Mouse up clears drag state and capture'
        Assert ($form.Bounds -eq $expectedBounds -and $form.TopMost) "Bar stays horizontal and on top after dropping at the $($drop[2])"
    }
    [TimerTestInput]::Click($btnBarRun)
    Assert $script:Sw.IsRunning 'Presenter start button runs the clock'
    [TimerTestInput]::Click($btnBarRun)
    Assert (-not $script:Sw.IsRunning -and $btnBarRun.Text -eq 'Resume') 'Presenter pause button changes to Continue'
    Assert (-not $btnBarNext.Enabled) 'Next is disabled while paused'
    [TimerTestInput]::Click($btnBarNext)
    Assert ($script:Idx -eq 0) 'Paused next cannot skip a speaker'
    [TimerTestInput]::Click($btnBarRun)
    Assert ($script:Sw.IsRunning -and $btnBarRun.Text -eq 'Pause') 'Presenter Continue resumes the clock'
    [TimerTestInput]::Click($btnBarNext)
    Assert ($script:Idx -eq 1) 'Presenter next button switches speakers'
    [TimerTestInput]::Click($btnBarUndo)
    Assert ($script:Idx -eq 0) 'Presenter undo button restores the speaker'
    [TimerTestInput]::Click($btnBarBack)
    Assert (-not $script:BarMode -and $form.Bounds -eq $normalBounds) 'Back button restores the normal window bounds'
    Assert (-not $form.TopMost) 'Back button restores the disabled always-on-top preference'
    $script:TopMostPref = $initialTopMost
    $form.TopMost = $initialTopMost
    $form.Bounds = $initialBounds
    [void][TimerTestInput]::Key($form, [Windows.Forms.Keys]::B)
    [void][TimerTestInput]::Key($form, [Windows.Forms.Keys]::Escape)
    Assert (-not $script:BarMode) 'B and Escape preserve mode shortcuts'

    Fresh
    $key = [TimerTestInput]::Key($form, [Windows.Forms.Keys]::Space)
    Assert ($script:Sw.IsRunning -and $script:Idx -eq 0 -and $key.SuppressKeyPress) 'Space starts once without clicking a focused button'
    Go-Next
    $key = [TimerTestInput]::Key($form, [Windows.Forms.Keys]'Control, Z')
    Assert ($script:Idx -eq 0 -and $key.SuppressKeyPress) 'Ctrl+Z restores the last action'

    foreach ($usePresenterBar in @($false, $true)) {
        Fresh 2
        Set-BarMode $usePresenterBar
        $runButton = if ($usePresenterBar) { $btnBarRun } else { $btnRun }
        $nextButton = if ($usePresenterBar) { $btnBarNext } else { $btnNext }
        $undoButton = if ($usePresenterBar) { $btnBarUndo } else { $btnUndo }
        $form.Activate()
        $runButton.Select()
        Assert ($form.ActiveControl -eq $runButton) 'The run button can receive focus'
        Assert ([TimerTestInput]::SendKey($runButton, [Windows.Forms.Keys]::Right)) 'The focused button routes Right through key preprocessing'
        Assert ($script:Idx -eq 0 -and ($form.ActiveControl -eq $runButton)) 'Right does not advance or move button focus before the start'
        Toggle-Run
        Assert ($tips.GetToolTip($btnNext).Contains('next speaker')) 'Main Next describes advancing'
        foreach ($button in $barButtons) { Assert (!$tips.GetToolTip($button)) 'Presenter actions have no hover popups' }
        Assert ([TimerTestInput]::SendKey($runButton, [Windows.Forms.Keys]::Right)) 'Right is consumed during a run'
        Assert ($script:Idx -eq 1 -and ($form.ActiveControl -eq $runButton)) 'Right advances while keeping button focus'
        if (-not $usePresenterBar) {
            Assert ($form.Text -match '^\+?\d{2,}:[0-5]\d · Speaker 2 · Time per Turn$') 'Normal title and taskbar label identify only the current speaker'
            if ($RenderDirectory) { Save-MainRender 'main-speaker-2' }
        }
        Toggle-Run
        Assert ([TimerTestInput]::SendKey($runButton, [Windows.Forms.Keys]::Right)) 'Right remains consumed while paused'
        Assert ($script:Idx -eq 1 -and ($form.ActiveControl -eq $runButton)) 'Right does not advance or move focus while paused'
        Toggle-Run
        Assert ([TimerTestInput]::SendKey($runButton, [Windows.Forms.Keys]::Tab) -and ($form.ActiveControl -eq $nextButton)) 'Tab moves forward between action buttons'
        [TimerTestInput]::DialogKey($form, [Windows.Forms.Keys]'Shift, Tab')
        Assert (($form.ActiveControl -eq $runButton)) 'Shift+Tab moves back between action buttons'
        Assert ($nextButton.Text -eq 'Finish' -and $tips.GetToolTip($btnNext).Contains('Finish the meeting')) 'The last action tooltip describes finishing the meeting'
        Assert ([TimerTestInput]::SendKey($runButton, [Windows.Forms.Keys]::Right)) 'Right is consumed at finish'
        Assert ((Test-FinishHint (Get-Phase)) -and $undoButton.Enabled) 'Finishing brings up a brief completion notice and enables undo'
        Assert ((Get-BarMessage (Get-Phase)) -eq 'Meeting ended · Undo') 'Presenter status announces finish and undo'
        if ($RenderDirectory) {
            $layout = if ($usePresenterBar) { 'bar' } else { 'main' }
            Save-MainRender ($layout + '-finished')
        }
        $undoButton.PerformClick()
        Assert ($script:Idx -eq 1 -and $script:Sw.IsRunning -and -not (Test-FinishHint (Get-Phase))) 'Undo restores the running final speaker and dismisses the completion notice'
    }
    Set-BarMode $false

    Fresh
    Toggle-Run
    Go-Next
    Go-Next
    Go-Next
    $script:DialogCase = 'Limits'
    Show-Settings
    Assert ($script:People.Count -eq 2 -and $script:End -eq $script:SavedEnd -and $script:Idx -eq 0 -and !$script:Sw.IsRunning -and !$script:Undo -and $script:Plan -eq 0) 'Corrected settings restart with the selected schedule'
    Assert (@($script:People | Where-Object { $_.Started -or $_.Used -or $_.Budget }).Count -eq 0) 'All speaker records were reset'
    Fresh
    Toggle-Run; Go-Next
    $expectedEnd = $script:End
    $script:DialogCase = 'CountOnly'
    Show-Settings
    Assert ($script:People.Count -eq 2 -and $script:End -eq $expectedEnd -and $script:Idx -eq 0 -and !$script:Sw.IsRunning) 'Count-only change resets and preserves the chosen end'

    Fresh
    Toggle-Run; Go-Next
    $script:End = (Get-Date).AddMinutes(-1)
    $expectedEnd = $script:End
    $script:DialogCase = 'Unrelated'
    Show-Settings
    Assert ($script:End -eq $expectedEnd -and $script:People.Count -eq 6 -and $script:Sw.IsRunning -and $script:Idx -eq 1 -and $script:Undo) 'Preference-only save preserves the live meeting even past the end'
    Fresh
    Toggle-Run; Go-Next
    $script:DialogCase = 'NextDay'
    $now = Get-Date
    $script:PickedEnd = if ($now.Hour -gt 0) { $now.AddHours(-1) } else { $now.Date }
    Show-Settings
    Assert ($script:End.Date -eq (Get-Date).Date.AddDays(1) -and !$script:Sw.IsRunning -and $script:Idx -eq 0 -and $script:People.Count -eq 6) 'Time-only save restarts with the next-day deadline'
    Toggle-Run; Go-Next
    $expectedEnd = $script:End
    $script:DialogCase = 'Cancel'
    Show-Settings
    Assert ($script:End -eq $expectedEnd -and $script:Idx -eq 1 -and $script:Sw.IsRunning -and $script:Undo) 'Cancel preserves the live meeting'

    foreach ($theme in @('light','dark')) {
        Set-Theme $theme
        Fresh
        $script:People[0].Started = $true
        $script:People[0].Budget = 180
        $script:People[0].Used = 120
        $script:Sw.Restart()
        Save-Undo 'next'
        Assert ((Get-Phase).Closing -and (Test-UndoHint)) 'The one-minute cue applies even while the undo hint is available'
        if ($RenderDirectory) { Save-MainRender ($theme + '-one-minute') }
        Set-BarMode $true
        if ($RenderDirectory) { Save-MainRender ($theme + '-bar-one-minute') }
        Set-BarMode $false
        Fresh
        foreach ($phase in @('normal','notice','critical','over')) {
            $script:People[0].Started = $true
            $script:People[0].Budget = 100
            $script:People[0].Used = switch ($phase) { 'normal' { 10 } 'notice' { 70 } 'critical' { 90 } 'over' { 105 } }
            $script:Sw.Restart()
            $state = Get-Phase
            Assert ($state.Level -eq $phase) 'Rendered phase must match remaining percentage'
            $color = Get-ClockColor $state
            Assert (-not $color.IsEmpty) 'Every clock phase has a color in both themes'
            if ($RenderDirectory) { Save-MainRender ($theme + '-' + $phase) }
            $script:Sw.Stop()
        }
        $compactBounds = $form.Bounds
        $form.SetBounds($centerX, $centerY, (S 600), $compactBounds.Height)
        $wideBounds = $form.Bounds
        Set-BarMode $true
        Assert ($form.Location -eq $wideBounds.Location -and $form.Width -eq $wideBounds.Width) 'Wide bar starts at the normal location and retains its width'
        Assert ($form.Height -eq (S 58)) 'Wide bar fits on one row'
        foreach ($button in $barButtons) {
            Assert ($stage.ClientRectangle.Contains($button.Bounds)) 'Presenter controls fit the wide layout'
        }
        [TimerTestInput]::Paint($stage)
        if ($RenderDirectory) { Save-MainRender ($theme + '-bar-wide') }
        Set-BarMode $false
        $form.Bounds = $compactBounds
        Fresh
        Set-BarMode $true
        $compactWidth = $form.Width
        if ($RenderDirectory) { Save-MainRender ($theme + '-bar-compact') }
        $script:People[0].Started = $true
        $script:People[0].Budget = 100
        $script:People[0].Used = 15
        Refresh-All
        if ($RenderDirectory) { Save-MainRender ($theme + '-bar-paused') }
        $script:People[0].Used = 70
        $script:Sw.Restart()
        Refresh-All
        Assert ($form.Width -eq $compactWidth) 'Quiet time guidance preserves the presenter bar width'
        if ($RenderDirectory) { Save-MainRender ($theme + '-bar-notice') }
        $script:Sw.Stop()
        Fresh 50
        $script:Idx = 11
        Refresh-All
        Assert ($form.Width -eq $compactWidth) 'Fifty speakers do not change the presenter bar width'
        $script:People[11].Started = $true
        $script:People[11].Budget = 100
        $script:People[11].Used = 114
        $quiet = Get-Phase
        Assert ((Get-ClockColor $quiet) -eq $C.Ink -and (Get-ClockColor $quiet $true) -eq $C.StripInk) 'Early overtime digits retain the regular color in both layouts'
        $script:People[11].Used = 115
        $highlighted = Get-Phase
        Assert ((Get-ClockColor $highlighted) -eq $C.Overtime -and (Get-ClockColor $highlighted $true) -eq $C.BarOvertime) 'Overtime digits use the quiet highlight from fifteen seconds'
        if ($RenderDirectory) { Save-MainRender ($theme + '-bar-crowded-over') }
        $crowdedPeople = $script:People
        $script:People = $crowdedPeople[0..19]
        $script:Sw.Restart()
        Assert ((Get-BarMessage (Get-Phase)) -eq '') 'Running overtime uses the clock alone in presenter mode'
        if ($RenderDirectory) { Save-MainRender ($theme + '-bar-speaker-12-of-20') }
        $script:Sw.Stop()
        $script:People = $crowdedPeople
        $script:People[11].Used = 115.5
        Assert ((Get-ClockColor (Get-Phase)) -eq (Get-ClockColor $highlighted)) 'Overtime highlight is stable'
        Set-BarMode $false
        if ($RenderDirectory) { Save-MainRender ($theme + '-crowded-over') }
    }
    Set-Theme 'light'
    $form.MinimumSize = [Drawing.Size]::Empty
    $form.ClientSize = New-Object Drawing.Size((Get-MinClientWidth), (S 290))
    Layout-Band
    Assert ($btnUndo.Right -lt $btnSet.Left) 'Main actions fit minimum width'
    Assert ($btnLight.Right -lt $btnDark.Left -and $btnDark.Right -lt $btnBar.Left -and $btnBar.Right -le $band.ClientSize.Width) 'Theme and presenter icons fit in order at minimum width'
    Assert ($btnLight.Top -eq $btnBar.Top -and $btnDark.Top -eq $btnBar.Top) 'Presenter icon shares the theme row'
    # Physical pixels available to the normal clock in a 380 x 328 client at 200% DPI.
    $clockWidth = 760
    $clockHeight = 240
    $normalFont = Font-Px $famNum ($clockHeight * 0.82) $numStyle
    Assert ((Get-StageClockFont '04:32' $clockWidth $clockHeight) -eq $normalFont) 'A typical countdown retains the normal font size'
    foreach ($text in @('1439:59', '+1000:01')) {
        $font = Get-StageClockFont $text $clockWidth $clockHeight
        Assert ((Measure-W $text $font) -le $clockWidth) "The full $text clock fits the normal window at 200% DPI"
    }
    if ($RenderDirectory) { Save-MainRender 'minimum' }
    Write-Host ("{0} native UI checks passed" -f $script:Checks)
} finally {
    $timer.Stop()
    $script:Sw.Stop()
    $form.Dispose()
    $tips.Dispose()
    foreach ($file in @($bootstrapPath, $modelPath, (Join-Path $testDirectory 'config.json'))) {
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
    [IO.Directory]::Delete($testDirectory)
}
