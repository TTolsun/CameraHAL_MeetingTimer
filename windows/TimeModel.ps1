# Minimum share per speaker, in seconds.
$script:MinShare = 60

# Default meeting end: the next full hour, or the one after it when the next one is less
# than 10 minutes away (opening the timer at 13:55 for a 14:00 meeting gives 15:00, not 14:00).
function Get-NextHour {
    $now = Get-Date
    $end = $now.Date.AddHours($now.Hour + 1)
    if (($end - $now).TotalMinutes -lt 10) { $end = $end.AddHours(1) }
    $end
}

# ---------------- time helpers ----------------
function Fmt([double]$sec) {
    $s = [int][math]::Floor([math]::Abs($sec))
    '{0:00}:{1:00}' -f [int][math]::Floor($s / 60), ($s % 60)
}

function Get-Elapsed([int]$i) {
    $p = $script:People[$i]
    if ($i -eq $script:Idx) { $p.Used + $script:Sw.Elapsed.TotalSeconds } else { $p.Used }
}

function Get-MeetingLeft { ($script:End - (Get-Date)).TotalSeconds }

# Pure share calculation (no clock or UI state) so it can be checked in isolation.
# Whoever finished early leaves no reserved time, so their unused seconds flow into
# $left and are split evenly across the speakers who have not started.
function Calc-Share([double]$left, [double]$reserved, [int]$pending, [double]$min = 0) {
    if ($pending -le 0) { return 0 }
    $share = [math]::Max(0, $left - $reserved) / $pending
    # Whole seconds: while a speaker waits to start, the share follows the clock second by second.
    [math]::Max($min, [math]::Floor($share))
}

# Time the current (locked) speaker still has, and how many speakers have no share yet.
function Get-Pending {
    $cur = $script:People[$script:Idx]
    $reserved = 0.0
    if ($cur.Budget -gt 0) { $reserved = [math]::Max(0, $cur.Budget - (Get-Elapsed $script:Idx)) }
    $pending = @(for ($j = $script:Idx; $j -lt $script:People.Count; $j++) { if (-not $script:People[$j].Started) { $j } }).Count
    [pscustomobject]@{ Reserved = $reserved; Pending = $pending }
}

# Share for a speaker who has not started yet: the meeting time that is left,
# minus what the current (locked) speaker still has, split across everyone unlocked.
function Get-Preview {
    if ((Get-MeetingLeft) -le 0) { return 0 }
    $pi = Get-Pending
    Calc-Share (Get-MeetingLeft) $pi.Reserved $pi.Pending $script:MinShare
}

# True when the one-minute minimum no longer fits before the meeting end time.
function Test-Overbooked {
    $pi = Get-Pending
    $pi.Pending -gt 0 -and ((Get-MeetingLeft) - $pi.Reserved) -lt ($pi.Pending * $script:MinShare)
}

function Get-Budget([int]$i) {
    $b = $script:People[$i].Budget
    if ($script:People[$i].Started) { $b } else { Get-Preview }
}

function Lock-Budget {
    $p = $script:People[$script:Idx]
    if (-not $p.Started) {
        # The first plan is the share at the moment the first speaker starts, before any minimum is applied.
        if ($script:Plan -le 0) {
            $pi = Get-Pending
            $script:Plan = Calc-Share (Get-MeetingLeft) $pi.Reserved $pi.Pending 0
        }
        $p.Budget = Get-Preview
        $p.Started = $true
    }
}

function Get-Phase {
    $budget = Get-Budget $script:Idx
    $el = Get-Elapsed $script:Idx
    $rem = $budget - $el
    # Keep phase boundaries relative to the locked budget; the final minute also shows guidance.
    $noticeAt = $budget * 0.3
    $criticalAt = $budget * 0.1
    $started = $script:People[$script:Idx].Started
    $level = if (-not $started -and $rem -le 0) { 'normal' } elseif ($rem -le 0) { 'over' } elseif ($rem -le $criticalAt) { 'critical' } elseif ($rem -le $noticeAt) { 'notice' } else { 'normal' }
    $run = if ($script:Sw.IsRunning) { 'run' } elseif (-not $started) { 'idle' } else { 'pause' }
    $text = if (-not $started -and $rem -le 0) { '00:00' } elseif ($rem -gt 0) { Fmt ([math]::Ceiling($rem)) } else { '+' + (Fmt ([math]::Floor(-$rem))) }
    $closing = $run -eq 'run' -and $rem -gt 0 -and ($rem -le 60 -or $rem -le $noticeAt)
    [pscustomobject]@{ El = $el; Rem = $rem; Budget = $budget; Level = $level; Run = $run; Text = $text; Closing = $closing; Highlight = $started -and $rem -le -15 }
}

function New-Person {
    [pscustomobject]@{ Used = 0.0; Budget = 0.0; Started = $false }
}

function Get-PlanDifference {
    if ($script:Plan -le 0) { return 0 }
    [math]::Round((Get-Budget $script:Idx) - $script:Plan)
}

# ---------------- meeting transitions ----------------
function Start-Meeting([int]$count, [datetime]$endTime = (Get-NextHour), [switch]$keepUndo) {
    $script:Sw.Reset()
    $script:People = @(1..$count | ForEach-Object { New-Person })
    $script:Idx = 0
    $script:End = $endTime
    $script:Plan = 0.0
    if (-not $keepUndo) { $script:Undo = $null }
}

function Switch-RunState([scriptblock]$confirmOvertime = { $false }) {
    if ($script:Sw.IsRunning) {
        $script:Sw.Stop()
    } else {
        if (-not (Test-SpeakerStart $script:Idx $confirmOvertime)) { return $false }
        Lock-Budget
        $script:Sw.Start()
    }
    $true
}

function Test-SpeakerStart([int]$i, [scriptblock]$confirmOvertime) {
    if (-not $script:People[$i].Started -and (Get-MeetingLeft) -le 0) {
        return (& $confirmOvertime)
    }
    $true
}

function Move-ToNextSpeaker([scriptblock]$confirmOvertime = { $false }) {
    if (-not $script:Sw.IsRunning) { return $false }
    $next = $script:Idx + 1
    if ($next -eq $script:People.Count) {
        Save-Undo 'finish'
        Start-Meeting $script:People.Count -KeepUndo
        return $true
    }
    if (-not (Test-SpeakerStart $next $confirmOvertime)) { return $false }
    Save-Undo 'next'
    $script:People[$script:Idx].Used = Get-Elapsed $script:Idx
    $script:Sw.Reset()
    $script:Idx = $next
    Lock-Budget
    $script:Sw.Start()
    $true
}

function Clear-CurrentSpeaker([scriptblock]$confirmReset = { $false }) {
    $wasRunning = $script:Sw.IsRunning
    # Nothing to clear: keep any earlier undo instead of overwriting it with a no-op.
    if (-not $wasRunning -and (Get-Elapsed $script:Idx) -eq 0 -and $script:People[$script:Idx].Budget -eq 0) { return $false }
    if (-not (& $confirmReset)) { return $false }
    Save-Undo 'reset'
    $script:Sw.Reset()
    $script:People[$script:Idx] = New-Person
    if ($wasRunning -and (Get-MeetingLeft) -gt 0) { Lock-Budget; $script:Sw.Start() }
    $true
}

# ---------------- undo ----------------
# One level of undo for the keys that cannot be taken back otherwise: Next (including the
# finish that starts a fresh meeting) and Reset. The time that passed since then belongs to
# the speaker who was talking, so it is given back to them if their clock was running.
function Save-Undo([string]$kind) {
    $copy = @($script:People | ForEach-Object { $_.PSObject.Copy() })
    # Fold the running stopwatch into the snapshot.
    $copy[$script:Idx].Used = Get-Elapsed $script:Idx
    $script:Undo = [pscustomobject]@{
        Kind = $kind; People = $copy; Idx = $script:Idx; End = $script:End
        Plan = $script:Plan; Running = $script:Sw.IsRunning; At = Get-Date
    }
}

# Recover the last destructive action, including a reset on the first speaker.
function Test-UndoAllowed {
    $null -ne $script:Undo
}

function Restore-PreviousTurn {
    $u = $script:Undo
    if (-not (Test-UndoAllowed)) { return $false }
    $script:Undo = $null
    $script:Sw.Reset()
    $script:People = $u.People
    $script:Idx = $u.Idx
    $script:End = $u.End
    $script:Plan = $u.Plan
    if ($u.Running) {
        $script:People[$script:Idx].Used += [math]::Max(0, ((Get-Date) - $u.At).TotalSeconds)
        $script:Sw.Start()
    }
    $true
}

# True for a few seconds after an undoable action, so the coaching line can offer Ctrl+Z.
function Test-UndoHint {
    (Test-UndoAllowed) -and ((Get-Date) - $script:Undo.At).TotalSeconds -lt 10
}

# ---------------- settings schedule ----------------
# Resolves the HH:mm picked in the settings dialog to the next time it occurs (today, or tomorrow if past).
function Resolve-EndTime([datetime]$picked, [datetime]$original) {
    if ($picked.Hour -eq $original.Hour -and $picked.Minute -eq $original.Minute) { return $original }
    $now = Get-Date
    $end = $now.Date.AddHours($picked.Hour).AddMinutes($picked.Minute)
    if ($end -le $now) { $end = $end.AddDays(1) }
    $end
}

# Validate a fresh meeting against all speakers, including anyone who spoke in the old one.
function Get-ScheduleIssue([long]$count, [datetime]$end) {
    if ($count -gt 50) { return 'A meeting supports up to 50 speakers.' }
    $remaining = ($end - (Get-Date)).TotalSeconds
    $seconds = [math]::Max(0, [math]::Floor($remaining))
    $capacity = [int][math]::Floor($seconds / $script:MinShare)
    if ($count -le $capacity) { return }
    $need = [int][math]::Ceiling($count * $script:MinShare / 60)
    $reason = if ($remaining -le 0) { 'The selected end time has passed.' } else {
        'Time left: {0} min {1} sec.' -f [math]::Floor($seconds / 60), ($seconds % 60)
    }
    $next = if ($capacity -ge 1) { "Use at most ${capacity} speakers or choose a later end time." }
            else { 'Choose a later end time.' }
    "$reason`nSpeaker count: ${count}. Allow at least ${need} min (1 min each).`n`n$next"
}
