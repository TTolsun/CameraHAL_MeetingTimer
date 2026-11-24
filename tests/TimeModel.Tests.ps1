# TimeModel.Tests.ps1 - Scenario tests for the timer's time-sharing logic.
#
# Runs on stock Windows PowerShell 5.1 with nothing installed (no Pester):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\TimeModel.Tests.ps1
# Exit code is the number of failed checks.
#
# The test loads only the time model. A fake Get-Date and stopwatch share the
# same clock, so a one-hour meeting runs in well under a second.

$ErrorActionPreference = 'Stop'
$windows = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows'
. (Join-Path $windows 'TimeModel.ps1')

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

function Confirm-Overtime { $script:ConfirmCalls++; $script:ConfirmResult }

# Fresh meeting: $n speakers, clock at $at, meeting end at $end.
function New-Meeting([int]$n, [string]$at = '14:00:00', [string]$end = '15:00:00') {
    $script:FakeNow = [datetime]"2026-01-05 $at"
    $script:Sw = New-FakeStopwatch
    $script:ConfirmResult = $true
    $script:ConfirmCalls = 0
    Start-Meeting $n ([datetime]"2026-01-05 $end")
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
[void](Switch-RunState)
Check 'first speaker locks the share' $script:People[0].Budget 595
Check 'first plan is set on start' $script:Plan 595

# Overrun shrinks only the shares of people who have not started.
New-Meeting 6
[void](Switch-RunState); Step 720; [void](Move-ToNextSpeaker)
Check 'overrun: next share is (3600-720)/5' $script:People[1].Budget 576
Check 'overrun: first speaker keeps their share' $script:People[0].Budget 600
Check 'overrun: plan delta source unchanged' $script:Plan 600

# Finishing early grows the remaining shares.
New-Meeting 6
[void](Switch-RunState); Step 300; [void](Move-ToNextSpeaker)
Check 'early finish: next share is (3600-300)/5' $script:People[1].Budget 660

# While a locked speaker runs, the preview for the others reserves their remaining time.
New-Meeting 4
[void](Switch-RunState); Step 100
# Left 3500, current reserves 900-100=800, three unlocked: (3500-800)/3 = 900.
$pi = Get-Pending
Check 'pending excludes the locked speaker' $pi.Pending 3
Check 'reserved is the locked remainder' $pi.Reserved 800

# ---------------- minimum share and overbooking ----------------
New-Meeting 6 '14:57:00' '15:00:00'
Check 'overbooked when 6 x 1 min does not fit in 3 min' (Test-Overbooked) $true
Check 'preview never drops under the minimum' (Get-Preview) 60
[void](Switch-RunState)
Check 'locked share respects the minimum' $script:People[0].Budget 60
New-Meeting 3 '14:57:00' '15:00:00'
Check '3 x 1 min fits in 3 min' (Test-Overbooked) $false
Check 'Calc-Share with nobody pending' (Calc-Share 100 0 0 60) 0
Check 'Calc-Share floors to whole seconds' (Calc-Share 100 0 3 0) 33

# ---------------- quiet countdown and overtime ----------------
New-Meeting 6
[void](Switch-RunState)
Step 419; Check 'normal above 30 percent left' (Get-Phase).Level 'normal'
Step 1;   Check 'notice at 30 percent left' (Get-Phase).Level 'notice'
Step 120; Check 'critical at 10 percent left' (Get-Phase).Level 'critical'
Step 60
Check 'over at zero' (Get-Phase).Level 'over'
Check 'countdown text at zero' (Get-Phase).Text '+00:00'
Check 'zero overtime is neutral' (Get-Phase).Highlight $false
Step 14.999
Check 'last unaccented time still displays +00:14' (Get-Phase).Text '+00:14'
Check 'overtime below fifteen seconds is neutral' (Get-Phase).Highlight $false
Step 0.001
Check 'highlight begins at +00:15' (Get-Phase).Text '+00:15'
Check 'overtime at fifteen seconds is highlighted' (Get-Phase).Highlight $true
[void](Switch-RunState)
Step 30
Check 'paused overtime retains emphasis' (Get-Phase).Highlight $true
Check 'paused overtime retains its reading' (Get-Phase).Text '+00:15'

# A one-minute cue is visible even when one minute exceeds 30% of the allocation.
New-Meeting 1 '14:57:00' '15:00:00'
[void](Switch-RunState)
Step 119
Check 'three-minute share at 61 seconds is still quiet' (Get-Phase).Closing $false
Step 1
Check 'three-minute share is still above the 30% boundary' (Get-Phase).Level 'normal'
Check 'three-minute share shows the closing cue at one minute' (Get-Phase).Closing $true
New-Meeting 1 '14:58:00' '15:00:00'
[void](Switch-RunState)
Step 60
Check 'two-minute share also shows the cue at one minute' (Get-Phase).Closing $true

# Short shares use the same percentage boundaries.
New-Meeting 6 '14:57:00' '15:00:00'
[void](Switch-RunState)
Step 41; Check 'short share: normal at 19 s left' (Get-Phase).Level 'normal'
Step 1;  Check 'short share: notice at 18 s left' (Get-Phase).Level 'notice'
Step 12; Check 'short share: critical at 6 s left' (Get-Phase).Level 'critical'

# Pausing stops the speaker's clock but not the meeting clock.
New-Meeting 6
[void](Switch-RunState); Step 100; [void](Switch-RunState); Step 50
Check 'pause freezes elapsed' (Get-Elapsed 0) 100
Check 'pause state' (Get-Phase).Run 'pause'

# ---------------- next gating ----------------
New-Meeting 3
[void](Move-ToNextSpeaker)
Check 'next is ignored before the speaker starts' $script:Idx 0
Check 'ignored next leaves no undo' ($null -eq $script:Undo) $true
[void](Switch-RunState); Step 100; [void](Switch-RunState)
[void](Move-ToNextSpeaker)
Check 'next is ignored while paused' $script:Idx 0
[void](Switch-RunState)
[void](Move-ToNextSpeaker)
Check 'next works again once resumed' $script:Idx 1

# ---------------- undo ----------------
# Accidental Next while the speaker talks: they get the time back and keep running.
New-Meeting 6
[void](Switch-RunState); Step 200; [void](Move-ToNextSpeaker)
Check 'next moved on' $script:Idx 1
Check 'undo hint shows right after next' ([bool](Test-UndoHint)) $true
Step 15
Check 'undo hint fades after 10 s' ([bool](Test-UndoHint)) $false
[void](Restore-PreviousTurn)
Check 'undo returns to the previous speaker' $script:Idx 0
Check 'undo gives the time back' (Get-Elapsed 0) 215
Check 'undo keeps the clock running' $script:Sw.IsRunning $true
Check 'undo clears the next speaker share' $script:People[1].Budget 0
Check 'undo keeps the first share' $script:People[0].Budget 600
Step 5
Check 'clock still runs after undo' (Get-Elapsed 0) 220
[void](Restore-PreviousTurn)
Check 'second undo is a no-op' $script:Idx 0

# Accidental finish on the last speaker: the meeting comes back.
New-Meeting 2
[void](Switch-RunState); Step 1500; [void](Move-ToNextSpeaker)
Step 1000; [void](Move-ToNextSpeaker)
Check 'finish starts a fresh meeting' $script:Idx 0
Check 'fresh meeting has no history' (Get-Elapsed 1) 0
Step 10
[void](Restore-PreviousTurn)
Check 'undo after finish returns to the last speaker' $script:Idx 1
Check 'undo after finish restores their time' (Get-Elapsed 1) 1010
Check 'undo after finish restores the first speaker' (Get-Elapsed 0) 1500
Check 'undo after finish restores the end time' $script:End.ToString('HH:mm') '15:00'
Check 'undo after finish restores the plan' $script:Plan 1800

# Accidental reset, taken while paused: nothing is added for the paused gap.
New-Meeting 6
[void](Switch-RunState); Step 100; [void](Move-ToNextSpeaker)
Step 300; [void](Switch-RunState)
[void](Clear-CurrentSpeaker -ConfirmReset { $true })
Check 'reset clears the share' $script:People[1].Budget 0
Step 20
[void](Restore-PreviousTurn)
Check 'undo after paused reset restores time exactly' (Get-Elapsed 1) 300
Check 'undo after paused reset stays paused' $script:Sw.IsRunning $false
Check 'undo after reset restores the share' $script:People[1].Budget 700

# A reset on the first speaker is recoverable too.
New-Meeting 6
[void](Switch-RunState); Step 300
[void](Clear-CurrentSpeaker -ConfirmReset { $true })
Check 'undo hint after reset on speaker 1' ([bool](Test-UndoHint)) $true
[void](Restore-PreviousTurn)
Check 'undo reset on speaker 1 restores elapsed' (Get-Elapsed 0) 300
Check 'successful undo consumes snapshot' ($null -eq $script:Undo) $true

# The exception: a finish lands on speaker 1 and must still be undoable (with a hint).
New-Meeting 2
[void](Switch-RunState); Step 100; [void](Move-ToNextSpeaker); Step 100; [void](Move-ToNextSpeaker)
Check 'undo hint after finish' ([bool](Test-UndoHint)) $true

# Reset on an untouched speaker must not overwrite a useful undo.
# After a finish, speaker 1 of the fresh meeting is untouched, so R there is a no-op.
New-Meeting 1
[void](Switch-RunState); Step 100; [void](Move-ToNextSpeaker)
[void](Clear-CurrentSpeaker -ConfirmReset { $true })
[void](Restore-PreviousTurn)
Check 'no-op reset keeps the earlier undo' (Get-Elapsed 0) 100

# ---------------- fresh meeting settings ----------------
New-Meeting 6
[void](Switch-RunState); Step 30; [void](Move-ToNextSpeaker)
$selectedEnd = (Get-Date).AddMinutes(10)
Start-Meeting 2 $selectedEnd
Check 'restart uses selected count' $script:People.Count 2
Check 'restart keeps selected end' $script:End $selectedEnd
Check 'restart begins at first speaker' $script:Idx 0
Check 'restart clock waits for start' $script:Sw.IsRunning $false
Check 'restart clears previous time' (Get-Elapsed 0) 0
Check 'restart clears the first plan' $script:Plan 0
Check 'restart clears undo' (Test-UndoAllowed) $false
Check 'fresh meeting uses all remaining time' (Get-Preview) 300
Check 'exact minute per speaker fits' (Get-ScheduleIssue 2 (Get-Date).AddSeconds(120)) $null
Check 'one second short requires adjustment' ([bool](Get-ScheduleIssue 2 (Get-Date).AddSeconds(119))) $true
Check 'expired deadline gives a reason' ((Get-ScheduleIssue 1 (Get-Date)) -match 'has passed') $true
Check 'fewer than sixty seconds cannot support one speaker' ([bool](Get-ScheduleIssue 1 (Get-Date).AddSeconds(59))) $true
Check 'app speaker limit has its own explanation' ((Get-ScheduleIssue 51 (Get-Date).AddHours(3)) -match 'up to 50 speakers') $true

# ---------------- integrated regression scenarios ----------------
New-Meeting 3
$original = [datetime]'2026-01-05 13:00:00'
Check 'unmodified past end remains unchanged' (Resolve-EndTime $original $original) $original
$picked = [datetime]'2026-01-05 12:30:00'
Check 'changed past time means next day' (Resolve-EndTime $picked $original) ([datetime]'2026-01-06 12:30:00')

New-Meeting 1
[void](Switch-RunState)
Step 2519
Check 'long budget normal above 30 percent' (Get-Phase).Level 'normal'
Step 1
Check 'long budget notice at exactly 30 percent' (Get-Phase).Level 'notice'
Step 720
Check 'long budget critical at exactly 10 percent' (Get-Phase).Level 'critical'
[void](Switch-RunState)
Step 20
Check 'paused critical retains warning' (Get-Phase).Level 'critical'
Check 'paused warning does not run clock' (Get-Phase).Run 'pause'

# The first plan records the even split before the minimum allocation is applied.
New-Meeting 2 '14:58:30' '15:00:00'
Check '90 seconds for two speakers previews the minimum allocation' (Get-Preview) 60
Check '90 seconds for two speakers is overbooked' (Test-Overbooked) $true
Check 'idle meeting has no plan difference' (Get-PlanDifference) 0
Check 'first speaker starts before the deadline' (Switch-RunState) $true
Check '90 seconds for two speakers locks a one-minute share' $script:People[0].Budget 60
Check 'first plan uses the even split before the one-minute minimum' $script:Plan 45
Check 'first allocation displays fifteen seconds above the plan' (Get-PlanDifference) 15

New-Meeting 2 '14:50:00' '15:00:00'
[void](Switch-RunState)
Check 'ten minutes for two speakers sets a five-minute plan' $script:Plan 300
Step 60
[void](Move-ToNextSpeaker)
Check 'finishing after one minute gives the next speaker nine minutes' $script:People[1].Budget 540
Check 'early finish keeps the first plan' $script:Plan 300
Check 'early finish adds four minutes above the first plan' (Get-PlanDifference) 240
Check "early finish commits the first speaker's minute" (Get-Elapsed 0) 60
Step 12
Check 'early finish can be undone' (Restore-PreviousTurn) $true
Check 'undo returns to the first speaker' $script:Idx 0
Check 'undo adds the time since the transition to the first speaker' (Get-Elapsed 0) 72
Check 'undo restores the original plan comparison' (Get-PlanDifference) 0
Check 'undo consumes the snapshot' (Test-UndoAllowed) $false

# Arrive at the deadline while speaking, before switching to the final speaker.
New-Meeting 3 '14:54:00' '15:00:00'
[void](Switch-RunState)
Step 60
[void](Move-ToNextSpeaker)
$priorUndo = $script:Undo
Step 301
$script:ConfirmResult = $false
Check 'declining expired next reports no transition' (Move-ToNextSpeaker -ConfirmOvertime ${function:Confirm-Overtime}) $false
Check 'expired next requests confirmation' $script:ConfirmCalls 1
Check 'declining expired next preserves speaker' $script:Idx 1
Check 'declining expired next preserves elapsed time' (Get-Elapsed 1) 301
Check 'declining expired next preserves the existing undo' ([object]::ReferenceEquals($priorUndo, $script:Undo)) $true
Check 'declining expired next leaves the next speaker unstarted' $script:People[2].Started $false
$script:ConfirmResult = $true
Check 'accepting expired next advances' (Move-ToNextSpeaker -ConfirmOvertime ${function:Confirm-Overtime}) $true
Check 'accepting expired next requests confirmation again' $script:ConfirmCalls 2
Check 'expired next increments the speaker' $script:Idx 2
Check 'expired next locks a zero-second allocation' $script:People[2].Budget 0
Check 'zero allocation is marked started' $script:People[2].Started $true
Check 'expired next starts recording overtime' $script:Sw.IsRunning $true
Step 10
Check 'approved expired next records ten seconds of overtime' (Get-Phase).Text '+00:10'
Check 'approved expired next can be undone' (Restore-PreviousTurn) $true
Check 'undo restores the previous speaker' $script:Idx 1
Check 'undo returns the added ten seconds to the original speaker' (Get-Elapsed 1) 311
Check 'undo restores the previous locked budget' $script:People[1].Budget 150
Check 'undo preserves the first plan' $script:Plan 120
Check 'undo resumes the previous speaker' $script:Sw.IsRunning $true

New-Meeting 2 '15:01:00' '15:00:00'
$script:ConfirmResult = $false
[void](Switch-RunState -ConfirmOvertime ${function:Confirm-Overtime})
Check 'declining overtime keeps timer idle' $script:Sw.IsRunning $false
Check 'declining overtime does not lock allocation' $script:People[0].Started $false
$script:ConfirmResult = $true
[void](Switch-RunState -ConfirmOvertime ${function:Confirm-Overtime})
Check 'accepted overtime locks zero allocation' $script:People[0].Budget 0
Check 'zero allocation is marked started' $script:People[0].Started $true
[void](Switch-RunState)
Check 'a started overtime speaker resumes without reconfirmation' (Switch-RunState) $true
Check 'zero budget stays locked when resuming' (Get-Budget 0) 0

New-Meeting 2
[void](Switch-RunState)
Step 15
[void](Clear-CurrentSpeaker -ConfirmReset { $false })
Check 'cancelled reset preserves elapsed' (Get-Elapsed 0) 15
Check 'cancelled reset preserves running clock' $script:Sw.IsRunning $true

# Wrap-up planning and the wall-clock countdown.
New-Meeting 2
Start-Meeting 2 $script:End -WrapMinutes 5
Check 'wrap-up starts with a 14:55 speaking cutoff' (Get-Preview) 1650
[void](Switch-RunState)
Step 1500
[void](Move-ToNextSpeaker)
Check 'early finish redistributes only speaking time' (Get-Budget 1) 1800
Step 1740
Check 'one advance starts wrap-up' (Move-ToNextSpeaker) $true
Check 'an early wrap-up uses the real meeting deadline' (Get-Phase).Text '06:00'
Check 'wrap-up does not pause' (Switch-RunState) $false
Step 390
Check 'wrap-up tracks overtime beyond the deadline' (Get-Phase).Text '+00:30'
[void](Move-ToNextSpeaker)
Check 'finish prepares the next meeting with the original reserve' $script:WrapReserve 300
Step 10
[void](Restore-PreviousTurn)
Check 'undo finish restores wrap-up against the original deadline' (Get-Phase).Text '+00:40'
[void](Restore-PreviousTurn)
Check 'undo wrap-up restores the running final speaker' $script:Sw.IsRunning $true
Check 'undo wrap-up restores time to the final speaker' (Get-Elapsed 1) 2140
Check 'wrap-up can start after the scheduled end' (Move-ToNextSpeaker) $true
Check 'late entry immediately shows actual overtime' (Get-Phase).Text '+00:40'

New-Meeting 2 '14:54:00'
Start-Meeting 2 $script:End -WrapMinutes 5
$options = Get-WrapOptions 0
Check 'keeping five minutes budgets thirty seconds each' $options.KeepShare 30
Check 'using wrap-up time allows one minute each' $options.UseShare 60
Check 'using wrap-up time leaves four minutes' $options.Reserve 240
Check 'cancelling the conflict leaves the speaker idle' (Switch-RunState -ChooseWrap { 'cancel' }) $false
Check 'keeping the reserve uses the shorter budget' (Switch-RunState -ChooseWrap { 'keep' }) $true
Check 'keep locks a thirty-second budget' (Get-Budget 0) 30
Start-Meeting 2 $script:End -WrapMinutes 5
[void](Switch-RunState -ChooseWrap { 'use' })
Check 'use locks a one-minute budget' (Get-Budget 0) 60
Check 'use changes the current reserve' $script:WrapReserve 240
Step 180
Check 'keep estimates only wrap-up time still available' (Get-WrapOptions 1).KeepReserve 180
[void](Move-ToNextSpeaker -ChooseWrap { 'use' })
[void](Restore-PreviousTurn)
Check 'undo the next speaker restores the prior reserve' $script:WrapReserve 240

New-Meeting 2 '14:54:00'
Start-Meeting 2 $script:End -WrapMinutes 5
Check 'a wrap choice left open past the deadline requires overtime consent' (Switch-RunState -ChooseWrap { Step 361; 'use' }) $false
Check 'declining overtime preserves the reserve' $script:WrapReserve 300

Write-Host ("{0} passed, {1} failed" -f $script:Passes, $script:Fails)
exit $script:Fails
