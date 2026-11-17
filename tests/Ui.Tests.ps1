# Native control and layout regressions. Run with Windows PowerShell 5.1 -STA.
param([string]$RenderDirectory = '')
$ErrorActionPreference = 'Stop'
if ($RenderDirectory) { [void][IO.Directory]::CreateDirectory($RenderDirectory) }
$repo = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $repo 'CameraHAL_MeetingTimer.ps1'))
$bootstrap = $source.Substring(0, $source.IndexOf('# ---------------- start ----------------'))
$bootstrap = $bootstrap.Replace('$dlg.ShowDialog($form)', '(Invoke-TestDialog $dlg)')
$testDirectory = Join-Path $repo ('.ui-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$bootstrapPath = Join-Path $testDirectory 'Application.ps1'
[IO.File]::WriteAllText($bootstrapPath, $bootstrap, (New-Object Text.UTF8Encoding $true))
. $bootstrapPath
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Reflection;
using System.Windows.Forms;
public static class TimerTestInput {
    public static KeyEventArgs Key(Control control, Keys key) {
        KeyEventArgs args = new KeyEventArgs(key);
        typeof(Control).GetMethod("OnKeyDown", BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(control, new object[] { args });
        return args;
    }
    public static void DialogKey(Form form, Keys key) {
        typeof(Form).GetMethod("ProcessDialogKey", BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(form, new object[] { key });
    }
    public static void Click(Control control) {
        typeof(Control).GetMethod("OnClick", BindingFlags.Instance | BindingFlags.NonPublic)
            .Invoke(control, new object[] { EventArgs.Empty });
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
    $script:Sound = $false
}
function Invoke-TestDialog($dialog) {
    $dialog.Show()
    try {
        Assert ($dialog.Controls['MeetingEnd'].CustomFormat -eq 'HH:mm') 'End picker must remain time-only'
        Assert ($dialog.AcceptButton.TabStop -and $dialog.CancelButton.TabStop) 'Dialog actions need keyboard focus'
        switch ($script:DialogCase) {
            'Unrelated' {
                Assert ($dialog.Controls['SpeakerCount'].Value -eq 6) 'Opening past-deadline settings must preserve speaker count'
                foreach ($control in $dialog.Controls) {
                    if ($control -is [Windows.Forms.CheckBox] -and $control.Text.StartsWith('알림음')) { $control.Checked = -not $control.Checked }
                }
                [TimerTestInput]::DialogKey($dialog, [Windows.Forms.Keys]::Enter)
                Assert ($dialog.DialogResult -eq 'OK') 'Enter must save settings'
            }
            'NextDay' {
                $dialog.Controls['MeetingEnd'].Value = $script:PickedEnd
                Assert ($script:SetEndLabel.Text.Contains('다음 날')) 'Next-day rollover needs a visible label'
                if ($RenderDirectory) { Save-DialogRender $dialog 'settings' }
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
    $normalBounds = $form.Bounds
    $topMost = $script:TopMostPref
    [TimerTestInput]::Click($btnBar)
    Assert $script:BarMode 'Bar button enters presenter mode'
    $workingArea = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    Assert ($script:BarEdge -eq 'bottom' -and $form.Bottom -eq $workingArea.Bottom) 'Default bar docks above the taskbar at the bottom'
    Assert $form.TopMost 'Presenter mode remains on top'
    $centerX = [int](($workingArea.Left + $workingArea.Right) / 2)
    $centerY = [int](($workingArea.Top + $workingArea.Bottom) / 2)
    foreach ($drop in @(
        @($centerX, $workingArea.Top, 'top'),
        @($workingArea.Left, $centerY, 'left'),
        @(($workingArea.Right - 1), $centerY, 'right'),
        @($centerX, ($workingArea.Bottom - 1), 'bottom'))) {
        Dock-Bar (New-Object Drawing.Point($drop[0], $drop[1]))
        Assert ($script:BarEdge -eq $drop[2]) 'Drop handler selects the nearest screen edge'
        Assert ((Load-Config).BarEdge -eq $drop[2]) 'Drop handler persists the chosen edge'
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
    [TimerTestInput]::Click($btnBarUndo)
    Assert ($script:Idx -eq 0) 'Presenter undo button restores the speaker'
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
        foreach ($phase in @('normal','notice','critical','over')) {
            $script:People[0].Started = $true
            $script:People[0].Budget = 100
            $script:People[0].Used = switch ($phase) { 'normal' { 10 } 'notice' { 70 } 'critical' { 90 } 'over' { 105 } }
            $script:Sw.Restart()
            $state = Get-Phase
            Assert ($state.Level -eq $phase) 'Rendered phase must match remaining percentage'
            $color = Get-ProgressColor $state
            Assert (-not $color.IsEmpty) 'Every progress phase has a color in both themes'
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
        $critical = [pscustomobject]@{ Level = 'critical'; Run = 'run'; El = 90.0 }
        $first = Get-ProgressColor $critical
        $critical.El = 90.5
        Assert ((Get-ProgressColor $critical).ToArgb() -ne $first.ToArgb()) 'Critical progress must pulse while running'
        $critical.El = 90.0
        $first = Get-ProgressColor $critical $true
        $critical.El = 90.5
        Assert ((Get-ProgressColor $critical $true).ToArgb() -ne $first.ToArgb()) 'Presenter progress must also pulse in both themes'
        $critical.Run = 'pause'
        $first = Get-ProgressColor $critical
        $critical.El = 91.0
        Assert ((Get-ProgressColor $critical).ToArgb() -eq $first.ToArgb()) 'Paused progress must stop pulsing'
    }
    Set-Theme 'light'
    $form.MinimumSize = [Drawing.Size]::Empty
    $form.ClientSize = New-Object Drawing.Size((Get-MinClientWidth), (S 290))
    Layout-Band
    Assert ($btnUndo.Right -lt $btnSet.Left) 'Main actions fit minimum width'
    Assert ($btnBar.Right -lt $btnLight.Left) 'Mode entry and theme buttons fit minimum width'
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
