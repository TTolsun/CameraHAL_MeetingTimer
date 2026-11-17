# TimeModel.Tests.ps1 - Scenario tests for the timer's time-sharing logic.
#
# Runs on stock Windows PowerShell 5.1 with nothing installed (no Pester):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\TimeModel.Tests.ps1
# Exit code is the number of failed checks.
#
# How it works: the functions are lifted out of CameraHAL_MeetingTimer.ps1 through the
# PowerShell parser, so the window is never built. The clock is faked: a function named
# Get-Date shadows the cmdlet (functions win over cmdlets), and $script:Sw is a stopwatch
# double driven by the same fake time. A one-hour meeting runs in well under a second.

$ErrorActionPreference = 'Stop'
$target = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'CameraHAL_MeetingTimer.ps1'

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { $parseErrors; exit 1 }
$defs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

# ---------------- fakes ----------------
$script:FakeNow = [datetime]'2026-01-05 14:00:00'
function Get-Date { $script:FakeNow }
function Step([double]$sec) { $script:FakeNow = $script:FakeNow.AddSeconds($sec) }

function New-FakeStopwatch {
    $o = [pscustomobject]@{ Acc = 0.0; From = $null }
    $o | Add-Member ScriptProperty IsRunning { $null -ne $this.From }
    $o | Add-Member ScriptProperty Elapsed {
        $s = $this.Acc
        if ($null -ne $this.From) { $s += ($script:FakeNow - $this.From).TotalSeconds }
        [TimeSpan]::FromSeconds($s)
    }
    $o | Add-Member ScriptMethod Start { if ($null -eq $this.From) { $this.From = $script:FakeNow } }
    $o | Add-Member ScriptMethod Stop {
        if ($null -ne $this.From) { $this.Acc += ($script:FakeNow - $this.From).TotalSeconds; $this.From = $null }
    }
    $o | Add-Member ScriptMethod Reset { $this.Acc = 0.0; $this.From = $null }
    $o
}

# UI hooks the logic calls; recorded or ignored.
$script:Sounds = New-Object System.Collections.Generic.List[string]
function Refresh-All { }
function Flash-IfHidden { }
function Play([string]$kind) { $script:Sounds.Add($kind) }
function Confirm-Action { $script:ConfirmCalls++; $script:ConfirmResult }

# Fresh meeting: $n speakers, clock at $at, meeting end at $end.
function New-Meeting([int]$n, [string]$at = '14:00:00', [string]$end = '15:00:00') {
    $script:FakeNow = [datetime]"2026-01-05 $at"
    $script:Sw = New-FakeStopwatch
    $script:MinShare = 60
    $script:Cfg = [pscustomobject]@{ Count = $n }
    $script:Undo = $null
    $script:Sounds.Clear()
    $script:ConfirmResult = $true
    $script:ConfirmCalls = 0
    Start-Over
    $script:End = [datetime]"2026-01-05 $end"
}

# ---------------- assertions ----------------
$script:Fails = 0
$script:Passes = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -eq "$expected") { $script:Passes++ }
    else { $script:Fails++; Write-Host ("FAIL  {0}: expected <{1}>, got <{2}>" -f $name, $expected, $actual) -ForegroundColor Red }
}

# ---------------- default end time ----------------
foreach ($case in @(
        @('14:05:00', '15:00'),   # ordinary: next full hour
        @('13:45:00', '14:00'),   # 15 minutes ahead is still a usable meeting
        @('13:50:00', '14:00'),   # exactly 10 minutes: keep the next hour
        @('13:52:00', '15:00'),   # opened just before a 14:00 meeting
        @('23:55:00', '01:00'))) {  # crosses midnight
    $script:FakeNow = [datetime]"2026-01-05 $($case[0])"
    Check "Get-NextHour at $($case[0])" (Get-NextHour).ToString('HH:mm') $case[1]
}

# ---------------- even split and locking ----------------
New-Meeting 6
Check 'preview splits the hour across 6' (Get-Preview) 600
Step 30
Check 'idle preview follows the clock' (Get-Preview) 595
Toggle-Run
Check 'first speaker locks the share' $script:People[0].Budget 595
Check 'first plan is set on start' $script:Plan 595

# Overrun shrinks only the shares of people who have not started.
New-Meeting 6
Toggle-Run; Step 720; Go-Next
Check 'overrun: next share is (3600-720)/5' $script:People[1].Budget 576
Check 'overrun: first speaker keeps their share' $script:People[0].Budget 600
Check 'overrun: plan delta source unchanged' $script:Plan 600

# Finishing early grows the remaining shares.
New-Meeting 6
Toggle-Run; Step 300; Go-Next
Check 'early finish: next share is (3600-300)/5' $script:People[1].Budget 660

# While a locked speaker runs, the preview for the others reserves their remaining time.
New-Meeting 4
Toggle-Run; Step 100
# Left 3500, current reserves 900-100=800, three unlocked: (3500-800)/3 = 900.
$pi = Get-Pending
Check 'pending excludes the locked speaker' $pi.Pending 3
Check 'reserved is the locked remainder' $pi.Reserved 800

# ---------------- minimum share and overbooking ----------------
New-Meeting 6 '14:57:00' '15:00:00'
Check 'overbooked when 6 x 1 min does not fit in 3 min' (Test-Overbooked) $true
Check 'preview never drops under the minimum' (Get-Preview) 60
Toggle-Run
Check 'locked share respects the minimum' $script:People[0].Budget 60
New-Meeting 3 '14:57:00' '15:00:00'
Check '3 x 1 min fits in 3 min' (Test-Overbooked) $false
Check 'Calc-Share with nobody pending' (Calc-Share 100 0 0 60) 0
Check 'Calc-Share floors to whole seconds' (Calc-Share 100 0 3 0) 33

# ---------------- phases and alerts ----------------
New-Meeting 6
Toggle-Run
Step 419; Check 'normal above 30 percent left' (Get-Phase).Level 'normal'
Step 1;   Check 'notice at 30 percent left' (Get-Phase).Level 'notice'
Check-Alerts
Step 120; Check 'critical at 10 percent left' (Get-Phase).Level 'critical'
Check-Alerts
Step 60;  Check 'over at zero' (Get-Phase).Level 'over'
Check 'countdown text at zero' (Get-Phase).Text '+00:00'
Check-Alerts
Check-Alerts
Check 'each warning sounds once' ($script:Sounds -join ',') 'Asterisk,Exclamation,Hand'
Step 30; Check-Alerts
Check 'overtime repeats every 30 s' $script:Sounds.Count 4
Check 'overtime text' (Get-Phase).Text '+00:30'

# Short shares use the same percentage boundaries.
New-Meeting 6 '14:57:00' '15:00:00'
Toggle-Run
Step 41; Check 'short share: normal at 19 s left' (Get-Phase).Level 'normal'
Step 1;  Check 'short share: notice at 18 s left' (Get-Phase).Level 'notice'
Step 12; Check 'short share: critical at 6 s left' (Get-Phase).Level 'critical'

# Pausing stops the speaker's clock but not the meeting clock.
New-Meeting 6
Toggle-Run; Step 100; Toggle-Run; Step 50
Check 'pause freezes elapsed' (Get-Elapsed 0) 100
Check 'pause state' (Get-Phase).Run 'pause'

# ---------------- next gating ----------------
New-Meeting 3
Go-Next
Check 'next is ignored before the speaker starts' $script:Idx 0
Check 'ignored next leaves no undo' ($null -eq $script:Undo) $true
Toggle-Run; Step 100; Toggle-Run
Go-Next
Check 'next is ignored while paused' $script:Idx 0
Toggle-Run
Go-Next
Check 'next works again once resumed' $script:Idx 1

# ---------------- undo ----------------
# Accidental Next while the speaker talks: they get the time back and keep running.
New-Meeting 6
Toggle-Run; Step 200; Go-Next
Check 'next moved on' $script:Idx 1
Check 'undo hint shows right after next' ([bool](Test-UndoHint)) $true
Step 15
Check 'undo hint fades after 10 s' ([bool](Test-UndoHint)) $false
Undo-Last
Check 'undo returns to the previous speaker' $script:Idx 0
Check 'undo gives the time back' (Get-Elapsed 0) 215
Check 'undo keeps the clock running' $script:Sw.IsRunning $true
Check 'undo clears the next speaker share' $script:People[1].Budget 0
Check 'undo keeps the first share' $script:People[0].Budget 600
Step 5
Check 'clock still runs after undo' (Get-Elapsed 0) 220
Undo-Last
Check 'second undo is a no-op' $script:Idx 0

# Accidental finish on the last speaker: the meeting comes back.
New-Meeting 2
Toggle-Run; Step 1500; Go-Next
Step 1000; Go-Next
Check 'finish starts a fresh meeting' $script:Idx 0
Check 'fresh meeting has no history' (Get-Elapsed 1) 0
Step 10
Undo-Last
Check 'undo after finish returns to the last speaker' $script:Idx 1
Check 'undo after finish restores their time' (Get-Elapsed 1) 1010
Check 'undo after finish restores the first speaker' (Get-Elapsed 0) 1500
Check 'undo after finish restores the end time' $script:End.ToString('HH:mm') '15:00'
Check 'undo after finish restores the plan' $script:Plan 1800

# Accidental reset, taken while paused: nothing is added for the paused gap.
New-Meeting 6
Toggle-Run; Step 100; Go-Next
Step 300; Toggle-Run
Reset-Current
Check 'reset clears the share' $script:People[1].Budget 0
Step 20
Undo-Last
Check 'undo after paused reset restores time exactly' (Get-Elapsed 1) 300
Check 'undo after paused reset stays paused' $script:Sw.IsRunning $false
Check 'undo after reset restores the share' $script:People[1].Budget 700

# A reset on the first speaker is recoverable too.
New-Meeting 6
Toggle-Run; Step 300
Reset-Current
Check 'undo hint after reset on speaker 1' ([bool](Test-UndoHint)) $true
Undo-Last
Check 'undo reset on speaker 1 restores elapsed' (Get-Elapsed 0) 300
Check 'successful undo consumes snapshot' ($null -eq $script:Undo) $true

# The exception: a finish lands on speaker 1 and must still be undoable (with a hint).
New-Meeting 2
Toggle-Run; Step 100; Go-Next; Step 100; Go-Next
Check 'undo hint after finish' ([bool](Test-UndoHint)) $true

# Reset on an untouched speaker must not overwrite a useful undo.
# After a finish, speaker 1 of the fresh meeting is untouched, so R there is a no-op.
New-Meeting 1
Toggle-Run; Step 100; Go-Next
Reset-Current
Undo-Last
Check 'no-op reset keeps the earlier undo' (Get-Elapsed 0) 100

# ---------------- speaker count changes ----------------
New-Meeting 6
Toggle-Run; Step 100; Go-Next; Step 100; Go-Next
Set-Count 2
Check 'shrinking below the current index clamps it' $script:Idx 1
Check 'shrinking keeps the speaker list valid' $script:People.Count 2

# ---------------- presenter bar ----------------
Add-Type -AssemblyName System.Drawing
$script:Scale = 1.0
$script:BarH = 52
$script:BarW = 180
$script:BarEdge = 'bottom'
$bar = Get-BarBounds (New-Object Drawing.Rectangle(1920, 0, 1920, 1040))
Check 'bar spans the full width along the bottom' ("{0},{1},{2}" -f $bar.X, $bar.Y, $bar.Width) '1920,988,1920'
Check 'bar height' $bar.Height 52

# ---------------- config (untrusted input) ----------------
$script:ConfigFile = Join-Path ([IO.Path]::GetTempPath()) ('mt-test-{0}.json' -f [guid]::NewGuid())
function Load-From([string]$json) {
    [IO.File]::WriteAllText($script:ConfigFile, $json)
    Load-Config
}
Check 'Bar defaults to off' (Load-From '{}').Bar $false
Check 'Bar true is read' (Load-From '{"Bar": true}').Bar $true
Check 'Bar as a string is rejected' (Load-From '{"Bar": "yes"}').Bar $false
Check 'Bar as a number is rejected' (Load-From '{"Bar": 1}').Bar $false
Check 'old configs default to bottom docking' (Load-From '{}').BarEdge 'bottom'
Check 'left docking is accepted' (Load-From '{"BarEdge": "left"}').BarEdge 'left'
Check 'invalid docking is rejected' (Load-From '{"BarEdge": "diagonal"}').BarEdge 'bottom'
Check 'docking boolean is rejected' (Load-From '{"BarEdge": true}').BarEdge 'bottom'
Check 'docking value is case-sensitive' (Load-From '{"BarEdge": "TOP"}').BarEdge 'bottom'
Check 'a JSON array falls back to defaults' (Load-From '[1,2,3]').Count 6
Check 'unknown theme falls back' (Load-From '{"Theme": "Dark"}').Theme 'light'
Remove-Item -LiteralPath $script:ConfigFile -ErrorAction SilentlyContinue

# ---------------- integrated regression scenarios ----------------
$screenArea = New-Object Drawing.Rectangle(-1920, -100, 1920, 1040)
foreach ($edge in @('top','bottom','left','right')) {
    $bounds = Get-BarBounds $screenArea $edge
    Check "$edge dock stays within monitor" ($screenArea.Contains($bounds)) $true
}
Check 'left dock width' (Get-BarBounds $screenArea 'left').Width 180
Check 'right dock aligns with screen edge' (Get-BarBounds $screenArea 'right').Right $screenArea.Right
foreach ($case in @(
    @(-1000, -100, 'top'), @(-1000, 940, 'bottom'),
    @(-1920, 400, 'left'), @(0, 400, 'right'))) {
    $point = New-Object Drawing.Point($case[0], $case[1])
    Check "nearest edge $($case[2])" (Get-NearestBarEdge $point $screenArea) $case[2]
}
$script:Scale = 2.0
Check 'dock scales height for high DPI' (Get-BarBounds $screenArea 'bottom').Height 104
Check 'dock scales vertical width for high DPI' (Get-BarBounds $screenArea 'right').Width 360
$script:Scale = 1.0

New-Meeting 3
$original = [datetime]'2026-01-05 13:00:00'
Check 'unmodified past end remains unchanged' (Resolve-EndTime $original $original) $original
$picked = [datetime]'2026-01-05 12:30:00'
Check 'changed past time means next day' (Resolve-EndTime $picked $original) ([datetime]'2026-01-06 12:30:00')

New-Meeting 1
Toggle-Run
Step 2519
Check 'long budget normal above 30 percent' (Get-Phase).Level 'normal'
Step 1
Check 'long budget notice at exactly 30 percent' (Get-Phase).Level 'notice'
Step 720
Check 'long budget critical at exactly 10 percent' (Get-Phase).Level 'critical'
Toggle-Run
Step 20
Check 'paused critical retains warning' (Get-Phase).Level 'critical'
Check 'paused warning does not run clock' (Get-Phase).Run 'pause'

New-Meeting 2 '15:01:00' '15:00:00'
$script:ConfirmResult = $false
Toggle-Run
Check 'declining overtime keeps timer idle' $script:Sw.IsRunning $false
Check 'declining overtime does not lock allocation' $script:People[0].Started $false
$script:ConfirmResult = $true
Toggle-Run
Check 'accepted overtime locks zero allocation' $script:People[0].Budget 0
Check 'zero allocation is marked started' $script:People[0].Started $true
Step 10
Check-Alerts
Check 'zero-budget start emits one overtime alarm' ($script:Sounds -join ',') 'Hand'
$script:ConfirmResult = $false
Go-Next
Check 'declining expired next preserves speaker' $script:Idx 0
$script:ConfirmResult = $true
Go-Next
Check 'expired next also has no invented time' $script:People[1].Budget 0
Check 'expired next starts recording overtime' $script:Sw.IsRunning $true
Undo-Last
Check 'undo restores zero-budget original speaker' $script:Idx 0
Check 'zero budget stays locked when resuming' (Get-Budget 0) 0

New-Meeting 2
Toggle-Run
Step 15
$script:ConfirmResult = $false
Reset-Current
Check 'cancelled reset preserves elapsed' (Get-Elapsed 0) 15
Check 'cancelled reset preserves running clock' $script:Sw.IsRunning $true

New-Meeting 6
Toggle-Run
Step 550
Check-Alerts
Check 'delayed tick emits only the critical warning' ($script:Sounds -join ',') 'Exclamation'
Step 51
Check-Alerts
Check 'delayed overtime emits one new alarm' ($script:Sounds -join ',') 'Exclamation,Hand'

Write-Host ("{0} passed, {1} failed" -f $script:Passes, $script:Fails)
exit $script:Fails
