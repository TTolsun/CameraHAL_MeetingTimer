# CameraHAL_MeetingTimer.ps1 - Compact weekly meeting speaker timer (Windows PowerShell 5.1 + WinForms)
#
# - Meeting end defaults to the next full hour after launch (14:05 -> 15:00).
# - Enter only the number of speakers; the remaining meeting time is split
#   automatically. Each speaker's share is locked when they start, so an
#   overrun shrinks the shares of the people still waiting.
# - A camera marks the current speaker. The overtime digits change color at +00:15.
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
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    // Dark title bar to match the dark theme (attribute 20 on current Windows 10/11, 19 on early 20H1 builds).
    public static void DarkTitle(IntPtr h, bool on) {
        int v = on ? 1 : 0;
        try {
            if (DwmSetWindowAttribute(h, 20, ref v, 4) != 0) DwmSetWindowAttribute(h, 19, ref v, 4);
        } catch { }
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

// NumericUpDown otherwise ignores an increment at its limit without feedback.
public class MtSpeakerCount : NumericUpDown {
    public event System.ComponentModel.CancelEventHandler Increasing;
    public override void UpButton() {
        var args = new System.ComponentModel.CancelEventArgs();
        if (Increasing != null) Increasing(this, args);
        if (!args.Cancel) base.UpButton();
    }
}

// Native keyboard and accessibility behavior with custom painting.
public class MtButton : Button {
    public Color Fill = Color.White, Fore = Color.Black, Border = Color.Empty, HoverFill = Color.Empty, PressFill = Color.Empty;
    public string Glyph = "";
    public int Radius = 4;
    public bool RightIsInputKey;

    // Let the timer form's KeyPreview receive Right before focus navigation.
    protected override bool IsInputKey(Keys keyData) {
        return (RightIsInputKey && keyData == Keys.Right) || base.IsInputKey(keyData);
    }
    private bool hover, press;

    public MtButton() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        TabStop = true;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
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
    protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
    protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(Parent != null ? Parent.BackColor : BackColor);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color f = Fill;
        if (press && PressFill != Color.Empty) f = PressFill;
        else if (hover && HoverFill != Color.Empty) f = HoverFill;
        if (!Enabled) f = SystemColors.Control;
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 2f, Height - 2f);
        using (GraphicsPath p = MtNative.Round(r, Math.Min(Radius, Height / 2f - 1))) {
            using (SolidBrush b = new SolidBrush(f)) g.FillPath(b, p);
            if (Border != Color.Empty) using (Pen pen = new Pen(Border, 1f)) g.DrawPath(pen, p);
        }
        g.SmoothingMode = SmoothingMode.None;
        Color ink = Enabled ? Fore : SystemColors.GrayText;
        if (String.IsNullOrEmpty(Glyph)) {
            TextRenderer.DrawText(g, Text, Font, ClientRectangle, ink,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
                TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
        } else {
            DrawGlyph(g, ink);
        }
        if (Focused && ShowFocusCues) {
            Rectangle focus = ClientRectangle;
            focus.Inflate(-5, -5);
            ControlPaint.DrawFocusRectangle(g, focus, Fore, f);
        }
    }

    private void DrawGlyph(Graphics g, Color ink) {
        float x = Width / 2f, y = Height / 2f, r = Math.Min(Width, Height) * 0.23f;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (Pen pen = new Pen(ink, Math.Max(1.5f, Height / 18f)))
        using (SolidBrush brush = new SolidBrush(ink)) {
            pen.StartCap = LineCap.Round;
            pen.EndCap = LineCap.Round;
            switch (Glyph) {
                case "play":
                    g.FillPolygon(brush, new PointF[] { new PointF(x-r*0.65f,y-r), new PointF(x+r,y), new PointF(x-r*0.65f,y+r) });
                    break;
                case "pause":
                    g.FillRectangle(brush, x-r, y-r, r*0.65f, r*2);
                    g.FillRectangle(brush, x+r*0.35f, y-r, r*0.65f, r*2);
                    break;
                case "next":
                    g.FillPolygon(brush, new PointF[] { new PointF(x-r,y-r), new PointF(x+r*0.45f,y), new PointF(x-r,y+r) });
                    g.DrawLine(pen, x+r, y-r, x+r, y+r);
                    break;
                case "stop":
                    g.FillRectangle(brush, x-r, y-r, r*2, r*2);
                    break;
                case "undo":
                    g.DrawArc(pen, x-r, y-r*0.3f, r*2, r*1.3f, 180, 250);
                    g.FillPolygon(brush, new PointF[] { new PointF(x-r*1.2f,y+r*0.35f), new PointF(x-r*0.4f,y-r*0.25f), new PointF(x-r*0.4f,y+r*0.95f) });
                    break;
                case "window":
                    g.DrawRectangle(pen, x-r, y-r*0.8f, r*2, r*1.6f);
                    g.DrawLine(pen, x-r, y-r*0.25f, x+r, y-r*0.25f);
                    break;
                case "presenter-bar":
                    g.DrawRectangle(pen, x-r, y-r*0.8f, r*2, r*1.6f);
                    g.FillRectangle(brush, x-r, y+r*0.25f, r*2, r*0.55f);
                    break;
            }
        }
        g.SmoothingMode = SmoothingMode.None;
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
        Overtime = '#8a4d22'; BarOvertime = '#ebb186'; Camera = '#007858'; BarCamera = '#83e4bb'; ActiveSpeaker = '#dcefe8'; BarActiveSpeaker = '#29433a'
        IdleInk = '#3d3d3d'; IdleLine = '#c2c2c2'; Done = '#3d3d3d'
        BarTrack = '#3d3d3d'
        BtnPrimary = '#024ad8'; BtnPrimaryInk = '#ffffff'; BtnPrimaryHover = '#0340b8'; BtnPrimaryPress = '#0e3191'
        BtnInk = '#1a1a1a'; BtnInkText = '#ffffff'; BtnInkLine = ''; BtnInkHover = '#292929'; BtnInkPress = '#000000'
    }
    # Dark follows the Raycast DESIGN.md (getdesign.md/raycast): near-black canvas,
    # hairline borders and one accent per state (blue, red).
    dark = New-Theme @{
        Paper = '#07080a'; Ink = '#f4f4f6'; Sub = '#9c9c9d'; Hair = '#242728'; Band = '#0d0d0d'
        Strip = '#0d0d0d'; StripInk = '#f4f4f6'; StripMute = '#9c9c9d'; StripHover = '#1c1c1d'
        Accent = '#57c1ff'; Plus = '#57c1ff'; Warn = '#ff6161'; Zero = '#6a6b6c'
        Overtime = '#ebb186'; BarOvertime = '#ebb186'; Camera = '#83e4bb'; BarCamera = '#83e4bb'; ActiveSpeaker = '#1d382f'; BarActiveSpeaker = '#29433a'
        IdleInk = '#cdcdcd'; IdleLine = '#434345'; Done = '#8a8a8c'
        BarTrack = '#242728'
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
    $cfg = [pscustomobject]@{ Count = 6; TopMost = $true; Theme = 'light'; Bar = $false; BarEdge = 'bottom' }
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
        if ($j.TopMost -is [bool]) { $cfg.TopMost = $j.TopMost }
        if ($j.Bar -is [bool]) { $cfg.Bar = $j.Bar }
        if ($j.BarEdge -is [string] -and @('top','bottom','left','right') -ccontains $j.BarEdge) { $cfg.BarEdge = $j.BarEdge }
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
        # The preference, not $form.TopMost: the presenter bar forces always-on-top.
        TopMost  = [bool]$script:TopMostPref
        Bar      = [bool]$script:BarMode
        BarEdge  = [string]$script:BarEdge
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
$script:ThemeName = $script:Cfg.Theme
$C = $Themes[$script:ThemeName]
$script:End = Get-NextHour
$script:Sw = New-Object System.Diagnostics.Stopwatch
$script:People = @()
$script:Idx = 0
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
$script:MsgIdle = '배정 {0} · 시작을 눌러 주세요'
$script:MsgPause = '일시정지'
$script:MsgUndo = 'Ctrl+Z로 되돌리기'
$script:MsgFinish = '회의를 종료했습니다. Ctrl+Z로 되돌리기'
$script:MsgBarFinish = '회의 종료 · 되돌리기'
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
    $band = (S 16) + (S $script:RunW) + (S 6) + (S $script:NextW) + (S 6) + (S 68) + (S 10) + (S 52) + (S 16)
    $head = (S 20) * 2 + (Measure-W '발표자 50' (FKM 16)) + (Measure-W '초과 · 일시정지' (FKM 12)) + (S 18)
    $msgs = @('59분 59초 남았어요', $script:MsgPause, ($script:MsgIdle -f '00:00'), $script:MsgUndo, $script:MsgFinish)
    $coach = (S 20) * 2 + (($msgs | ForEach-Object { Measure-W $_ (FKM 13) } | Measure-Object -Maximum).Maximum)
    [math]::Max([math]::Max($topBar, $band), [math]::Max($head, $coach))
}

# ---------------- window ----------------
$form = New-Object Windows.Forms.Form
$form.Text = 'CameraHAL_MeetingTimer'
$form.ClientSize = New-Object Drawing.Size((S 380), (S 328))
$form.MinimumSize = New-Object Drawing.Size(((Get-MinClientWidth) + ($form.Width - $form.ClientSize.Width)), (S 328))
$form.MaximizeBox = $false
$form.StartPosition = 'Manual'
$form.BackColor = $C.Paper
$script:TopMostPref = $script:Cfg.TopMost
$form.TopMost = $script:TopMostPref
$script:NormalMin = $form.MinimumSize
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
$band.Height = S 94
$band.BackColor = $C.Band

# The control added FIRST is docked LAST, so Fill goes in first.
$form.Controls.Add($stage)
$form.Controls.Add($band)
$form.Controls.Add($strip)

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 200
$script:BatonStarted = $null
$script:BarTwoRowWidth = 520

# ---------------- painting ----------------

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

# A centered five-slot window, clamped at either end of the speaker list.
function Get-SpeakerWindow([int]$count, [int]$current) {
    $size = [math]::Min(5, $count)
    $first = [math]::Max(0, [math]::Min($current - 2, $count - $size))
    [pscustomobject]@{ First = $first; Last = $first + $size - 1; Before = $first -gt 0; After = $first + $size -lt $count }
}

function Get-BatonOffset {
    if ($null -eq $script:BatonStarted) { return 0.0 }
    $t = [math]::Max(0.0, [math]::Min(1.0, ((Get-Date) - $script:BatonStarted).TotalMilliseconds / 240))
    -[math]::Pow(1 - $t, 2)
}

function Paint-SpeakerBaton($g, [int]$left, [int]$top, [int]$width, [bool]$bar = $false) {
    $n = $script:People.Count
    $window = Get-SpeakerWindow $n $script:Idx
    $slot = S 22
    $rowW = ($window.Last - $window.First + 1) * $slot
    $x = $left + [int](($width - $rowW) / 2)
    $muted = if ($bar) { $C.StripMute } else { $C.Sub }
    $ink = if ($bar) { $C.StripInk } else { $C.Ink }
    $camera = if ($bar) { $C.BarCamera } else { $C.Camera }
    $active = if ($bar) { $C.BarActiveSpeaker } else { $C.ActiveSpeaker }
    $surface = if ($bar) { $C.Strip } else { $C.Paper }
    $labelTop = $top + (S 14)
    if ($window.Before) { Draw-Text $g '…' (FK 12) $muted ($x - (S 14)) $labelTop (S 14) (S 18) 'Center' }
    if ($window.After) { Draw-Text $g '…' (FK 12) $muted ($x + $rowW) $labelTop (S 14) (S 18) 'Center' }
    for ($i = $window.First; $i -le $window.Last; $i++) {
        $slotX = $x + ($i - $window.First) * $slot
        $fg = $muted
        if ($i -eq $script:Idx) {
            Fill-Round $g $active $slotX $labelTop $slot (S 18) (S 5)
            $fg = $ink
        }
        Draw-Text $g ($i + 1) (FN 12) $fg $slotX $labelTop $slot (S 18) 'Center'
    }
    $center = $x + ($script:Idx - $window.First + 0.5 + (Get-BatonOffset)) * $slot
    Fill-Round $g $camera ($center - (S 9)) ($top + (S 2)) (S 18) (S 11) (S 3)
    Fill-Round $g $camera ($center - (S 4)) $top (S 8) (S 4) (S 1)
    Fill-Round $g $surface ($center - (S 4)) ($top + (S 3)) (S 8) (S 8) (S 4)
}

function Get-RemainingMessage([double]$seconds) {
    $whole = [int][math]::Ceiling($seconds)
    $minutes = [int][math]::Floor($whole / 60)
    $secs = $whole % 60
    if ($minutes -eq 0) { return '{0}초 남았어요' -f $secs }
    if ($secs -eq 0) { return '{0}분 남았어요' -f $minutes }
    '{0}분 {1}초 남았어요' -f $minutes, $secs
}

function Test-FinishHint($state) {
    $state.Run -eq 'idle' -and $script:Undo.Kind -eq 'finish' -and (Test-UndoHint)
}

function Get-BarMessage($state) {
    if (Test-FinishHint $state) { return $script:MsgBarFinish }
    if ($state.Run -eq 'pause') { return $script:MsgPause }
    if ($state.Level -eq 'over') { return '' }
    if ($state.Run -eq 'idle') { return '대기' }
    if ($state.Closing) { return Get-RemainingMessage $state.Rem }
    '진행 중'
}

function Get-ClockColor($state, [bool]$bar = $false) {
    if ($bar) { if ($state.Highlight) { $C.BarOvertime } else { $C.StripInk } }
    else { if ($state.Highlight) { $C.Overtime } else { $C.Ink } }
}

function Paint-Bar($g) {
    $W = $stage.ClientSize.Width; $H = $stage.ClientSize.Height
    if ($W -lt 50 -or $H -lt 10 -or $script:People.Count -eq 0) { return }
    $st = Get-Phase
    $g.Clear($C.Strip)
    $vertical = $script:BarEdge -in @('left','right')
    $dc = Get-ClockColor $st $true
    $msg = Get-BarMessage $st
    $head = '{0} / {1}명' -f ($script:Idx + 1), $script:People.Count
    if ($vertical) {
        $pad = S 10
        $content = $W - 2 * $pad
        Draw-Text $g $head (FKM 15) $C.StripInk $pad (S 14) $content (S 28) 'Center'
        Paint-SpeakerBaton $g $pad (S 52) $content $true
        $digitPx = [math]::Min((S 43), $W / 4)
        while ((Measure-W $st.Text (Font-Px $famNum $digitPx $numStyle)) -gt $content -and $digitPx -gt (S 16)) { $digitPx -= 1 }
        Draw-Text $g $st.Text (Font-Px $famNum $digitPx $numStyle) $dc $pad (S 94) $content (S 66) 'Center'
        Draw-Text $g $msg (FKM 12) $C.StripMute $pad (S 162) $content (S 28) 'Center'
    } elseif ($W -lt (S $script:BarTwoRowWidth)) {
        # On a narrow monitor the clock and camera share the top row; controls stay below.
        $pad = S 8
        $batonW = S 140
        $clockX = $pad + $batonW
        Paint-SpeakerBaton $g $pad (S 5) $batonW $true
        $clockW = $W - $clockX - $pad
        if ($msg -eq $script:MsgBarFinish) {
            Draw-Text $g $st.Text (FN 23) $dc $clockX 0 $clockW (S 27) 'Center'
            Draw-Text $g $msg (FKM 12) $C.StripInk $clockX (S 24) $clockW (S 18) 'Center'
            $msg = ''
        } else {
            Draw-Text $g $st.Text (FN 28) $dc $clockX 0 $clockW (S 42) 'Center'
        }
        $headW = S 72
        Draw-Text $g $head (FKM 14) $C.StripInk $pad (S 42) $headW (S 40) 'Center'
        $messageX = $pad + $headW + (S 4)
        $messageW = $btnBarRun.Left - $messageX - $pad
        if ($messageW -gt (S 40)) {
            Draw-Text $g $msg (FKM 12) $C.StripMute $messageX (S 42) $messageW (S 40)
        }
    } else {
        $headW = S 72
        $clockW = S 134
        $batonW = S 146
        $pad = S 12
        Draw-Text $g $head (FKM 15) $C.StripInk $pad 0 $headW ($H - (S 4)) 'Center'
        Paint-SpeakerBaton $g ($pad + $headW) (S 12) $batonW $true
        $clockX = $pad + $headW + $batonW
        $messageX = $clockX + $clockW
        $messageW = $btnBarRun.Left - $messageX - (S 8)
        if ($msg -eq $script:MsgBarFinish -and $messageW -lt (Measure-W $msg (FKM 12))) {
            Draw-Text $g $st.Text (FN 28) $dc $clockX 0 $clockW (S 36) 'Center'
            Draw-Text $g $msg (FKM 12) $C.StripInk $clockX (S 33) $clockW (S 19) 'Center'
        } else {
            Draw-Text $g $st.Text (FN 32) $dc $clockX 0 $clockW ($H - (S 4)) 'Center'
            if ($messageW -gt (S 40)) {
                Draw-Text $g $msg (FKM 12) $C.StripMute $messageX 0 $messageW ($H - (S 4))
            }
        }
    }
    $th = S 4
    $ratio = if ($st.Budget -gt 0) { [math]::Min(1.0, $st.El / $st.Budget) } elseif ($st.Level -eq 'over') { 1.0 } else { 0 }
    if ($vertical) {
        Fill-Round $g $C.BarTrack ($W - $th) 0 $th $H 0
        Fill-Round $g $C.StripMute ($W - $th) 0 $th ($H * $ratio) 0
    } else {
        Fill-Round $g $C.BarTrack 0 ($H - $th) $W $th 0
        Fill-Round $g $C.StripMute 0 ($H - $th) ($W * $ratio) $th 0
    }
}

function Get-StageClockFont([string]$text, [int]$width, [int]$height) {
    $px = [math]::Max((S 20), [math]::Min($height * 0.82, $width / 3.5))
    $font = Font-Px $famNum $px $numStyle
    $measured = Measure-W $text $font
    if ($measured -gt $width) {
        # Jump near the fitting size to avoid caching every intermediate font.
        $px = [math]::Floor($font.Size * $width / $measured)
        $font = Font-Px $famNum $px $numStyle
        # GDI can round the measured width differently at the new size.
        while ($px -gt 6 -and (Measure-W $text $font) -gt $width) {
            $px -= 1
            $font = Font-Px $famNum $px $numStyle
        }
    }
    $font
}

function Paint-Stage($g) {
    if ($script:BarMode) { Paint-Bar $g; return }
    $W = $stage.ClientSize.Width; $H = $stage.ClientSize.Height
    if ($W -lt 50 -or $H -lt 50 -or $script:People.Count -eq 0) { return }
    $st = Get-Phase
    $g.Clear($C.Paper)
    $pad = S 20
    $cw = $W - 2 * $pad

    $head = '발표자 {0}' -f ($script:Idx + 1)
    $hw = Measure-W $head (FKM 16)
    Draw-Text $g $head (FKM 16) $C.Ink $pad (S 14) ($hw + 2) (S 26)
    if ($st.Level -eq 'over') {
        $bt = if ($st.Run -eq 'pause') { '초과 · 일시정지' } else { '시간 초과' }
        $bc = $C.Sub; $bb = $C.IdleLine
    } else {
        $bt = switch ($st.Run) { 'run' { '진행 중' } 'pause' { '일시정지' } default { '대기' } }
        $bc = $C.Ink; $bb = $C.IdleLine
    }
    [void](Draw-PillRight $g $bt (FKM 12) $NoColor $bc $bb ($W - $pad) (S 15) (S 24))

    $top = S 40
    $bottom = $H - (S 38)
    $dh = [math]::Max((S 30), $bottom - $top)
    $clockFont = Get-StageClockFont $st.Text $W $dh
    Draw-Text $g $st.Text $clockFont (Get-ClockColor $st) 0 $top $W $dh 'Center'

    $mc = $C.Sub
    if (Test-FinishHint $st) { $msg = $script:MsgFinish; $mc = $C.Accent }
    elseif ($st.Level -eq 'over' -or $st.Run -eq 'pause') { $msg = '' }
    elseif ($st.Closing) { $msg = Get-RemainingMessage $st.Rem }
    elseif (Test-UndoHint) { $msg = $script:MsgUndo; $mc = $C.Accent }
    elseif ($st.Run -eq 'idle' -and $st.Budget -le 0) { $msg = '시작하면 초과 시간을 기록합니다' }
    elseif ($st.Run -eq 'idle') { $msg = $script:MsgIdle -f (Fmt $st.Budget) }
    else { $msg = '배정 {0}' -f (Fmt $st.Budget) }
    Draw-Text $g $msg (FKM 13) $mc $pad $bottom $cw (S 22) 'Center'

    $n = $script:People.Count
    $gap = if ($n -gt 12) { S 2 } else { S 4 }
    $segW = ($cw - $gap * ($n - 1)) / $n
    for ($i = 0; $i -lt $n; $i++) {
        $x = $pad + $i * ($segW + $gap)
        Fill-Round $g $C.Hair $x ($H - (S 7)) $segW (S 3) (S 1)
        if ($i -eq $script:Idx) {
            $ratio = if ($st.Budget -gt 0) { [math]::Min(1.0, $st.El / $st.Budget) } elseif ($st.Level -eq 'over') { 1.0 } else { 0 }
            Fill-Round $g $C.Sub $x ($H - (S 7)) ($segW * $ratio) (S 3) (S 1)
        } elseif ((Get-Elapsed $i) -gt 0) {
            Fill-Round $g $C.Done $x ($H - (S 7)) $segW (S 3) (S 1)
        }
    }
}

function Paint-Band($g) {
    $g.Clear($C.Band)
    Draw-HLine $g $C.Hair 0 $band.ClientSize.Width 0
}

# ---------------- actions ----------------
function Refresh-All {
    if ($script:People.Count -eq 0) { return }
    $st = Get-Phase
    $btnRun.Text = switch ($st.Run) { 'run' { '일시정지' } 'pause' { '계속' } default { '시작' } }
    $isLast = $script:Idx -ge $script:People.Count - 1
    $btnNext.Text = if ($isLast) { '종료' } else { '다음' }
    # Next/finish only while the clock runs: hidden before the start and while paused.
    $btnNext.Visible = $script:Sw.IsRunning
    $btnUndo.Enabled = Test-UndoAllowed
    $btnBarRun.Text = $btnRun.Text
    $btnBarNext.Text = $btnNext.Text
    $btnBarRun.Glyph = if ($script:Sw.IsRunning) { 'pause' } else { 'play' }
    $btnBarNext.Glyph = if ($isLast) { 'stop' } else { 'next' }
    $nextTip = if ($isLast) { '회의를 종료합니다 (N / →)' } else { '다음 발표자를 바로 시작합니다 (N / →)' }
    if ($tips.GetToolTip($btnNext) -ne $nextTip) {
        $tips.SetToolTip($btnNext, $nextTip)
    }
    $btnBarNext.Enabled = $script:Sw.IsRunning
    $btnBarUndo.Enabled = Test-UndoAllowed
    if ($script:BarMode) { Layout-BarControls }
    # The title doubles as the taskbar label while minimized.
    $speaker = $script:Idx + 1
    if ($script:BarMode) { $speaker = '{0}/{1}' -f $speaker, $script:People.Count }
    $form.Text = '{0} · 발표자 {1} · CameraHAL_MeetingTimer' -f $st.Text, $speaker
    $strip.Invalidate()
    $stage.Invalidate()
}

function Confirm-Action([string]$message, [string]$title) {
    $owner = $form
    if ($script:SetDlg -and -not $script:SetDlg.IsDisposed -and $script:SetDlg.Visible) { $owner = $script:SetDlg }
    [Windows.Forms.MessageBox]::Show($owner, $message, $title, 'YesNo', 'Warning', 'Button2') -eq 'Yes'
}

function Confirm-SpeakerStart([int]$i) {
    if (-not $script:People[$i].Started -and (Get-MeetingLeft) -le 0) {
        return (Confirm-Action "회의 종료 시각이 지났습니다.
추가 배정 없이 초과 시간을 기록하며 계속할까요?" '회의 시간 종료')
    }
    $true
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
    if ($script:Sw.IsRunning) { $script:Sw.Stop() }
    else {
        if (-not (Confirm-SpeakerStart $script:Idx)) { return }
        Lock-Budget
        $script:Sw.Start()
    }
    Refresh-All
}

function Go-Next {
    # Same rule as the button (also covers N and the right arrow): the clock must be running.
    if (-not $script:Sw.IsRunning) { return }
    $isLast = $script:Idx -ge $script:People.Count - 1
    if (-not $isLast -and -not (Confirm-SpeakerStart ($script:Idx + 1))) { return }
    Save-Undo $(if ($isLast) { 'finish' } else { 'next' })
    if ($isLast) {
        # Finishing ends the meeting: no summary, go straight to a fresh one.
        Commit-Current
        Start-Over
    } else {
        $script:BatonStarted = Get-Date
        Switch-To ($script:Idx + 1)
        if ($timer) { $timer.Interval = 30 }
    }
}

# Clears the current speaker's clock and share (e.g. after an accidental start).
function Reset-Current {
    $wasRunning = $script:Sw.IsRunning
    # Nothing to clear: keep any earlier undo instead of overwriting it with a no-op.
    if (-not $wasRunning -and (Get-Elapsed $script:Idx) -eq 0 -and $script:People[$script:Idx].Budget -eq 0) { return }
    if (-not (Confirm-Action '현재 발표자의 사용 시간과 배정 시간을 지울까요?' '현재 발표자 초기화')) { return }
    Save-Undo 'reset'
    $script:Sw.Reset()
    $script:People[$script:Idx] = New-Person
    if ($wasRunning -and (Get-MeetingLeft) -gt 0) { Lock-Budget; $script:Sw.Start() }
    Refresh-All
}

function Start-Over([datetime]$endTime = (Get-NextHour)) {
    $script:BatonStarted = $null
    $script:Sw.Reset()
    $script:People = @(1..$script:Cfg.Count | ForEach-Object { New-Person })
    $script:Idx = 0
    $script:End = $endTime
    $script:Plan = 0.0
    Refresh-All
}

# ---------------- undo ----------------
# One level of undo for the keys that cannot be taken back otherwise: Next (including the
# finish that starts a fresh meeting) and Reset. The time that passed since then belongs to
# the speaker who was talking, so it is given back to them if their clock was running.
$script:Undo = $null
function Save-Undo([string]$kind) {
    $copy = @($script:People | ForEach-Object { $_.PSObject.Copy() })
    # Fold the running stopwatch into the copy, the same way Commit-Current would.
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

function Undo-Last {
    $u = $script:Undo
    if (-not (Test-UndoAllowed)) { return }
    $script:Undo = $null
    $script:Sw.Reset()
    $script:BatonStarted = $null
    $script:People = $u.People
    $script:Idx = $u.Idx
    $script:End = $u.End
    $script:Plan = $u.Plan
    if ($u.Running) {
        $script:People[$script:Idx].Used += [math]::Max(0, ((Get-Date) - $u.At).TotalSeconds)
        $script:Sw.Start()
    }
    Refresh-All
}

# True for a few seconds after an undoable action, so the coaching line can offer Ctrl+Z.
function Test-UndoHint {
    (Test-UndoAllowed) -and ((Get-Date) - $script:Undo.At).TotalSeconds -lt 10
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
function Resolve-EndTime([datetime]$picked, [datetime]$original) {
    if ($picked.Hour -eq $original.Hour -and $picked.Minute -eq $original.Minute) { return $original }
    $now = Get-Date
    $end = $now.Date.AddHours($picked.Hour).AddMinutes($picked.Minute)
    if ($end -le $now) { $end = $end.AddDays(1) }
    $end
}

# Validate a fresh meeting against all speakers, including anyone who spoke in the old one.
function Get-ScheduleIssue([long]$count, [datetime]$end) {
    if ($count -gt 50) { return '한 회의에는 최대 50명까지 참여할 수 있습니다. 50명 이하로 설정해 주세요.' }
    $remaining = ($end - (Get-Date)).TotalSeconds
    $seconds = [math]::Max(0, [math]::Floor($remaining))
    $capacity = [int][math]::Floor($seconds / $script:MinShare)
    if ($count -le $capacity) { return }
    $need = [int][math]::Ceiling($count * $script:MinShare / 60)
    $reason = if ($remaining -le 0) { '선택한 종료 시각이 지났습니다.' } else {
        '남은 시간은 {0}분 {1}초입니다.' -f [math]::Floor($seconds / 60), ($seconds % 60)
    }
    $next = if ($capacity -ge 1) { "발표자를 ${capacity}명 이하로 줄이거나`n종료 시각을 늦춰 주세요." }
            else { '종료 시각을 조금 더 늦춰 주세요.' }
    "$reason`n${count}명에게 1분씩, 최소 ${need}분이 필요합니다.`n`n$next"
}

function Show-ScheduleNotice([string]$reason) {
    $palette = $Themes.light
    $notice = New-Object Windows.Forms.Form
    try {
        $notice.Name = 'ScheduleNotice'
        $notice.Text = '회의 설정'
        $notice.StartPosition = 'CenterParent'
        $notice.FormBorderStyle = 'FixedDialog'
        $notice.MaximizeBox = $false
        $notice.MinimizeBox = $false
        $notice.ShowInTaskbar = $false
        $notice.BackColor = $palette.Paper
        $heading = New-DlgLabel '회의 설정을 조정해 주세요' (FKM 20) $palette.Ink 24 20 296 32
        $body = New-DlgLabel $reason (FK 14) $palette.Sub 24 64 296 1
        $body.Name = 'Reason'
        $body.MaximumSize = New-Object Drawing.Size((S 296), 0)
        $body.AutoSize = $true
        $back = New-Button '설정으로 돌아가기' 'primary' 144 44 {} $palette
        $back.DialogResult = 'OK'
        $notice.AcceptButton = $back
        $notice.CancelButton = $back
        $notice.Controls.AddRange(@($heading, $body, $back))
        $back.Location = New-Object Drawing.Point((S 176), ($body.Bottom + (S 24)))
        $notice.ClientSize = New-Object Drawing.Size((S 344), ($back.Bottom + (S 24)))
        [void]$notice.ShowDialog($script:SetDlg)
    } finally { $notice.Dispose() }
}

function Update-SettingsHint {
    $end = $script:SetProposedEnd
    $count = [int]$script:SetNum.Value
    $script:SetEndLabel.Text = if ($end.Date -gt (Get-Date).Date) { '종료 시각 · 다음 날' } else { '종료 시각' }
    $capacity = [math]::Min(50, [math]::Max(0, [math]::Floor(($end - (Get-Date)).TotalSeconds / $script:MinShare)))
    $script:SetHint.Text = if ($capacity -eq 0) { '새 회의를 시작하려면 최소 1분이 필요합니다.' }
        elseif ($count -gt $capacity) { '현재 종료 시각에는 최대 {0}명까지 배정할 수 있습니다. 인원이나 종료 시각을 조정해 주세요.' -f $capacity }
        else { '1인당 1분 기준으로 최대 {0}명입니다.' -f $capacity }
}

function Show-Settings {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Name = 'Settings'
    $dlg.Text = '회의 설정'
    $dlg.ClientSize = New-Object Drawing.Size((S 340), (S 420))
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.TopMost = $true
    # Native controls (NumericUpDown, DateTimePicker) cannot be themed cleanly, so this dialog stays light.
    $L = $Themes.light
    $dlg.BackColor = $L.Paper
    $dlg.KeyPreview = $true

    $title = New-DlgLabel '설정' (FKM 22) $L.Ink 24 20 292 34

    $l1 = New-DlgLabel '발표자 수' (FKM 14) $L.Ink 24 72 140 22
    $num = New-Object MtSpeakerCount
    $num.Name = 'SpeakerCount'
    $num.TabIndex = 0
    $num.Minimum = 1
    # Keep over-limit typed drafts visible until Save can explain the limit.
    $num.Maximum = [int]::MaxValue
    $num.AccessibleDescription = '발표자 수는 1명부터 50명까지 설정할 수 있습니다.'
    $num.Value = [decimal]$script:People.Count
    $num.Font = FK 15
    $num.BorderStyle = 'FixedSingle'
    $num.SetBounds((S 24), (S 98), (S 120), (S 32))

    $l2 = New-DlgLabel '종료 시각' (FKM 14) $L.Ink 172 72 144 22
    $dt = New-Object Windows.Forms.DateTimePicker
    $dt.Name = 'MeetingEnd'
    $dt.TabIndex = 1
    $dt.Format = 'Custom'
    $dt.CustomFormat = 'HH:mm'
    $dt.ShowUpDown = $true
    $dt.Font = FK 15
    $script:SetProposedEnd = $script:End
    $dt.Value = $script:SetProposedEnd
    $script:SetEndLabel = $l2
    $dt.SetBounds((S 172), (S 98), (S 120), (S 32))

    $h1 = New-DlgLabel '' (FK 12) $L.Sub 24 132 292 44
    $resetHint = New-DlgLabel "인원이나 종료 시각을 바꿔 저장하면`n기록이 지워지고 1번 발표자가 대기합니다." (FK 13) $L.Ink 24 176 292 48
    $script:SetNum = $num
    $script:SetDt = $dt
    $script:SetHint = $h1
    $num.add_Increasing({
        param($sender, $eventArgs)
        $issue = Get-ScheduleIssue ([long]$sender.Value + 1) $script:SetProposedEnd
        if ($issue) {
            $eventArgs.Cancel = $true
            Show-ScheduleNotice $issue
        }
    })
    $num.add_ValueChanged({ Update-SettingsHint })
    $dt.add_ValueChanged({
        $script:SetProposedEnd = Resolve-EndTime $script:SetDt.Value $script:End
        Update-SettingsHint
    })
    Update-SettingsHint

    $cbTop = New-Object Windows.Forms.CheckBox
    $cbTop.TabIndex = 2
    $cbTop.Text = '항상 다른 창 위에 표시'
    $cbTop.Font = FK 14
    $cbTop.ForeColor = $L.Ink
    $cbTop.Checked = $script:TopMostPref
    $cbTop.SetBounds((S 24), (S 232), (S 292), (S 26))

    $script:SetDlg = $dlg
    $script:SetStartOver = $false
    $restart = New-Button '새 회의 시작' 'quiet' 120 36 {
        $defaultEnd = Get-NextHour
        $issue = Get-ScheduleIssue ([int]$script:SetNum.Value) $defaultEnd
        if ($issue) {
            Show-ScheduleNotice ("기본 종료 시각은 {0:HH:mm}입니다.`n`n{1}`n직접 정한 종료 시각을 쓰려면 설정에서 저장을 눌러 주세요." -f $defaultEnd, $issue)
            return
        }
        $r = [Windows.Forms.MessageBox]::Show($script:SetDlg, "기록을 모두 지우고 종료 시각을 다음 정각으로 되돌립니다.`n진행할까요?", '새 회의', 'YesNo', 'Warning')
        if ($r -eq 'Yes') { $script:SetProposedEnd = $defaultEnd; $script:SetStartOver = $true; $script:SetDlg.DialogResult = 'OK'; $script:SetDlg.Close() }
    } $L
    $restart.TabIndex = 3
    $restart.Location = New-Object Drawing.Point((S 24), (S 282))
    $h2 = New-DlgLabel "기록을 지우고, 종료 시각을`n다음 정각으로 되돌립니다." (FK 12) $L.Sub 156 280 170 40

    $save = New-Button '저장' 'primary' 92 44 {
        $count = [int]$script:SetNum.Value
        if ($count -ne $script:People.Count -or $script:SetProposedEnd -ne $script:End) {
            $issue = Get-ScheduleIssue $count $script:SetProposedEnd
            if ($issue) {
                Show-ScheduleNotice $issue
                if ($script:SetProposedEnd -ne $script:End) { $script:SetDt.Select() } else { $script:SetNum.Select() }
                return
            }
        }
        $script:SetDlg.DialogResult = 'OK'
        $script:SetDlg.Close()
    } $L
    $save.TabIndex = 5
    $dlg.AcceptButton = $save
    $save.Location = New-Object Drawing.Point((S 224), (S 352))
    $cancel = New-Button '취소' 'outline' 84 44 { $script:SetDlg.DialogResult = 'Cancel'; $script:SetDlg.Close() } $L
    $cancel.TabIndex = 4
    $dlg.CancelButton = $cancel
    $cancel.Location = New-Object Drawing.Point((S 132), (S 352))

    $dlg.Controls.AddRange(@($title, $l1, $num, $l2, $dt, $h1, $resetHint, $cbTop, $restart, $h2, $cancel, $save))

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $script:TopMostPref = $cbTop.Checked
        $form.TopMost = $script:TopMostPref -or $script:BarMode
        $count = [int]$num.Value
        if ($script:SetStartOver -or $count -ne $script:People.Count -or $script:SetProposedEnd -ne $script:End) {
            $script:Cfg.Count = $count
            $script:Undo = $null
            Start-Over $script:SetProposedEnd
        }
        try { Save-Config } catch { }
        Refresh-All
    }
    $dlg.Dispose()
}

# ---------------- controls ----------------
$btnRun  = New-Button '시작' 'primary' $script:RunW 36 { Toggle-Run }
$btnNext = New-Button '다음' 'ink' $script:NextW 36 { Go-Next }
$btnUndo = New-Button '되돌리기' 'quiet' 68 36 { Undo-Last }
$btnSet = New-Button '설정' 'quiet' 52 36 { Show-Settings }
$btnLight = New-Button '☀' 'quiet' 32 30 { Choose-Theme 'light' }
$btnDark = New-Button '☾' 'quiet' 32 30 { Choose-Theme 'dark' }
$btnBar = New-Button '발표 막대' 'quiet' 32 30 { Toggle-BarMode }
$btnBar.Glyph = 'presenter-bar'
$normalButtons = @($btnRun,$btnNext,$btnUndo,$btnSet,$btnLight,$btnDark,$btnBar)
$band.Controls.AddRange($normalButtons)
$tips = New-Object Windows.Forms.ToolTip
$tab = 0
foreach ($button in $normalButtons) { $button.TabIndex = $tab; $tab++ }
$btnLight.Font = Font-Px 'Segoe UI Symbol' (S 18)
$btnDark.Font = $btnLight.Font
$btnLight.AccessibleName = '밝은 화면'
$btnDark.AccessibleName = '어두운 화면'
$tips.SetToolTip($btnRun, '시작 / 일시정지 (Space)')
$tips.SetToolTip($btnUndo, '직전 전환, 종료, 초기화 취소 (Ctrl+Z)')
$tips.SetToolTip($btnSet, '발표자 수, 종료 시각, 항상 위 표시 설정 (S)')
$tips.SetToolTip($btnBar, '화면 공유용 발표 막대 (B)')
$tips.SetToolTip($btnLight, '밝은 화면')
$tips.SetToolTip($btnDark, '어두운 화면')
$btnBarRun = New-Button '시작' 'primary' 56 28 { Toggle-Run }
$btnBarNext = New-Button '다음' 'ink' 48 28 { Go-Next }
$btnBarUndo = New-Button '되돌리기' 'quiet' 64 28 { Undo-Last }
$btnBarBack = New-Button '기본 창' 'quiet' 64 28 { Toggle-BarMode }
$btnBarUndo.Glyph = 'undo'
$btnBarBack.Glyph = 'window'
$barButtons = @($btnBarRun,$btnBarNext,$btnBarUndo,$btnBarBack)
foreach ($button in ($normalButtons + $barButtons)) { $button.RightIsInputKey = $true }
$stage.Controls.AddRange($barButtons)
$tab = 0
foreach ($button in $barButtons) { $button.Visible = $false; $button.TabIndex = $tab; $tab++ }

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
    Set-ButtonKind $btnBarRun 'primary'
    Set-ButtonKind $btnBarNext 'ink'
    foreach ($button in @($btnUndo,$btnSet,$btnBar,$btnLight,$btnDark,$btnBarUndo,$btnBarBack)) { Set-ButtonKind $button 'quiet' }
    $selected = if ($name -eq 'light') { $btnLight } else { $btnDark }
    $selected.SetColors($C.Hair, $C.Ink, $C.Hair, $C.Hair, $C.Hair)
    if ($form.IsHandleCreated) { [MtNative]::DarkTitle($form.Handle, ($name -eq 'dark')) }
    $band.Invalidate()
    Refresh-All
}

function Layout-Band {
    $x = S 16
    foreach ($button in @($btnRun,$btnNext,$btnUndo)) {
        $button.Location = New-Object Drawing.Point($x, (S 10))
        $x += $button.Width + (S 6)
    }
    $btnSet.Location = New-Object Drawing.Point(($band.ClientSize.Width - (S 16) - $btnSet.Width), (S 10))
    $right = $band.ClientSize.Width - (S 16)
    foreach ($button in @($btnBar,$btnDark,$btnLight)) {
        $right -= $button.Width
        $button.Location = New-Object Drawing.Point($right, (S 54))
        $right -= S 4
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

$stage.add_Paint({ param($s, $e) Paint-Stage $e.Graphics })
# Double-clicking empty bar space (or pressing B / Esc) restores the normal window.
$stage.add_DoubleClick({ if ($script:BarMode) { Set-BarMode $false } })

# ---------------- presenter bar ----------------
# When the facilitator shares the whole screen, the small corner window is hard to read
# and covers content. Bar mode turns the window into a thin always-on-top strip across
# the chosen edge of its screen, so the countdown is visible to everyone in the call.
$script:BarMode = $false
$script:BarH = 58
$script:BarEdge = $script:Cfg.BarEdge
$script:NormalBounds = $null
$script:BarDrag = $null

# WorkingArea keeps every dock position clear of the Windows taskbar.
function Get-BarBounds($wa, [string]$edge = $script:BarEdge) {
    $width = [math]::Min($wa.Width, (S 650))
    $height = if ($width -lt (S $script:BarTwoRowWidth)) { S 88 } else { S $script:BarH }
    $height = [math]::Min($wa.Height, $height)
    $sideWidth = [math]::Min($wa.Width, (S 164))
    $sideHeight = [math]::Min($wa.Height, (S 320))
    $centerX = $wa.Left + [int](($wa.Width - $width) / 2)
    $centerY = $wa.Top + [int](($wa.Height - $sideHeight) / 2)
    switch ($edge) {
        'top' { New-Object Drawing.Rectangle($centerX, $wa.Top, $width, $height) }
        'left' { New-Object Drawing.Rectangle($wa.Left, $centerY, $sideWidth, $sideHeight) }
        'right' { New-Object Drawing.Rectangle(($wa.Right - $sideWidth), $centerY, $sideWidth, $sideHeight) }
        default { New-Object Drawing.Rectangle($centerX, ($wa.Bottom - $height), $width, $height) }
    }
}

function Get-NearestBarEdge($point, $wa) {
    $distances = @{
        bottom = [math]::Abs($point.Y - $wa.Bottom)
        top = [math]::Abs($point.Y - $wa.Top)
        left = [math]::Abs($point.X - $wa.Left)
        right = [math]::Abs($point.X - $wa.Right)
    }
    $nearest = 'bottom'
    foreach ($edge in @('top','left','right')) {
        if ($distances[$edge] -lt $distances[$nearest]) { $nearest = $edge }
    }
    $nearest
}

function Layout-BarControls {
    if (-not $script:BarMode) { return }
    $vertical = $script:BarEdge -eq 'left' -or $script:BarEdge -eq 'right'
    if ($vertical) {
        $x = [int](($stage.ClientSize.Width - (S 72)) / 2)
        $y = $stage.ClientSize.Height - (S 88)
        for ($i = 0; $i -lt $barButtons.Count; $i++) {
            $button = $barButtons[$i]
            $button.Size = New-Object Drawing.Size((S 32), (S 32))
            $button.Location = New-Object Drawing.Point(($x + ($i % 2) * (S 40)), ($y + [int][math]::Floor($i / 2) * (S 40)))
        }
    } else {
        $x = $stage.ClientSize.Width - (S 12)
        $y = if ($stage.ClientSize.Width -lt (S $script:BarTwoRowWidth)) { $stage.ClientSize.Height - (S 42) }
             else { [int](($stage.ClientSize.Height - (S 36)) / 2) }
        for ($i = $barButtons.Count - 1; $i -ge 0; $i--) {
            $button = $barButtons[$i]
            $button.Size = New-Object Drawing.Size((S 32), (S 32))
            $x -= $button.Width
            $button.Location = New-Object Drawing.Point($x, $y)
            $x -= S 4
        }
    }
}

function Dock-Bar($point) {
    $wa = [Windows.Forms.Screen]::FromPoint($point).WorkingArea
    $script:BarEdge = Get-NearestBarEdge $point $wa
    $form.Bounds = Get-BarBounds $wa
    Layout-BarControls
    $stage.Invalidate()
    try { Save-Config } catch { }
}

function Set-BarMode([bool]$on) {
    if ($on -eq $script:BarMode) { return }
    $script:BarDrag = $null
    $stage.Capture = $false
    $script:BarMode = $on
    $form.SuspendLayout()
    if ($on) {
        $script:NormalBounds = $form.Bounds
        $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        $form.MinimumSize = [Drawing.Size]::Empty
        $form.FormBorderStyle = 'None'
        $strip.Visible = $false
        $band.Visible = $false
        $form.Bounds = Get-BarBounds $wa
        $form.TopMost = $true
    } else {
        $form.FormBorderStyle = 'Sizable'
        $strip.Visible = $true
        $band.Visible = $true
        $form.MinimumSize = $script:NormalMin
        if ($script:NormalBounds) { $form.Bounds = $script:NormalBounds } else { Place-Corner }
        $form.TopMost = $script:TopMostPref
        if ($form.IsHandleCreated -and $script:ThemeName -eq 'dark') { [MtNative]::DarkTitle($form.Handle, $true) }
    }
    foreach ($button in $barButtons) { $button.Visible = $on }
    $stage.Cursor = if ($on) { [Windows.Forms.Cursors]::SizeAll } else { [Windows.Forms.Cursors]::Default }
    $form.ResumeLayout()
    Layout-BarControls
    $stage.Invalidate()
    Refresh-All
    if ($on) { $btnBarRun.Select() } else { $btnBar.Select() }
}

$stage.add_MouseDown({
    param($s, $e)
    if (-not $script:BarMode -or $e.Button -ne 'Left') { return }
    $script:BarDrag = [pscustomobject]@{ Cursor = [Windows.Forms.Cursor]::Position; Origin = $form.Location; Moving = $false }
    $stage.Capture = $true
})
$stage.add_MouseMove({
    if ($null -eq $script:BarDrag) { return }
    $point = [Windows.Forms.Cursor]::Position
    $dx = $point.X - $script:BarDrag.Cursor.X
    $dy = $point.Y - $script:BarDrag.Cursor.Y
    if ([math]::Abs($dx) -gt [Windows.Forms.SystemInformation]::DragSize.Width -or [math]::Abs($dy) -gt [Windows.Forms.SystemInformation]::DragSize.Height) { $script:BarDrag.Moving = $true }
    if ($script:BarDrag.Moving) { $form.Location = New-Object Drawing.Point(($script:BarDrag.Origin.X + $dx), ($script:BarDrag.Origin.Y + $dy)) }
})
$stage.add_MouseUp({
    param($s, $e)
    if ($e.Button -ne 'Left' -or $null -eq $script:BarDrag) { return }
    $moved = $script:BarDrag.Moving
    $script:BarDrag = $null
    $stage.Capture = $false
    if ($moved) { Dock-Bar ([Windows.Forms.Cursor]::Position) }
})
$stage.add_MouseCaptureChanged({
    if ($script:BarDrag -and -not $stage.Capture) {
        $script:BarDrag = $null
        if ($script:BarMode) { $form.Bounds = Get-BarBounds ([Windows.Forms.Screen]::FromControl($form).WorkingArea); Layout-BarControls }
    }
})
$stage.add_Resize({ Layout-BarControls })

function Toggle-BarMode {
    Set-BarMode (-not $script:BarMode)
    try { Save-Config } catch { }
}
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
        'Right' { if ($e.Modifiers -ne 'None') { return }; Go-Next }
        'R'     { Reset-Current }
        'Z'     { if ($e.Control) { Undo-Last } else { return } }
        'S'     { Show-Settings }
        'D'     { Choose-Theme $(if ($script:ThemeName -eq 'dark') { 'light' } else { 'dark' }) }
        'B'     { Toggle-BarMode }
        'Escape' { if ($script:BarMode) { Toggle-BarMode } else { return } }
        default { return }
    }
    $e.Handled = $true
    $e.SuppressKeyPress = $true
})

$timer.add_Tick({
    if ($timer.Interval -ne 200 -and (Get-BatonOffset) -eq 0) {
        $script:BatonStarted = $null
        $timer.Interval = 200
    }
    Refresh-All
})

$form.add_FormClosing({
    $timer.Stop()
    try { Save-Config } catch { }
})

# ---------------- start ----------------
Set-Theme $script:ThemeName
Start-Over
Place-Corner
# Reopen as the presenter bar if that is how the timer was closed last time.
if ($script:Cfg.Bar) { Set-BarMode $true }
$timer.Start()
[void]$form.ShowDialog()
$form.Dispose()
$tips.Dispose()
