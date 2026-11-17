# CameraHAL_MeetingTimer.ps1 - Compact weekly meeting speaker timer (Windows PowerShell 5.1 + WinForms)
#
# - Meeting end defaults to the next full hour after launch (14:05 -> 15:00).
# - Enter only the number of speakers; the remaining meeting time is split
#   automatically. Each speaker's share is locked when they start, so an
#   overrun shrinks the shares of the people still waiting.
# - Small always-on-top window in the bottom-right corner. When a speaker runs
#   out of time while the window is minimized or in the background, its taskbar
#   button flashes.
#
# Visual style follows the HP-inspired DESIGN.md (getdesign.md/hp): white canvas,
# #1a1a1a ink, a single #024ad8 accent, 4px buttons, 1px hairlines.
# Launch with CameraHAL_MeetingTimer.bat (WinForms needs a single-threaded apartment, hence -STA).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('MtButton' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class MtNative {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    // Dark title bar to match the dark theme (attribute 20 on current Windows 10/11, 19 on early 20H1 builds).
    public static void DarkTitle(IntPtr h, bool on) {
        int v = on ? 1 : 0;
        try {
            if (DwmSetWindowAttribute(h, 20, ref v, 4) != 0) DwmSetWindowAttribute(h, 19, ref v, 4);
        } catch { }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    // Flash caption + taskbar button until the window comes to the foreground.
    public static void Flash(IntPtr h) {
        FLASHWINFO f = new FLASHWINFO();
        f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        f.hwnd = h;
        f.dwFlags = 3 | 12;            // FLASHW_ALL | FLASHW_TIMERNOFG
        f.uCount = uint.MaxValue;
        f.dwTimeout = 0;
        FlashWindowEx(ref f);
    }

    public static GraphicsPath Round(RectangleF r, float rad) {
        GraphicsPath p = new GraphicsPath();
        if (rad <= 0.5f) { p.AddRectangle(r); return p; }
        float d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}

// Flicker-free surface that the script paints itself.
public class MtCanvas : Panel {
    public MtCanvas() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
    }
}

// Rounded flat button. Not selectable, so Space/N/P always reach the form's key handler.
public class MtButton : Control {
    public Color Fill = Color.White, Fore = Color.Black, Border = Color.Empty, HoverFill = Color.Empty, PressFill = Color.Empty;
    public int Radius = 4;
    private bool hover, press;

    public MtButton() {
        SetStyle(ControlStyles.Selectable, false);
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        TabStop = false;
        Cursor = Cursors.Hand;
    }

    public void SetColors(Color fill, Color fore, Color border, Color hoverFill, Color pressFill) {
        Fill = fill; Fore = fore; Border = border; HoverFill = hoverFill; PressFill = pressFill;
        Invalidate();
    }

    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; press = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { press = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { press = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(Parent != null ? Parent.BackColor : BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color f = Fill;
        if (press && PressFill != Color.Empty) f = PressFill;
        else if (hover && HoverFill != Color.Empty) f = HoverFill;
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 2f, Height - 2f);
        using (GraphicsPath p = MtNative.Round(r, Math.Min(Radius, Height / 2f - 1))) {
            using (SolidBrush b = new SolidBrush(f)) g.FillPath(b, p);
            if (Border != Color.Empty) using (Pen pen = new Pen(Border, 1f)) g.DrawPath(pen, p);
        }
        g.SmoothingMode = SmoothingMode.None;
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, Fore,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
            TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
    }
}
'@
}

# Render sharply on high-DPI screens; every pixel size below goes through S.
[void][MtNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:Scale = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero).DpiX / 96.0
function S([double]$v) { [int][math]::Round($v * $script:Scale) }

$script:Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigFile = Join-Path $script:Dir 'config.json'

# ---------------- design tokens ----------------
function Col([string]$hex) { [Drawing.ColorTranslator]::FromHtml($hex) }
# Note: never name a local variable $c - PowerShell names are case-insensitive.
# Colors are named by ROLE, not by hue, so the same code paints both themes
# ("Paper" is white in light and near-black in dark). The settings dialog always
# uses the light table ($Themes.light); the active table is $C.
function New-Theme([hashtable]$hex) {
    $t = @{}
    foreach ($k in $hex.Keys) { if ($hex[$k]) { $t[$k] = Col $hex[$k] } else { $t[$k] = [Drawing.Color]::Empty } }
    $t
}
$Themes = @{
    light = New-Theme @{
        Paper = '#ffffff'; Ink = '#1a1a1a'; Sub = '#636363'; Hair = '#e8e8e8'; Band = '#f7f7f7'
        Strip = '#1a1a1a'; StripInk = '#ffffff'; StripMute = '#c2c2c2'; StripHover = '#292929'
        Accent = '#024ad8'; Plus = '#8fb4ff'; Warn = '#ff5050'; Zero = '#636363'
        Crit = '#b3262b'; OverBg = '#b3262b'; OverPulse = '#5a1313'; OverInk = '#ffffff'; OverSub = '#f9d4d2'
        IdleInk = '#3d3d3d'; IdleLine = '#c2c2c2'; Done = '#3d3d3d'
        BtnPrimary = '#024ad8'; BtnPrimaryInk = '#ffffff'; BtnPrimaryHover = '#0340b8'; BtnPrimaryPress = '#0e3191'
        BtnInk = '#1a1a1a'; BtnInkText = '#ffffff'; BtnInkLine = ''; BtnInkHover = '#292929'; BtnInkPress = '#000000'
    }
    # Dark follows the Raycast DESIGN.md (getdesign.md/raycast): near-black canvas,
    # hairline borders and one accent per state (blue, red).
    dark = New-Theme @{
        Paper = '#07080a'; Ink = '#f4f4f6'; Sub = '#9c9c9d'; Hair = '#242728'; Band = '#0d0d0d'
        Strip = '#0d0d0d'; StripInk = '#f4f4f6'; StripMute = '#9c9c9d'; StripHover = '#1c1c1d'
        Accent = '#57c1ff'; Plus = '#57c1ff'; Warn = '#ff6161'; Zero = '#6a6b6c'
        Crit = '#ff6161'; OverBg = '#a1131a'; OverPulse = '#5a0a0f'; OverInk = '#ffffff'; OverSub = '#f9d4d2'
        IdleInk = '#cdcdcd'; IdleLine = '#434345'; Done = '#8a8a8c'
        BtnPrimary = '#ffffff'; BtnPrimaryInk = '#000000'; BtnPrimaryHover = '#e8e8e8'; BtnPrimaryPress = '#cfcfcf'
        BtnInk = '#121212'; BtnInkText = '#f4f4f6'; BtnInkLine = '#3a3d3f'; BtnInkHover = '#1c1c1d'; BtnInkPress = '#242728'
    }
}
$NoColor = [Drawing.Color]::Empty
$C = $Themes.light

$installed = @((New-Object Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
function Pick-Font([string[]]$cands, [string]$fallback) {
    foreach ($name in $cands) { if ($installed -contains $name) { return $name } }
    $fallback
}
$famKo    = Pick-Font @('Pretendard', 'Pretendard Variable') 'Malgun Gothic'
$famKoMed = Pick-Font @('Pretendard Medium', 'Pretendard SemiBold') ''
# Segoe UI digits are tabular, so the countdown never jitters sideways.
$famNum   = Pick-Font @('Segoe UI Semibold') 'Segoe UI'
$numStyle = if ($famNum -eq 'Segoe UI') { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }

$script:Fonts = @{}
function Font-Px([string]$fam, [double]$px, [Drawing.FontStyle]$style = [Drawing.FontStyle]::Regular) {
    $px = [math]::Max(6, [math]::Round($px))
    $key = "$fam|$px|$style"
    if (-not $script:Fonts.ContainsKey($key)) {
        $script:Fonts[$key] = New-Object Drawing.Font($fam, [float]$px, $style, [Drawing.GraphicsUnit]::Pixel)
    }
    $script:Fonts[$key]
}
function FK([double]$px)  { Font-Px $famKo ($px * $script:Scale) }
function FKM([double]$px) {
    if ($famKoMed) { Font-Px $famKoMed ($px * $script:Scale) } else { Font-Px $famKo ($px * $script:Scale) ([Drawing.FontStyle]::Bold) }
}
function FN([double]$px)  { Font-Px $famNum ($px * $script:Scale) $numStyle }

# ---------------- config ----------------
function Load-Config {
    $cfg = [pscustomobject]@{ Count = 6; Sound = $true; TopMost = $true; Theme = 'light' }
    # config.json is treated as untrusted data: plain JSON only (no object
    # deserialization), size-capped, and every field type- and range-checked.
    # Anything unexpected falls back to the defaults above.
    try {
        $fi = Get-Item -LiteralPath $script:ConfigFile -ErrorAction Stop
        if ($fi.PSIsContainer -or $fi.Length -gt 4KB) { return $cfg }
        $j = [IO.File]::ReadAllText($fi.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
        # Must be a JSON object; an array would expose its own .Count property.
        if ($j -isnot [System.Management.Automation.PSCustomObject]) { return $cfg }
        # Older versions saved the key as "Count"; read it only if it is really present.
        $raw = $j.PSObject.Properties['Speakers']
        if (-not $raw) { $raw = $j.PSObject.Properties['Count'] }
        $n = 0
        if ($raw -and $raw.Value -is [int] -and [int]::TryParse("$($raw.Value)", [ref]$n) -and $n -ge 1 -and $n -le 50) { $cfg.Count = $n }
        if ($j.Sound -is [bool]) { $cfg.Sound = $j.Sound }
        if ($j.TopMost -is [bool]) { $cfg.TopMost = $j.TopMost }
        # Only the two known theme names are accepted; anything else keeps the default.
        if ($j.Theme -is [string] -and ($j.Theme -ceq 'light' -or $j.Theme -ceq 'dark')) { $cfg.Theme = $j.Theme }
    } catch { }
    $cfg
}

function Save-Config {
    # "Speakers", not "Count": .Count is a built-in PowerShell property and would
    # silently read as 1 when the key is missing.
    $json = [pscustomobject]@{
        Speakers = [int]$script:People.Count
        Sound    = [bool]$script:Sound
        TopMost  = [bool]$form.TopMost
        Theme    = [string]$script:ThemeName
    } | ConvertTo-Json
    [IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object Text.UTF8Encoding $false))
}

# Default meeting end: the next full hour, or the one after it when the next one is less
# than 10 minutes away (opening the timer at 13:55 for a 14:00 meeting gives 15:00, not 14:00).
function Get-NextHour {
    $now = Get-Date
    $end = $now.Date.AddHours($now.Hour + 1)
    if (($end - $now).TotalMinutes -lt 10) { $end = $end.AddHours(1) }
    $end
}

$script:Cfg = Load-Config
$script:Sound = $script:Cfg.Sound
$script:ThemeName = $script:Cfg.Theme
$C = $Themes[$script:ThemeName]
$script:End = Get-NextHour
$script:Sw = New-Object System.Diagnostics.Stopwatch
$script:People = @()
$script:Idx = 0
$script:EndFlashed = $false
# Minimum share per speaker (seconds) and the first plan, fixed when the first speaker starts (0 = not set).
$script:MinShare = 60
$script:Plan = 0.0

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
    $pending = @(for ($j = $script:Idx; $j -lt $script:People.Count; $j++) { if ($script:People[$j].Budget -eq 0) { $j } }).Count
    [pscustomobject]@{ Reserved = $reserved; Pending = $pending }
}

# Share for a speaker who has not started yet: the meeting time that is left,
# minus what the current (locked) speaker still has, split across everyone unlocked.
function Get-Preview {
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
    if ($b -gt 0) { $b } else { Get-Preview }
}

function Lock-Budget {
    $p = $script:People[$script:Idx]
    if ($p.Budget -eq 0) {
        # The first plan is the share at the moment the first speaker starts, before any minimum is applied.
        if ($script:Plan -le 0) {
            $pi = Get-Pending
            $script:Plan = Calc-Share (Get-MeetingLeft) $pi.Reserved $pi.Pending 0
        }
        $p.Budget = [math]::Max($script:MinShare, (Get-Preview))
    }
}

# Recomputes the first plan from the current state (used when settings change).
function Reset-Plan {
    $script:Plan = 0.0
    $cur = $script:People[$script:Idx]
    if ($cur.Budget -gt 0) {
        $n = $script:People.Count - $script:Idx
        $script:Plan = Calc-Share ((Get-MeetingLeft) + (Get-Elapsed $script:Idx)) 0 $n 0
    }
}

function Get-Phase {
    $budget = Get-Budget $script:Idx
    $el = Get-Elapsed $script:Idx
    $rem = $budget - $el
    # Warning points scale down for short shares.
    $noticeAt = [math]::Min(120, $budget * 0.3)
    $criticalAt = [math]::Min(60, $budget * 0.15)
    $level = if ($rem -le 0) { 'over' } elseif ($rem -le $criticalAt) { 'critical' } elseif ($rem -le $noticeAt) { 'notice' } else { 'normal' }
    $run = if ($script:Sw.IsRunning) { 'run' } elseif ($el -eq 0) { 'idle' } else { 'pause' }
    $text = if ($rem -gt 0) { Fmt ([math]::Ceiling($rem)) } else { '+' + (Fmt ([math]::Floor(-$rem))) }
    [pscustomobject]@{ El = $el; Rem = $rem; Budget = $budget; Level = $level; Run = $run; Text = $text; NoticeAt = $noticeAt; CriticalAt = $criticalAt }
}

function New-Person {
    [pscustomobject]@{ Used = 0.0; Budget = 0.0; W2 = $false; W1 = $false; Zero = $false; Over = 0 }
}

function Play([string]$kind) {
    if ($script:Sound) { [System.Media.SystemSounds]::$kind.Play() }
}

function Test-Background {
    $form.WindowState -eq 'Minimized' -or [MtNative]::GetForegroundWindow() -ne $form.Handle
}

function Flash-IfHidden {
    if (Test-Background) { [MtNative]::Flash($form.Handle) }
}

# ---------------- drawing helpers ----------------
function Draw-Text($g, [string]$text, $font, $color, [int]$x, [int]$y, [int]$w, [int]$h, [string]$align = 'Left') {
    $f = [Windows.Forms.TextFormatFlags]'VerticalCenter, SingleLine, EndEllipsis, NoPadding'
    if ($align -eq 'Center') { $f = $f -bor [Windows.Forms.TextFormatFlags]::HorizontalCenter }
    elseif ($align -eq 'Right') { $f = $f -bor [Windows.Forms.TextFormatFlags]::Right }
    [Windows.Forms.TextRenderer]::DrawText($g, $text, $font, (New-Object Drawing.Rectangle($x, $y, $w, $h)), $color, $f)
}

function Measure-W([string]$text, $font) {
    [Windows.Forms.TextRenderer]::MeasureText($text, $font, (New-Object Drawing.Size(10000, 1000)),
        [Windows.Forms.TextFormatFlags]'SingleLine, NoPadding').Width
}

function Fill-Round($g, $color, [double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    if ($w -le 0 -or $h -le 0) { return }
    $g.SmoothingMode = 'AntiAlias'
    $path = [MtNative]::Round((New-Object Drawing.RectangleF($x, $y, $w, $h)), [math]::Min($r, [math]::Min($h, $w) / 2))
    $b = New-Object Drawing.SolidBrush($color)
    $g.FillPath($b, $path)
    $b.Dispose(); $path.Dispose()
    $g.SmoothingMode = 'None'
}

# Badge pill. $x is the right edge. Returns the pill width.
function Draw-PillRight($g, [string]$text, $font, $fill, $fore, $border, [int]$x, [int]$y, [int]$h) {
    $w = (Measure-W $text $font) + (S 18)
    $x = $x - $w
    $g.SmoothingMode = 'AntiAlias'
    $path = [MtNative]::Round((New-Object Drawing.RectangleF(($x + 0.5), ($y + 0.5), ($w - 1), ($h - 1))), (S 8))
    if (-not $fill.IsEmpty) { $b = New-Object Drawing.SolidBrush($fill); $g.FillPath($b, $path); $b.Dispose() }
    if (-not $border.IsEmpty) { $p = New-Object Drawing.Pen($border, 1); $g.DrawPath($p, $path); $p.Dispose() }
    $path.Dispose()
    $g.SmoothingMode = 'None'
    Draw-Text $g $text $font $fore $x $y $w $h 'Center'
    $w
}

function Draw-HLine($g, $color, [int]$x1, [int]$x2, [int]$y) {
    $p = New-Object Drawing.Pen($color, 1)
    $g.DrawLine($p, $x1, $y, $x2, $y)
    $p.Dispose()
}

# ---------------- buttons ----------------
function Set-ButtonKind($b, [string]$kind, $pal = $null) {
    if (-not $pal) { $pal = $C }
    $b.Radius = S 4
    switch ($kind) {
        'primary' { $b.SetColors($pal.BtnPrimary, $pal.BtnPrimaryInk, $NoColor, $pal.BtnPrimaryHover, $pal.BtnPrimaryPress) }
        'ink'     { $b.SetColors($pal.BtnInk, $pal.BtnInkText, $pal.BtnInkLine, $pal.BtnInkHover, $pal.BtnInkPress) }
        'outline' { $b.SetColors($pal.Paper, $pal.Ink, $pal.Ink, $pal.Band, $pal.Hair) }
        'quiet'   { $b.SetColors($pal.Paper, $pal.Ink, $pal.StripMute, $pal.Band, $pal.Hair) }
    }
}

# $pal: pass a theme table to pin a button to it (the settings dialog is always light).
function New-Button([string]$text, [string]$kind, [int]$w, [int]$h, [scriptblock]$onClick, $pal = $null) {
    $b = New-Object MtButton
    $b.Text = $text
    $b.Size = New-Object Drawing.Size((S $w), (S $h))
    $b.Font = FKM 13
    Set-ButtonKind $b $kind $pal
    $b.add_Click($onClick)
    $b
}

# ---------------- minimum size ----------------
# Coaching lines under the digits. Kept short on purpose: the longest one sets the window's minimum width.
$script:MsgOver = '마무리해 주세요.'
$script:MsgIdle = '배정 {0} · Space로 시작'
$script:MsgPause = '일시정지 · Space로 계속'
$script:MsgCritical = '곧 끝납니다. 마무리해 주세요.'
$script:MsgUndo = 'Ctrl+Z로 되돌리기'
# Bottom row sizes (logical px): Start/Next buttons, then the theme and settings icons at the right edge.
$script:RunW = 88
$script:NextW = 64
$script:IconW = 32
$script:IconGap = 2
# Width the top strip needs for a given variant: clock, plan change, end time and tail text.
function Get-StripNeed([bool]$labels, [string]$tail) {
    $need = (S 16) + (Measure-W '00:00' (FN 14)) + (S 12) + (S 16) + (S 10) + (Measure-W $tail (FK 12)) + (Measure-W '00:00' (FN 14))
    # Plan change sits between the clock and the end time, with some air on both sides.
    $need += (Measure-W '+88:88' (FN 14)) + (S 24)
    if ($labels) { $need += (Measure-W '현재' (FK 12)) + (Measure-W '종료' (FK 12)) + (S 12) }
    $need
}

# Narrowest client width at which nothing important is cut off. Measured from the real
# fonts, so a missing Pretendard (falls back to Malgun Gothic) still gets a safe value.
function Get-MinClientWidth {
    $topBar = Get-StripNeed $false '초과 예상'
    $band = (S 16) + (S $script:RunW) + (S 6) + (S $script:NextW) + (S 10) + 3 * (S $script:IconW) + 2 * (S $script:IconGap) + (S 8)
    $head = (S 20) * 2 + (Measure-W '발표자 50' (FKM 16)) + (Measure-W ' / 50명' (FK 13)) + (Measure-W '시간 초과' (FKM 12)) + (S 18)
    $msgs = @($script:MsgOver, $script:MsgPause, ($script:MsgIdle -f '00:00'), $script:MsgCritical, $script:MsgUndo)
    $coach = (S 20) * 2 + (($msgs | ForEach-Object { Measure-W $_ (FKM 13) } | Measure-Object -Maximum).Maximum)
    [math]::Max([math]::Max($topBar, $band), [math]::Max($head, $coach))
}

# ---------------- window ----------------
$form = New-Object Windows.Forms.Form
$form.Text = 'CameraHAL_MeetingTimer'
$form.ClientSize = New-Object Drawing.Size((S 380), (S 290))
$form.MinimumSize = New-Object Drawing.Size(((Get-MinClientWidth) + ($form.Width - $form.ClientSize.Width)), (S 290))
$form.MaximizeBox = $false
$form.StartPosition = 'Manual'
$form.BackColor = $C.Paper
$form.TopMost = $script:Cfg.TopMost
$form.KeyPreview = $true
$form.Font = FK 13
try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path) } catch { }

$strip = New-Object MtCanvas
$strip.Dock = 'Top'
$strip.Height = S 36
$strip.BackColor = $C.Strip

$stage = New-Object MtCanvas
$stage.Dock = 'Fill'
$stage.BackColor = $C.Paper

$band = New-Object MtCanvas
$band.Dock = 'Bottom'
$band.Height = S 56
$band.BackColor = $C.Band

# The control added FIRST is docked LAST, so Fill goes in first.
$form.Controls.Add($stage)
$form.Controls.Add($band)
$form.Controls.Add($strip)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 200

# ---------------- painting ----------------
function Paint-Gear($g, [int]$cx, [int]$cy, $color, $bg) {
    $g.SmoothingMode = 'AntiAlias'
    $pen = New-Object Drawing.Pen($color, [single](3 * $script:Scale))
    for ($k = 0; $k -lt 8; $k++) {
        $a = $k * [math]::PI / 4
        $g.DrawLine($pen, [single]($cx + [math]::Cos($a) * (S 5)), [single]($cy + [math]::Sin($a) * (S 5)),
                          [single]($cx + [math]::Cos($a) * (S 8.5)), [single]($cy + [math]::Sin($a) * (S 8.5)))
    }
    $pen.Dispose()
    $b = New-Object Drawing.SolidBrush($color)
    $g.FillEllipse($b, ($cx - (S 6.5)), ($cy - (S 6.5)), (S 13), (S 13))
    $b.Dispose()
    $b = New-Object Drawing.SolidBrush($bg)
    $g.FillEllipse($b, ($cx - (S 2.5)), ($cy - (S 2.5)), (S 5), (S 5))
    $b.Dispose()
    $g.SmoothingMode = 'None'
}

function Paint-Sun($g, [int]$cx, [int]$cy, $color) {
    $g.SmoothingMode = 'AntiAlias'
    $pen = New-Object Drawing.Pen($color, [single](1.8 * $script:Scale))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    for ($k = 0; $k -lt 8; $k++) {
        $a = $k * [math]::PI / 4
        $g.DrawLine($pen, [single]($cx + [math]::Cos($a) * (S 7.5)), [single]($cy + [math]::Sin($a) * (S 7.5)),
                          [single]($cx + [math]::Cos($a) * (S 10)), [single]($cy + [math]::Sin($a) * (S 10)))
    }
    $pen.Dispose()
    $b = New-Object Drawing.SolidBrush($color)
    $g.FillEllipse($b, ($cx - (S 4.5)), ($cy - (S 4.5)), (S 9), (S 9))
    $b.Dispose()
    $g.SmoothingMode = 'None'
}

# Crescent: a disc with a second, offset disc in the background color cut out of it.
function Paint-Moon($g, [int]$cx, [int]$cy, $color, $bg) {
    $g.SmoothingMode = 'AntiAlias'
    $b = New-Object Drawing.SolidBrush($color)
    $g.FillEllipse($b, ($cx - (S 7.5)), ($cy - (S 7.5)), (S 15), (S 15))
    $b.Dispose()
    $b = New-Object Drawing.SolidBrush($bg)
    $g.FillEllipse($b, ($cx - (S 7.5) + (S 5)), ($cy - (S 7.5) - (S 3.5)), (S 13), (S 13))
    $b.Dispose()
    $g.SmoothingMode = 'None'
}

# Hit boxes of the three icons at the bottom right: sun, moon, then the gear at the far right edge.
function Get-IconRects {
    $W = $band.ClientSize.Width; $H = $band.ClientSize.Height
    $s = S $script:IconW; $gap = S $script:IconGap
    $y = [int](($H - $s) / 2) + 1
    $gx = $W - (S 8) - $s
    @{
        gear = New-Object Drawing.Rectangle($gx, $y, $s, $s)
        moon = New-Object Drawing.Rectangle(($gx - $gap - $s), $y, $s, $s)
        sun  = New-Object Drawing.Rectangle(($gx - 2 * ($gap + $s)), $y, $s, $s)
    }
}

# Current speaker's share minus the first plan, in whole seconds, with its color on the dark strip.
function Get-PlanDelta {
    $st = Get-Phase
    $d = if ($script:Plan -gt 0) { [math]::Round($st.Budget - $script:Plan) } else { 0 }
    if ($d -gt 0)     { [pscustomobject]@{ Text = '+' + (Fmt $d); Color = $C.Plus } }
    elseif ($d -lt 0) { [pscustomobject]@{ Text = '-' + (Fmt $d); Color = $C.Warn } }
    else              { [pscustomobject]@{ Text = '±00:00'; Color = $C.Zero } }
}

function Paint-Strip($g) {
    $W = $strip.ClientSize.Width; $H = $strip.ClientSize.Height
    if ($W -lt 10) { return }
    $g.Clear($C.Strip)

    $left = Get-MeetingLeft
    if ($left -gt 0 -and (Test-Overbooked)) {
        $tailFull = '종료 시각 초과 예상'; $tailShort = '초과 예상'; $tc = $C.Warn
    } elseif ($left -gt 0) {
        $m = [int][math]::Ceiling($left / 60)
        $tailFull = '{0}분 남음' -f $m; $tailShort = '{0}분' -f $m; $tc = $C.StripMute
    } else {
        $tailFull = '회의 시간 종료'; $tailShort = '회의 종료'; $tc = $C.Warn
    }

    # Pick the richest variant that fits: full text, short tail, then no "현재"/"종료" labels.
    $variants = @(
        @{ Labels = $true;  Tail = $tailFull },
        @{ Labels = $true;  Tail = $tailShort },
        @{ Labels = $false; Tail = $tailShort })
    $pick = $variants[2]
    foreach ($v in $variants) {
        if ((Get-StripNeed $v.Labels $v.Tail) -le $W) { $pick = $v; break }
    }

    $x = S 16
    if ($pick.Labels) {
        $lw = Measure-W '현재' (FK 12)
        Draw-Text $g '현재' (FK 12) $C.StripMute $x 0 ($lw + 2) $H
        $x += $lw + (S 6)
    }
    $clock = (Get-Date).ToString('HH:mm')
    $clw = Measure-W $clock (FN 14)
    Draw-Text $g $clock (FN 14) $C.StripInk $x 0 ($clw + 2) $H
    $leftEnd = $x + $clw

    $right = $W - (S 16)
    $tw = Measure-W $pick.Tail (FK 12)
    Draw-Text $g $pick.Tail (FK 12) $tc ($right - $tw) 0 ($tw + 2) $H
    $right -= $tw + (S 10)
    $ew = Measure-W $script:End.ToString('HH:mm') (FN 14)
    Draw-Text $g $script:End.ToString('HH:mm') (FN 14) $C.StripInk ($right - $ew) 0 ($ew + 2) $H
    $rightStart = $right - $ew
    if ($pick.Labels) {
        $right -= $ew + (S 6)
        $kw = Measure-W '종료' (FK 12)
        Draw-Text $g '종료' (FK 12) $C.StripMute ($right - $kw) 0 ($kw + 2) $H
        $rightStart = $right - $kw
    }

    # Change versus the first plan, centered between the clock and the end time.
    $pd = Get-PlanDelta
    $dw = Measure-W $pd.Text (FN 14)
    $mid = [int](($leftEnd + $rightStart) / 2)
    Draw-Text $g $pd.Text (FN 14) $pd.Color ($mid - [int]($dw / 2)) 0 ($dw + 2) $H
}

function Paint-Stage($g) {
    $W = $stage.ClientSize.Width; $H = $stage.ClientSize.Height
    if ($W -lt 50 -or $H -lt 50 -or $script:People.Count -eq 0) { return }
    $st = Get-Phase
    $isOver = $st.Level -eq 'over'

    if ($isOver) {
        # Red slab, pulsing to wine every half second while the clock runs.
        $flash = $st.Run -eq 'run' -and ([int][math]::Floor($st.El * 2) % 2) -eq 1
        $bg = if ($flash) { $C.OverPulse } else { $C.OverBg }
        $fg = $C.OverInk; $sub = $C.OverSub
    } else {
        $bg = $C.Paper; $fg = $C.Ink; $sub = $C.Sub
    }
    $g.Clear($bg)
    $pad = S 20
    $cw = $W - 2 * $pad

    # Header row: speaker counter + state badge
    $head = '발표자 {0}' -f ($script:Idx + 1)
    $hw = Measure-W $head (FKM 16)
    Draw-Text $g $head (FKM 16) $fg $pad (S 14) ($hw + 2) (S 26)
    Draw-Text $g (' / {0}명' -f $script:People.Count) (FK 13) $sub ($pad + $hw) (S 14) (S 80) (S 26)
    if ($isOver)                 { $bt = '시간 초과'; $bf = $C.OverInk; $bc = $C.OverBg;   $bb = $NoColor }
    elseif ($st.Run -eq 'run')   { $bt = '진행 중';  $bf = $C.Ink;      $bc = $C.Paper;    $bb = $NoColor }
    elseif ($st.Run -eq 'pause') { $bt = '일시정지'; $bf = $NoColor;    $bc = $C.Ink;      $bb = $C.Ink }
    else                         { $bt = '대기';     $bf = $NoColor;    $bc = $C.IdleInk;  $bb = $C.IdleLine }
    [void](Draw-PillRight $g $bt (FKM 12) $bf $bc $bb ($W - $pad) (S 15) (S 24))

    # Countdown digits
    $top = S 40
    $bottom = $H - (S 58)
    $dh = [math]::Max((S 30), $bottom - $top)
    $px = [math]::Max(20, [math]::Min($dh * 0.82, $W / 3.5))
    $dc = switch ($st.Level) { 'over' { $C.OverInk } 'critical' { $C.Crit } 'notice' { $C.Accent } default { $C.Ink } }
    Draw-Text $g $st.Text (Font-Px $famNum $px $numStyle) $dc 0 $top $W $dh 'Center'

    # Coaching line (visible to everyone when the screen is shared)
    $mc = $sub
    if ($isOver) { $msg = $script:MsgOver; $mc = $C.OverInk }
    elseif (Test-UndoHint) { $msg = $script:MsgUndo; $mc = $C.Accent }
    elseif ($st.Run -eq 'idle') { $msg = $script:MsgIdle -f (Fmt $st.Budget) }
    elseif ($st.Run -eq 'pause') { $msg = $script:MsgPause }
    elseif ($st.Level -eq 'critical') { $msg = $script:MsgCritical; $mc = $C.Crit }
    elseif ($st.Level -eq 'notice') { $msg = '핵심만 정리해 주세요.'; $mc = $C.Accent }
    else { $msg = '배정 {0}' -f (Fmt $st.Budget) }
    Draw-Text $g $msg (FKM 13) $mc $pad $bottom $cw (S 22) 'Center'

    # One segment per speaker; the current one fills up as time passes.
    $n = $script:People.Count
    $gap = if ($n -gt 12) { S 2 } else { S 4 }
    $sh = S 6
    $sy = $H - (S 24)
    $segW = ($cw - $gap * ($n - 1)) / $n
    $track = if ($isOver) { [Drawing.Color]::FromArgb(70, 255, 255, 255) } else { $C.Hair }
    for ($i = 0; $i -lt $n; $i++) {
        $x = $pad + $i * ($segW + $gap)
        Fill-Round $g $track $x $sy $segW $sh (S 3)
        $el = Get-Elapsed $i
        if ($i -eq $script:Idx) {
            $fill = switch ($st.Level) { 'over' { $C.OverInk } 'critical' { $C.Crit } 'notice' { $C.Accent } default { $C.Ink } }
            $ratio = if ($st.Budget -gt 0) { [math]::Min(1.0, $el / $st.Budget) } else { 1.0 }
            Fill-Round $g $fill $x $sy ($segW * $ratio) $sh (S 3)
        } elseif ($el -gt 0) {
            $b = $script:People[$i].Budget
            $fill = if ($b -gt 0 -and $el -gt $b) { $C.Warn } else { $C.Done }
            if ($isOver -and $fill -eq $C.Done) { $fill = $C.OverSub }
            Fill-Round $g $fill $x $sy $segW $sh (S 3)
        }
    }
}

function Paint-Band($g) {
    $g.Clear($C.Band)
    Draw-HLine $g $C.Hair 0 $band.ClientSize.Width 0

    # Sun = light theme, moon = dark theme, gear = settings. The current theme's icon stays highlighted.
    $rects = Get-IconRects
    foreach ($k in 'sun', 'moon', 'gear') {
        $r = $rects[$k]
        $active = ($k -eq 'sun' -and $script:ThemeName -eq 'light') -or ($k -eq 'moon' -and $script:ThemeName -eq 'dark')
        $hot = $script:BandHot -eq $k
        $bg = if ($active -or $hot) { $C.Hair } else { $C.Band }
        $fg = if ($active -or $hot) { $C.Ink } else { $C.Sub }
        if ($active -or $hot) { Fill-Round $g $bg $r.X $r.Y $r.Width $r.Height (S 6) }
        $cx = $r.X + [int]($r.Width / 2); $cy = $r.Y + [int]($r.Height / 2)
        switch ($k) {
            'sun'  { Paint-Sun $g $cx $cy $fg }
            'moon' { Paint-Moon $g $cx $cy $fg $bg }
            'gear' { Paint-Gear $g $cx $cy $fg $bg }
        }
    }
}

# ---------------- actions ----------------
function Refresh-All {
    if ($script:People.Count -eq 0) { return }
    $st = Get-Phase
    $btnRun.Text = switch ($st.Run) { 'run' { '일시정지' } 'pause' { '계속' } default { '시작' } }
    $btnNext.Text = if ($script:Idx -ge $script:People.Count - 1) { '종료' } else { '다음' }
    # Next/finish only make sense once this speaker has started.
    $btnNext.Visible = $script:People[$script:Idx].Budget -gt 0
    # The title doubles as the taskbar label while minimized.
    $form.Text = '{0} · 발표자 {1}/{2} · CameraHAL_MeetingTimer' -f $st.Text, ($script:Idx + 1), $script:People.Count
    $strip.Invalidate()
    $stage.Invalidate()
}

function Check-Alerts {
    $p = $script:People[$script:Idx]
    $st = Get-Phase
    if ($st.Run -eq 'run') {
        if (-not $p.W2 -and $st.Rem -le $st.NoticeAt) { $p.W2 = $true; Play 'Asterisk' }
        if (-not $p.W1 -and $st.Rem -le $st.CriticalAt) { $p.W1 = $true; Play 'Exclamation' }
        if (-not $p.Zero -and $st.Rem -le 0) { $p.Zero = $true; Play 'Hand'; Flash-IfHidden }
        if ($st.Rem -lt 0) {
            # Repeat the alarm (and the taskbar flash) every 30 seconds of overtime.
            $n = [int][math]::Floor(-$st.Rem / 30)
            if ($n -gt $p.Over) { $p.Over = $n; Play 'Hand'; Flash-IfHidden }
        }
    }
    if (-not $script:EndFlashed -and (Get-MeetingLeft) -le 0) {
        $script:EndFlashed = $true
        Play 'Hand'
        Flash-IfHidden
    }
}

function Commit-Current {
    $script:People[$script:Idx].Used += $script:Sw.Elapsed.TotalSeconds
    $script:Sw.Reset()
}

function Switch-To([int]$i) {
    if ($i -lt 0 -or $i -ge $script:People.Count -or $i -eq $script:Idx) { return }
    $wasRunning = $script:Sw.IsRunning
    Commit-Current
    $script:Idx = $i
    if ($wasRunning) { Lock-Budget; $script:Sw.Start() }
    Refresh-All
}

function Toggle-Run {
    if ($script:Sw.IsRunning) { $script:Sw.Stop() } else { Lock-Budget; $script:Sw.Start() }
    Refresh-All
}

function Go-Next {
    # Same rule as the button (also covers N and the right arrow): the speaker must have started.
    if ($script:People[$script:Idx].Budget -eq 0) { return }
    Save-Undo
    if ($script:Idx -ge $script:People.Count - 1) {
        # Finishing ends the meeting: no summary, go straight to a fresh one.
        Commit-Current
        Start-Over
    } else {
        Switch-To ($script:Idx + 1)
    }
}

# Clears the current speaker's clock and share (e.g. after an accidental start).
function Reset-Current {
    $wasRunning = $script:Sw.IsRunning
    # Nothing to clear: keep any earlier undo instead of overwriting it with a no-op.
    if (-not $wasRunning -and (Get-Elapsed $script:Idx) -eq 0 -and $script:People[$script:Idx].Budget -eq 0) { return }
    Save-Undo
    $script:Sw.Reset()
    $script:People[$script:Idx] = New-Person
    if ($wasRunning) { Lock-Budget; $script:Sw.Start() }
    Refresh-All
}

function Set-Count([int]$n) {
    $n = [math]::Max(1, [math]::Min(50, $n))
    if ($n -eq $script:People.Count) { return }
    $wasRunning = $script:Sw.IsRunning
    Commit-Current
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in $script:People) { $list.Add($p) }
    while ($list.Count -lt $n) { $list.Add((New-Person)) }
    while ($list.Count -gt $n) { $list.RemoveAt($list.Count - 1) }
    $script:People = $list.ToArray()
    if ($script:Idx -ge $n) { $script:Idx = $n - 1 }
    if ($wasRunning) { Lock-Budget; $script:Sw.Start() }
    Refresh-All
}

function Start-Over {
    $script:Sw.Reset()
    $script:People = @(1..$script:Cfg.Count | ForEach-Object { New-Person })
    $script:Idx = 0
    $script:End = Get-NextHour
    $script:EndFlashed = $false
    $script:Plan = 0.0
    Refresh-All
}

# ---------------- undo ----------------
# One level of undo for the keys that cannot be taken back otherwise: Next (including the
# finish that starts a fresh meeting) and Reset. The time that passed since then belongs to
# the speaker who was talking, so it is given back to them if their clock was running.
$script:Undo = $null
function Save-Undo {
    $copy = @($script:People | ForEach-Object { $_.PSObject.Copy() })
    # Fold the running stopwatch into the copy, the same way Commit-Current would.
    $copy[$script:Idx].Used = Get-Elapsed $script:Idx
    $script:Undo = [pscustomobject]@{
        People = $copy; Idx = $script:Idx; End = $script:End; EndFlashed = $script:EndFlashed
        Plan = $script:Plan; Running = $script:Sw.IsRunning; At = Get-Date
    }
}

function Undo-Last {
    $u = $script:Undo
    if (-not $u) { return }
    $script:Undo = $null
    $script:Sw.Reset()
    $script:People = $u.People
    $script:Idx = $u.Idx
    $script:End = $u.End
    $script:EndFlashed = $u.EndFlashed
    $script:Plan = $u.Plan
    if ($u.Running) {
        $script:People[$script:Idx].Used += [math]::Max(0, ((Get-Date) - $u.At).TotalSeconds)
        $script:Sw.Start()
    }
    Refresh-All
}

# True for a few seconds after an undoable action, so the coaching line can offer Ctrl+Z.
function Test-UndoHint {
    $script:Undo -and ((Get-Date) - $script:Undo.At).TotalSeconds -lt 10
}

function Place-Corner {
    $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
    $form.Location = New-Object Drawing.Point(($wa.Right - $form.Width - (S 16)), ($wa.Bottom - $form.Height - (S 16)))
}

# ---------------- settings ----------------
function New-DlgLabel([string]$text, $font, $color, [int]$x, [int]$y, [int]$w, [int]$h) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.Font = $font
    $l.ForeColor = $color
    $l.SetBounds((S $x), (S $y), (S $w), (S $h))
    $l
}

# Resolves the HH:mm picked in the settings dialog to the next time it occurs (today, or tomorrow if past).
function Resolve-EndTime($picked) {
    $now = Get-Date
    $end = $now.Date.AddHours($picked.Hour).AddMinutes($picked.Minute)
    if ($end -le $now) { $end = $end.AddDays(1) }
    $end
}

# Caps the speaker count so every remaining speaker can get at least MinShare seconds.
# Speakers who already finished stay counted; only the ones still to come are limited.
$script:SetHintBase = '남은 회의 시간은 아직 시작하지 않은 발표자에게 자동으로 똑같이 나뉩니다.'
function Update-SetMax([bool]$clamped = $false) {
    $leftSec = ((Resolve-EndTime $script:SetDt.Value) - (Get-Date)).TotalSeconds
    $fit = [int][math]::Floor($leftSec / $script:MinShare)
    $max = [math]::Min(50, [math]::Max($script:Idx + 1, $script:Idx + $fit))
    $script:SetNum.Maximum = [decimal]$max
    if ($script:SetNum.Value -gt $max) { $script:SetNum.Value = [decimal]$max; $clamped = $true }
    if ($leftSec -lt $script:MinShare) {
        $script:SetHint.Text = '남은 시간이 1분 미만이어서 발표자 수는 최소 인원으로 제한됩니다.'
    } elseif ($clamped -or $fit -lt (50 - $script:Idx)) {
        $script:SetHint.Text = ('남은 시간 기준 최대 {0}명입니다 (1인당 최소 1분).' -f $max)
    } else {
        $script:SetHint.Text = $script:SetHintBase
    }
}

function Show-Settings {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'CameraHAL_MeetingTimer'
    $dlg.ClientSize = New-Object Drawing.Size((S 340), (S 412))
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.TopMost = $true
    # Native controls (NumericUpDown, DateTimePicker) cannot be themed cleanly, so this dialog stays light.
    $L = $Themes.light
    $dlg.BackColor = $L.Paper
    $dlg.KeyPreview = $true
    $dlg.add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Escape') { $s.DialogResult = 'Cancel'; $s.Close() } })

    $title = New-DlgLabel '설정' (FKM 22) $L.Ink 24 20 292 34

    $l1 = New-DlgLabel '발표자 수' (FKM 14) $L.Ink 24 72 140 22
    $num = New-Object Windows.Forms.NumericUpDown
    $num.Minimum = 1
    $num.Maximum = 50
    $num.Value = [decimal]$script:People.Count
    $num.Font = FK 15
    $num.BorderStyle = 'FixedSingle'
    $num.SetBounds((S 24), (S 98), (S 120), (S 32))

    $l2 = New-DlgLabel '회의 종료 시각' (FKM 14) $L.Ink 172 72 140 22
    $dt = New-Object Windows.Forms.DateTimePicker
    $dt.Format = 'Custom'
    $dt.CustomFormat = 'HH:mm'
    $dt.ShowUpDown = $true
    $dt.Font = FK 15
    $dt.Value = $script:End
    $dt.SetBounds((S 172), (S 98), (S 120), (S 32))

    $h1 = New-DlgLabel $script:SetHintBase (FK 12) $L.Sub 24 136 292 48
    $script:SetNum = $num
    $script:SetDt = $dt
    $script:SetHint = $h1
    $dt.add_ValueChanged({ Update-SetMax })
    Update-SetMax

    $cbTop = New-Object Windows.Forms.CheckBox
    $cbTop.Text = '항상 다른 창 위에 표시'
    $cbTop.Font = FK 14
    $cbTop.ForeColor = $L.Ink
    $cbTop.Checked = $form.TopMost
    $cbTop.SetBounds((S 24), (S 192), (S 292), (S 26))

    $cbSound = New-Object Windows.Forms.CheckBox
    $cbSound.Text = '알림음 사용 (마감 직전, 시간 초과)'
    $cbSound.Font = FK 14
    $cbSound.ForeColor = $L.Ink
    $cbSound.Checked = $script:Sound
    $cbSound.SetBounds((S 24), (S 222), (S 292), (S 26))

    $script:SetDlg = $dlg
    $script:SetStartOver = $false
    $restart = New-Button '새 회의 시작' 'quiet' 120 36 {
        $r = [Windows.Forms.MessageBox]::Show($script:SetDlg, "기록을 모두 지우고 종료 시각을 다음 정각으로 되돌립니다.`n진행할까요?", '새 회의', 'YesNo', 'Warning')
        if ($r -eq 'Yes') { $script:SetStartOver = $true; $script:SetDlg.DialogResult = 'OK'; $script:SetDlg.Close() }
    } $L
    $restart.Location = New-Object Drawing.Point((S 24), (S 270))
    $h2 = New-DlgLabel "기록을 지우고, 종료 시각을`n다음 정각으로 되돌립니다." (FK 12) $L.Sub 156 268 170 40

    $save = New-Button '저장' 'primary' 92 40 { $script:SetDlg.DialogResult = 'OK'; $script:SetDlg.Close() } $L
    $save.Location = New-Object Drawing.Point((S 224), (S 348))
    $cancel = New-Button '취소' 'outline' 84 40 { $script:SetDlg.DialogResult = 'Cancel'; $script:SetDlg.Close() } $L
    $cancel.Location = New-Object Drawing.Point((S 132), (S 348))

    $dlg.Controls.AddRange(@($title, $l1, $num, $l2, $dt, $h1, $cbTop, $cbSound, $restart, $h2, $cancel, $save))

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $form.TopMost = $cbTop.Checked
        $script:Sound = $cbSound.Checked
        $script:Cfg.Count = [int]$num.Value
        # A snapshot from before a count or end-time change no longer matches the meeting.
        $script:Undo = $null
        if ($script:SetStartOver) {
            Start-Over
        } else {
            # Picked time is today's; if it is already past, it means tomorrow.
            $end = Resolve-EndTime $dt.Value
            $changed = $end -ne $script:End -or $script:Cfg.Count -ne $script:People.Count
            if ($end -ne $script:End) { $script:End = $end; $script:EndFlashed = $false }
            Set-Count $script:Cfg.Count
            # A different end time or speaker count makes the old first plan meaningless.
            if ($changed) { Reset-Plan }
        }
        try { Save-Config } catch { }
        Refresh-All
    }
    $dlg.Dispose()
}

# ---------------- controls ----------------
$btnRun  = New-Button '시작' 'primary' $script:RunW 36 { Toggle-Run }
$btnNext = New-Button '다음' 'ink' $script:NextW 36 { Go-Next }
$band.Controls.AddRange(@($btnRun, $btnNext))

# Switches the main window between the light and dark tables (the settings dialog stays light).
function Set-Theme([string]$name) {
    if (-not $Themes.ContainsKey($name)) { return }
    $script:ThemeName = $name
    $script:C = $Themes[$name]
    $form.BackColor = $C.Paper
    $strip.BackColor = $C.Strip
    $stage.BackColor = $C.Paper
    $band.BackColor = $C.Band
    Set-ButtonKind $btnRun 'primary'
    Set-ButtonKind $btnNext 'ink'
    if ($form.IsHandleCreated) { [MtNative]::DarkTitle($form.Handle, ($name -eq 'dark')) }
    $band.Invalidate()
    Refresh-All
}

function Layout-Band {
    $W = $band.ClientSize.Width
    $y = [int](($band.ClientSize.Height - $btnRun.Height) / 2) + 1
    $x = S 16
    foreach ($b in @($btnRun, $btnNext)) {
        $b.Location = New-Object Drawing.Point($x, $y)
        $x += $b.Width + (S 6)
    }
}

# ---------------- events ----------------
$strip.add_Paint({ param($s, $e) Paint-Strip $e.Graphics })
# Switches theme and remembers it; used by the sun/moon icons and the D key.
function Choose-Theme([string]$name) {
    if ($script:ThemeName -eq $name) { return }
    Set-Theme $name
    try { Save-Config } catch { }
}

# The icons are painted, not controls, so hit-test them by hand.
$script:BandHot = ''
$script:IconTips = @{ sun = '밝은 화면'; moon = '어두운 화면'; gear = '설정 (S)' }
$script:IconTip = New-Object Windows.Forms.ToolTip
function Get-IconAt($pt) {
    $rects = Get-IconRects
    foreach ($k in 'sun', 'moon', 'gear') { if ($rects[$k].Contains($pt)) { return $k } }
    ''
}
$band.add_MouseMove({
    param($s, $e)
    $hot = Get-IconAt $e.Location
    if ($hot -ne $script:BandHot) {
        $script:BandHot = $hot
        $band.Cursor = if ($hot) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::Default }
        $script:IconTip.SetToolTip($band, $(if ($hot) { $script:IconTips[$hot] } else { '' }))
        $band.Invalidate()
    }
})
$band.add_MouseLeave({
    if ($script:BandHot) { $script:BandHot = ''; $band.Cursor = [Windows.Forms.Cursors]::Default; $band.Invalidate() }
})
$band.add_MouseClick({
    param($s, $e)
    if ($e.Button -ne 'Left') { return }
    switch (Get-IconAt $e.Location) {
        'sun'  { Choose-Theme 'light' }
        'moon' { Choose-Theme 'dark' }
        'gear' { Show-Settings }
    }
})
$stage.add_Paint({ param($s, $e) Paint-Stage $e.Graphics })
$band.add_Paint({ param($s, $e) Paint-Band $e.Graphics })
$band.add_Resize({ Layout-Band })

$form.add_Shown({
    Layout-Band
    if ($script:ThemeName -eq 'dark') { [MtNative]::DarkTitle($form.Handle, $true) }
    Refresh-All
    # A hidden-window launch hides the first window this process shows; undo that.
    if (-not [MtNative]::IsWindowVisible($form.Handle)) { [void][MtNative]::ShowWindow($form.Handle, 5) }
    $form.Activate()
})

$form.add_KeyDown({
    param($s, $e)
    switch ($e.KeyCode) {
        'Space' { Toggle-Run }
        'N'     { Go-Next }
        'Right' { Go-Next }
        'R'     { Reset-Current }
        'Z'     { if ($e.Control) { Undo-Last } else { return } }
        'S'     { Show-Settings }
        'D'     { Choose-Theme $(if ($script:ThemeName -eq 'dark') { 'light' } else { 'dark' }) }
        'M'     { $script:Sound = -not $script:Sound }
        default { return }
    }
    $e.Handled = $true
    $e.SuppressKeyPress = $true
})

$timer.add_Tick({
    Check-Alerts
    Refresh-All
})

$form.add_FormClosing({
    $timer.Stop()
    try { Save-Config } catch { }
})

# ---------------- start ----------------
Start-Over
Place-Corner
$timer.Start()
[void]$form.ShowDialog()
$form.Dispose()
