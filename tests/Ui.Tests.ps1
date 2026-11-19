# Native control and layout regressions. Run with Windows PowerShell 5.1 -STA.
param([string]$RenderDirectory = '')
$ErrorActionPreference = 'Stop'
if ($RenderDirectory) { [void][IO.Directory]::CreateDirectory($RenderDirectory) }
$repo = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $repo 'CameraHAL_MeetingTimer.ps1'))
$bootstrap = $source.Substring(0, $source.IndexOf('# ---------------- start ----------------'))
$bootstrap = $bootstrap.Replace('$dlg.ShowDialog($form)', '(Invoke-TestDialog $dlg)')
# Feed screen coordinates to the real handlers without moving the desktop cursor.
$bootstrap = $bootstrap.Replace('[Windows.Forms.Cursor]::Position', '$script:TestCursorPosition')
$testDirectory = Join-Path $repo ('.ui-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$bootstrapPath = Join-Path $testDirectory 'Application.ps1'
[IO.File]::WriteAllText($bootstrapPath, $bootstrap, (New-Object Text.UTF8Encoding $true))
. $bootstrapPath
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Reflection;
using System.Drawing;
using System.Windows.Forms;
public static class TimerTestInput {
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
function Fresh {
    $script:Cfg.Count = 6
    $script:Undo = $null
    Start-Over
    $script:End = (Get-Date).AddMinutes(40)
}
function Invoke-TestDialog($dialog) {
    $dialog.Show()
    try {
        Assert ($dialog.Controls['MeetingEnd'].CustomFormat -eq 'HH:mm') 'End picker must remain time-only'
        Assert ($dialog.AcceptButton.TabStop -and $dialog.CancelButton.TabStop) 'Dialog actions need keyboard focus'
        switch ($script:DialogCase) {
            'Unrelated' {
                Assert ($dialog.Controls['SpeakerCount'].Value -eq 6) 'Opening past-deadline settings must preserve speaker count'
                $alwaysOnTop = @($dialog.Controls | Where-Object { $_ -is [Windows.Forms.CheckBox] })
                Assert ($alwaysOnTop.Count -eq 1 -and $alwaysOnTop[0].Text -notmatch '알림음') 'Settings offer only the existing always-on-top checkbox'
                $alwaysOnTop[0].Checked = -not $alwaysOnTop[0].Checked
                [TimerTestInput]::DialogKey($dialog, [Windows.Forms.Keys]::Enter)
                Assert ($dialog.DialogResult -eq 'OK') 'Enter must save settings'
            }
            'NextDay' {
                $dialog.Controls['MeetingEnd'].Value = $script:PickedEnd
                Assert ($script:SetEndLabel.Text.Contains('다음 날')) 'Next-day rollover needs a visible label'
                if ($RenderDirectory) { Save-DialogRender $dialog 'settings' }
                [TimerTestInput]::DialogKey($dialog, [Windows.Forms.Keys]::Enter)
            }
            'Clamp' {
                $count = $dialog.Controls['SpeakerCount']
                Assert ($count.Minimum -eq 4 -and $count.Value -eq 6) 'Settings cannot remove the current speaker or earlier speakers'
                $dialog.Controls['MeetingEnd'].Value = (Get-Date).AddMinutes(2)
                Assert ($count.Value -eq 4 -and $count.Maximum -eq 4) 'An earlier deadline can reduce the count only to the current speaker'
                Assert ($script:SetHint.Text.Contains('6명에서 4명으로')) 'The automatic reduction shows both counts before saving'
                $dialog.Controls['MeetingEnd'].Value = (Get-Date).AddMinutes(1)
                Assert ($script:SetHint.Text.Contains('6명에서 4명으로')) 'The reduction remains visible while editing the deadline'
                [TimerTestInput]::DialogKey($dialog, [Windows.Forms.Keys]::Enter)
            }
            'Cancel' {
                $dialog.Controls['MeetingEnd'].Value = (Get-Date).AddHours(2)
                [TimerTestInput]::DialogKey($dialog, [Windows.Forms.Keys]::Escape)
                Assert ($dialog.DialogResult -eq 'Cancel') 'Escape must cancel settings'
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
    Assert ($btnBar.Text -eq '발표 막대' -and $btnBarBack.Text -eq '기본 창') 'Mode controls need explicit labels'
    Assert ($btnBar.Glyph -eq 'presenter-bar') 'Presenter entry is rendered as an icon'
    $normalBounds = $form.Bounds
    $topMost = $script:TopMostPref
    [TimerTestInput]::Click($btnBar)
    Assert $script:BarMode 'Bar button enters presenter mode'
    $workingArea = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    Assert ($script:BarEdge -eq 'bottom' -and $form.Bottom -eq $workingArea.Bottom) 'Default bar docks above the taskbar at the bottom'
    Assert $form.TopMost 'Presenter mode remains on top'
    $narrowArea = New-Object Drawing.Rectangle(0, 0, (S 400), (S 600))
    $form.Bounds = Get-BarBounds $narrowArea 'bottom'
    Layout-BarControls
    Assert ($form.Height -eq (S 88)) 'A narrow horizontal bar reserves a second row'
    foreach ($button in $barButtons) {
        Assert ($button.Top -ge (S 42) -and $stage.ClientRectangle.Contains($button.Bounds)) 'Narrow bar buttons stay below the clock and within the window'
    }
    if ($RenderDirectory) { Save-MainRender 'narrow-horizontal' }
    $form.Bounds = Get-BarBounds $workingArea 'bottom'
    Layout-BarControls
    foreach ($button in $barButtons) { Assert (-not [string]::IsNullOrEmpty($button.Glyph)) 'Presenter actions have icons and retain native text for accessibility' }
    $centerX = [int](($workingArea.Left + $workingArea.Right) / 2)
    $centerY = [int](($workingArea.Top + $workingArea.Bottom) / 2)
    $originalBounds = $form.Bounds
    $script:TestCursorPosition = New-Object Drawing.Point(($form.Left + (S 20)), ($form.Top + (S 20)))
    [TimerTestInput]::Mouse($stage, 'Down')
    [TimerTestInput]::Mouse($stage, 'Move')
    [TimerTestInput]::Mouse($stage, 'Up')
    Assert ($null -eq $script:BarDrag -and $form.Bounds -eq $originalBounds) 'Clicking empty bar space leaves docking unchanged'
    foreach ($drop in @(
        @($centerX, $workingArea.Top, 'top'),
        @($workingArea.Left, $centerY, 'left'),
        @(($workingArea.Right - 1), $centerY, 'right'),
        @($centerX, ($workingArea.Bottom - 1), 'bottom'))) {
        $start = New-Object Drawing.Point(($form.Left + (S 20)), ($form.Top + (S 20)))
        $origin = $form.Location
        $script:TestCursorPosition = $start
        [TimerTestInput]::Mouse($stage, 'Down')
        Assert ($null -ne $script:BarDrag -and -not $script:BarDrag.Moving) 'Mouse down records the drag origin'
        $script:TestCursorPosition = New-Object Drawing.Point($drop[0], $drop[1])
        [TimerTestInput]::Mouse($stage, 'Move')
        $expectedMove = New-Object Drawing.Point(($origin.X + $drop[0] - $start.X), ($origin.Y + $drop[1] - $start.Y))
        Assert ($script:BarDrag.Moving -and $form.Location -eq $expectedMove) 'Bar follows the simulated pointer during drag'
        [TimerTestInput]::Mouse($stage, 'Up')
        Assert ($null -eq $script:BarDrag -and -not $stage.Capture) 'Mouse up clears drag state and capture'
        Assert ($script:BarEdge -eq $drop[2]) "Drag docks to the $($drop[2]) edge"
        Assert ($form.Bounds -eq (Get-BarBounds $workingArea $drop[2])) "Drag positions the bar at the $($drop[2]) edge"
        Assert ((Load-Config).BarEdge -eq $drop[2]) "Drag persists the $($drop[2]) edge"
    }
    [TimerTestInput]::Click($btnBarRun)
    Assert $script:Sw.IsRunning 'Presenter start button runs the clock'
    [TimerTestInput]::Click($btnBarRun)
    Assert (-not $script:Sw.IsRunning -and $btnBarRun.Text -eq '계속') 'Presenter pause button changes to Continue'
    Assert (-not $btnBarNext.Enabled) 'Next is disabled while paused'
    [TimerTestInput]::Click($btnBarNext)
    Assert ($script:Idx -eq 0) 'Paused next cannot skip a speaker'
    [TimerTestInput]::Click($btnBarRun)
    Assert ($script:Sw.IsRunning -and $btnBarRun.Text -eq '일시정지') 'Presenter Continue resumes the clock'
    [TimerTestInput]::Click($btnBarNext)
    Assert ($script:Idx -eq 1) 'Presenter next button switches speakers'
    Assert ($null -ne $script:BatonStarted) 'Presenter Next starts one camera movement'
    [TimerTestInput]::Click($btnBarUndo)
    Assert ($script:Idx -eq 0) 'Presenter undo button restores the speaker'
    Assert ($null -eq $script:BatonStarted) 'Presenter Undo places the camera without replaying movement'
    [TimerTestInput]::Click($btnBarBack)
    Assert (-not $script:BarMode -and $form.Bounds -eq $normalBounds) 'Back button restores the normal window bounds'
    Assert ($form.TopMost -eq $topMost) 'Back button restores always-on-top preference'
    [void][TimerTestInput]::Key($form, [Windows.Forms.Keys]::B)
    [void][TimerTestInput]::Key($form, [Windows.Forms.Keys]::Escape)
    Assert (-not $script:BarMode) 'B and Escape preserve mode shortcuts'

    Fresh
    $key = [TimerTestInput]::Key($form, [Windows.Forms.Keys]::Space)
    Assert ($script:Sw.IsRunning -and $script:Idx -eq 0 -and $key.SuppressKeyPress) 'Space starts once without clicking a focused button'
    Go-Next
    $key = [TimerTestInput]::Key($form, [Windows.Forms.Keys]'Control, Z')
    Assert ($script:Idx -eq 0 -and $key.SuppressKeyPress) 'Ctrl+Z restores the last action'

    # Initialize the paint handlers before exposing the window to synchronous native messages.
    foreach ($panel in @($strip, $stage, $band)) { [TimerTestInput]::Paint($panel) }
    $form.Show()
    foreach ($usePresenterBar in @($false, $true)) {
        Fresh
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
        Assert ($tips.GetToolTip($nextButton).Contains('다음 발표자')) 'Next indicates that the next speaker starts'
        Assert ([TimerTestInput]::SendKey($runButton, [Windows.Forms.Keys]::Right)) 'Right is consumed during a run'
        Assert ($script:Idx -eq 1 -and ($form.ActiveControl -eq $runButton)) 'Right advances while keeping button focus'
        if (-not $usePresenterBar) {
            Assert ($form.Text -match '^\+?\d{2,}:[0-5]\d · 발표자 2 · CameraHAL_MeetingTimer$') 'Normal title and taskbar label identify only the current speaker'
            if ($RenderDirectory) { Save-MainRender 'main-speaker-2' }
        }
        Toggle-Run
        Assert ([TimerTestInput]::SendKey($runButton, [Windows.Forms.Keys]::Right)) 'Right remains consumed while paused'
        Assert ($script:Idx -eq 1 -and ($form.ActiveControl -eq $runButton)) 'Right does not advance or move focus while paused'
        Toggle-Run
        Assert ([TimerTestInput]::SendKey($runButton, [Windows.Forms.Keys]::Tab) -and ($form.ActiveControl -eq $nextButton)) 'Tab moves forward between action buttons'
        [TimerTestInput]::DialogKey($form, [Windows.Forms.Keys]'Shift, Tab')
        Assert (($form.ActiveControl -eq $runButton)) 'Shift+Tab moves back between action buttons'
        Set-Count 2
        Assert ($nextButton.Text -eq '종료' -and $tips.GetToolTip($nextButton).Contains('회의를 종료합니다')) 'The last action tooltip describes finishing the meeting'
        Assert ([TimerTestInput]::SendKey($runButton, [Windows.Forms.Keys]::Right)) 'Right is consumed at finish'
        Assert ((Test-FinishHint (Get-Phase)) -and $undoButton.Enabled) 'Finishing brings up a brief completion notice and enables undo'
        Assert ((Get-BarMessage (Get-Phase)) -eq '회의 종료 · 되돌리기') 'Presenter status announces finish and undo'
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
    $script:DialogCase = 'Clamp'
    Show-Settings
    Assert ($script:People.Count -eq 4 -and $script:Cfg.Count -eq 4 -and $script:Idx -eq 3 -and $script:Sw.IsRunning) 'Save preserves the active speaker and persists the announced count'

    Fresh
    $script:End = (Get-Date).AddMinutes(-1)
    $expectedEnd = $script:End
    $script:DialogCase = 'Unrelated'
    Show-Settings
    Assert ($script:End -eq $expectedEnd -and $script:People.Count -eq 6) 'Preference-only save preserves expired end and speaker count'
    Fresh
    $script:DialogCase = 'NextDay'
    $script:PickedEnd = (Get-Date).Date
    Show-Settings
    Assert ($script:End.Date -eq (Get-Date).Date.AddDays(1)) 'Edited past time resolves to tomorrow'
    $expectedEnd = $script:End
    $script:DialogCase = 'Cancel'
    Show-Settings
    Assert ($script:End -eq $expectedEnd) 'Cancelled settings preserve the deadline'

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
        $script:BarEdge = 'bottom'
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
        foreach ($edge in @('bottom','top','left','right')) {
            $script:BarEdge = $edge
            Set-BarMode $true
            $workingArea = [Windows.Forms.Screen]::FromControl($form).WorkingArea
            $form.Bounds = Get-BarBounds $workingArea $edge
            Layout-BarControls
            foreach ($button in $barButtons) { Assert ($stage.ClientRectangle.Contains($button.Bounds)) 'Presenter controls fit every dock orientation' }
            if ($RenderDirectory) { Save-MainRender ($theme + '-bar-' + $edge) }
            Set-BarMode $false
        }
        Fresh
        $script:BarEdge = 'bottom'
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
        Set-Count 50
        $script:Idx = 11
        Refresh-All
        Assert ($form.Width -eq $compactWidth) 'Fifty speakers do not change the presenter bar width'
        Assert ($null -eq $script:BatonStarted) 'Pause and speaker count changes do not start movement'
        $script:People[11].Started = $true
        $script:People[11].Budget = 100
        $script:People[11].Used = 114
        $quiet = Get-Phase
        Assert ((Get-ClockColor $quiet) -eq $C.Ink -and (Get-ClockColor $quiet $true) -eq $C.StripInk) 'Early overtime digits retain the regular color in both layouts'
        $script:People[11].Used = 115
        $highlighted = Get-Phase
        Assert ((Get-ClockColor $highlighted) -eq $C.Overtime -and (Get-ClockColor $highlighted $true) -eq $C.BarOvertime) 'Overtime digits use the quiet highlight from fifteen seconds'
        if ($RenderDirectory) { Save-MainRender ($theme + '-bar-crowded-over') }
        Set-Count 20
        $script:Sw.Restart()
        Assert ((Get-BarMessage (Get-Phase)) -eq '') 'Running overtime uses the clock alone in presenter mode'
        if ($RenderDirectory) { Save-MainRender ($theme + '-bar-speaker-12-of-20') }
        $script:Sw.Stop()
        Set-Count 50
        $script:People[11].Used = 115.5
        Assert ((Get-ClockColor (Get-Phase)) -eq (Get-ClockColor $highlighted)) 'Overtime highlight is stable'
        $script:BarEdge = 'right'
        $form.Bounds = Get-BarBounds $workingArea
        Layout-BarControls
        if ($RenderDirectory) { Save-MainRender ($theme + '-vertical-crowded-over') }
        Set-BarMode $false
        Assert ($null -eq $script:BatonStarted) 'Redocking, theme changes and returning to the main window do not start movement'
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
    foreach ($file in @($bootstrapPath, (Join-Path $testDirectory 'config.json'))) {
        if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    }
    [IO.Directory]::Delete($testDirectory)
}
