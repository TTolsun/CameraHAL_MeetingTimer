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
