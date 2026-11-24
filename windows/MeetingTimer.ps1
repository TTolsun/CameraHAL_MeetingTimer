# MeetingTimer.ps1 - Compact weekly meeting speaker timer (Windows PowerShell 5.1 + WinForms)
#
# - Meeting end defaults to the next full hour after launch (14:05 -> 15:00).
# - Enter only the number of speakers; the remaining meeting time is split
#   automatically. Each speaker's share is locked when they start, so an
#   overrun shrinks the shares of the people still waiting.
# - A highlighted number marks the current speaker in the bar. Overtime digits change color at +00:15.
#
# Visual style follows the HP-inspired DESIGN.md (getdesign.md/hp): white canvas,
# #1a1a1a ink, a single #024ad8 accent, 4px buttons, 1px hairlines.
# Launch with MeetingTimer.bat (WinForms needs a single-threaded apartment, hence -STA).

param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))

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

public class MtTimerForm : Form {
    public event EventHandler SwitchViewRequested;

    protected override void WndProc(ref Message message) {
        const int WM_SYSCOMMAND = 0x0112, SC_MINIMIZE = 0xF020, SC_MAXIMIZE = 0xF030;
        long command = message.WParam.ToInt64() & 0xFFF0;
        if (message.Msg == WM_SYSCOMMAND && SwitchViewRequested != null &&
            ((MinimizeBox && command == SC_MINIMIZE) || (MaximizeBox && command == SC_MAXIMIZE))) {
            SwitchViewRequested(this, EventArgs.Empty);
            return;
        }
        base.WndProc(ref message);
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
                case "wrap":
                    g.DrawEllipse(pen, x-r, y-r, r*2, r*2);
                    g.DrawLine(pen, x, y-r*0.6f, x, y);
                    g.DrawLine(pen, x, y, x+r*0.5f, y+r*0.3f);
                    break;
                case "undo":
                    g.DrawArc(pen, x-r, y-r*0.3f, r*2, r*1.3f, 180, 250);
                    g.FillPolygon(brush, new PointF[] { new PointF(x-r*1.2f,y+r*0.35f), new PointF(x-r*0.4f,y-r*0.25f), new PointF(x-r*0.4f,y+r*0.95f) });
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

$script:ConfigFile = $ConfigPath

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
        Overtime = '#8a4d22'; BarOvertime = '#ebb186'; BarActiveSpeaker = '#29433a'
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
        Overtime = '#ebb186'; BarOvertime = '#ebb186'; BarActiveSpeaker = '#29433a'
        IdleInk = '#cdcdcd'; IdleLine = '#434345'; Done = '#8a8a8c'
        BarTrack = '#242728'
        BtnPrimary = '#ffffff'; BtnPrimaryInk = '#000000'; BtnPrimaryHover = '#e8e8e8'; BtnPrimaryPress = '#cfcfcf'
        BtnInk = '#121212'; BtnInkText = '#f4f4f6'; BtnInkLine = '#3a3d3f'; BtnInkHover = '#1c1c1d'; BtnInkPress = '#242728'
    }
}
$C = $Themes.light
$NoColor = [Drawing.Color]::Empty

$installed = @((New-Object Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
function Pick-Font([string[]]$cands, [string]$fallback) {
    foreach ($name in $cands) { if ($installed -contains $name) { return $name } }
    $fallback
}
$famKo    = Pick-Font @('Pretendard', 'Pretendard Variable') 'Segoe UI'
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
    $cfg = [pscustomobject]@{ Count = 6; TopMost = $true; Theme = 'light'; Bar = $false; WrapMinutes = 0 }
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
        if ($j.WrapMinutes -is [int] -and $j.WrapMinutes -ge 0 -and $j.WrapMinutes -le 59) { $cfg.WrapMinutes = $j.WrapMinutes }
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
        Theme    = [string]$script:ThemeName
        WrapMinutes = [int]$script:WrapMinutes
    } | ConvertTo-Json
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:ConfigFile))
    [IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object Text.UTF8Encoding $false))
}

. (Join-Path $PSScriptRoot 'TimeModel.ps1')

$script:Cfg = Load-Config
$script:ThemeName = $script:Cfg.Theme
$C = $Themes[$script:ThemeName]
$script:Sw = New-Object System.Diagnostics.Stopwatch
$script:People = @()

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
$script:MsgIdle = 'Allocated {0} · Press Start'
$script:MsgPause = 'Paused'
$script:MsgUndo = 'Press Ctrl+Z to undo'
$script:MsgFinish = 'Meeting ended. Press Ctrl+Z to undo.'
$script:MsgBarFinish = 'Meeting ended · Undo'
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
    if ($labels) { $need += (Measure-W 'Now' (FK 12)) + (Measure-W 'End' (FK 12)) + (S 12) }
    $need
}

# Narrowest client width at which nothing important is cut off. Measured from the real
# fonts, so a missing Pretendard (falls back to Segoe UI) still gets a safe value.
function Get-MinClientWidth {
    $topBar = Get-StripNeed $false 'May run over'
    $band = (S 16) + (S $script:RunW) + (S 6) + (S $script:NextW) + (S 6) + (S 68) + (S 10) + (S 68) + (S 16)
    $head = (S 20) * 2 + (Measure-W 'Speaker 50' (FKM 16)) + (Measure-W 'Overtime · Paused' (FKM 12)) + (S 18)
    $msgs = @('59 min 59 sec left', 'Meeting end time reached', $script:MsgPause, ($script:MsgIdle -f '00:00'), $script:MsgUndo, $script:MsgFinish)
    $coach = (S 20) * 2 + (($msgs | ForEach-Object { Measure-W $_ (FKM 13) } | Measure-Object -Maximum).Maximum)
    [math]::Max([math]::Max($topBar, $band), [math]::Max($head, $coach))
}

# ---------------- window ----------------
$form = New-Object MtTimerForm
$form.Text = 'Time per Turn'
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
$script:BarTwoRowWidth = 520

# ---------------- painting ----------------

# Current speaker's share minus the first plan, in whole seconds, with its color on the dark strip.
function Get-PlanDelta {
    $d = Get-PlanDifference
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
        $tailFull = 'May run past end time'; $tailShort = 'May run over'; $tc = $C.Warn
    } elseif ($left -gt 0) {
        $m = [int][math]::Ceiling($left / 60)
        $tailFull = '{0} min left' -f $m; $tailShort = '{0} min' -f $m; $tc = $C.StripMute
    } else {
        $tailFull = 'End time reached'; $tailShort = 'Meeting ended'; $tc = $C.Warn
    }

    # Pick the richest variant that fits: full text, short tail, then no "Now"/"Finish" labels.
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
        $lw = Measure-W 'Now' (FK 12)
        Draw-Text $g 'Now' (FK 12) $C.StripMute $x 0 ($lw + 2) $H
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
        $kw = Measure-W 'End' (FK 12)
        Draw-Text $g 'End' (FK 12) $C.StripMute ($right - $kw) 0 ($kw + 2) $H
        $rightStart = $right - $kw
    }

    # Change versus the first plan, centered between the clock and the end time.
    if ($null -ne $script:WrapStart) { return }
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

function Paint-BarSpeakers($g, [int]$left, [int]$width, [int]$height) {
    $window = Get-SpeakerWindow $script:People.Count $script:Idx
    $slot = S 22
    $rowW = ($window.Last - $window.First + 1) * $slot
    $labelH = S 24
    $labelTop = [int](($height - $labelH) / 2)
    $x = $left + [int](($width - $rowW) / 2)
    if ($window.Before) { Draw-Text $g '…' (FK 12) $C.StripMute ($x - (S 14)) $labelTop (S 14) $labelH 'Center' }
    if ($window.After) { Draw-Text $g '…' (FK 12) $C.StripMute ($x + $rowW) $labelTop (S 14) $labelH 'Center' }
    for ($i = $window.First; $i -le $window.Last; $i++) {
        $slotX = $x + ($i - $window.First) * $slot
        $fg = $C.StripMute
        if ($i -eq $script:Idx) {
            Fill-Round $g $C.BarActiveSpeaker $slotX $labelTop $slot $labelH (S 5)
            $fg = $C.StripInk
        }
        Draw-Text $g ($i + 1) (FN 13) $fg $slotX $labelTop $slot $labelH 'Center'
    }
}

function Get-RemainingMessage([double]$seconds) {
    $whole = [int][math]::Ceiling($seconds)
    $minutes = [int][math]::Floor($whole / 60)
    $secs = $whole % 60
    if ($minutes -eq 0) { return '{0} sec left' -f $secs }
    if ($secs -eq 0) { return '{0} min left' -f $minutes }
    '{0} min {1} sec left' -f $minutes, $secs
}

function Test-FinishHint($state) {
    $state.Run -eq 'idle' -and $script:Undo.Kind -eq 'finish' -and (Test-UndoHint)
}

function Get-BarMessage($state) {
    if (Test-FinishHint $state) { return $script:MsgBarFinish }
    if ($state.Run -eq 'wrap') {
        if ($state.Rem -le 0) { return 'Overtime' }
        return 'Ends {0:HH:mm}' -f $script:End
    }
    if ($state.Run -eq 'run' -and $script:WrapMinutes -gt 0 -and $script:Idx -eq $script:People.Count - 1) {
        return 'Next: wrap-up'
    }
    if ($state.Run -eq 'pause') { return $script:MsgPause }
    if ($state.Level -eq 'over') { return '' }
    if ($state.Run -eq 'idle') { return 'Ready' }
    if ($state.Closing) { return Get-RemainingMessage $state.Rem }
    'Running'
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
    $dc = Get-ClockColor $st $true
    $msg = Get-BarMessage $st
    $firstRow = $H - (S 46)
    if ($st.Run -eq 'wrap') {
        $narrow = $W -lt (S $script:BarTwoRowWidth)
        $height = if ($narrow) { $firstRow } else { $H - (S 4) }
        $right = if ($narrow) { $W } else { $btnBarRun.Left - (S 58) }
        Draw-Text $g 'Wrap-up' (FKM 16) $C.StripInk (S 12) 0 (S 86) $height
        Draw-Clock $g $st.Text $dc (S 98) 0 ($right - (S 110)) $height
        if ($narrow) {
            Draw-Text $g $msg (FKM 12) $C.StripMute (S 12) $firstRow (S 130) (S 40)
        } else {
            Draw-Text $g $msg (FKM 12) $C.StripMute $right 0 (S 83) $height
        }
        $th = S 4
        $ratio = if ($st.Budget -gt 0) { [math]::Min(1.0, $st.El / $st.Budget) } else { 1.0 }
        Fill-Round $g $C.BarTrack 0 ($H - $th) $W $th 0
        Fill-Round $g $C.StripMute 0 ($H - $th) ($W * [math]::Max(0, $ratio)) $th 0
        return
    }
    $head = '{0} / {1}' -f ($script:Idx + 1), $script:People.Count
    if ($W -lt (S $script:BarTwoRowWidth)) {
        # In a narrow window the speaker numbers and clock share the top row.
        $pad = S 8
        $speakerW = S 140
        $clockX = $pad + $speakerW
        Paint-BarSpeakers $g $pad $speakerW $firstRow
        $clockW = $W - $clockX - $pad
        if ($msg -eq $script:MsgBarFinish) {
            Draw-Clock $g $st.Text $dc $clockX 0 $clockW ($firstRow - (S 18))
            Draw-Text $g $msg (FKM 12) $C.StripInk $clockX ($firstRow - (S 18)) $clockW (S 18) 'Center'
            $msg = ''
        } else {
            Draw-Clock $g $st.Text $dc $clockX 0 $clockW $firstRow
        }
        $headW = S 72
        Draw-Text $g $head (FKM 14) $C.StripInk $pad $firstRow $headW (S 40) 'Center'
        $messageX = $pad + $headW + (S 4)
        $messageW = $btnBarRun.Left - $messageX - $pad
        if ($messageW -gt (S 40)) {
            Draw-Text $g $msg (FKM 12) $C.StripMute $messageX $firstRow $messageW (S 40)
        }
    } else {
        $headW = S 72
        $speakerW = S 146
        $pad = S 12
        Draw-Text $g $head (FKM 15) $C.StripInk $pad 0 $headW ($H - (S 4)) 'Center'
        Paint-BarSpeakers $g ($pad + $headW) $speakerW ($H - (S 4))
        $clockX = $pad + $headW + $speakerW
        $clockW = [math]::Max((S 134), $btnBarRun.Left - $clockX - (S 145))
        $messageX = $clockX + $clockW
        $messageW = $btnBarRun.Left - $messageX - (S 8)
        if ($msg -eq $script:MsgBarFinish -and $messageW -lt (Measure-W $msg (FKM 12))) {
            Draw-Clock $g $st.Text $dc $clockX 0 $clockW ($H - (S 23))
            Draw-Text $g $msg (FKM 12) $C.StripInk $clockX ($H - (S 23)) $clockW (S 19) 'Center'
        } else {
            Draw-Clock $g $st.Text $dc $clockX 0 $clockW ($H - (S 4))
            if ($messageW -gt (S 40)) {
                Draw-Text $g $msg (FKM 12) $C.StripMute $messageX 0 $messageW ($H - (S 4))
            }
        }
    }
    $th = S 4
    $ratio = if ($st.Budget -gt 0) { [math]::Min(1.0, $st.El / $st.Budget) } elseif ($st.Level -eq 'over') { 1.0 } else { 0 }
    Fill-Round $g $C.BarTrack 0 ($H - $th) $W $th 0
    Fill-Round $g $C.StripMute 0 ($H - $th) ($W * $ratio) $th 0
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

function Draw-Clock($g, [string]$text, $color, [int]$x, [int]$y, [int]$width, [int]$height) {
    if ($width -le 0 -or $height -le 0) { return }
    $font = Get-StageClockFont $text $width $height
    Draw-Text $g $text $font $color $x $y $width $height 'Center'
}

function Paint-Stage($g) {
    if ($script:BarMode) { Paint-Bar $g; return }
    $W = $stage.ClientSize.Width; $H = $stage.ClientSize.Height
    if ($W -lt 50 -or $H -lt 50 -or $script:People.Count -eq 0) { return }
    $st = Get-Phase
    $g.Clear($C.Paper)
    $pad = S 20
    $cw = $W - 2 * $pad

    $head = if ($st.Run -eq 'wrap') { 'Wrap-up' } else { 'Speaker {0}' -f ($script:Idx + 1) }
    $hw = Measure-W $head (FKM 16)
    Draw-Text $g $head (FKM 16) $C.Ink $pad (S 14) ($hw + 2) (S 26)
    if ($st.Level -eq 'over') {
        $bt = if ($st.Run -eq 'pause') { 'Overtime · Paused' } else { 'Overtime' }
        $bc = $C.Sub; $bb = $C.IdleLine
    } else {
        $bt = switch ($st.Run) { 'run' { 'Running' } 'wrap' { 'Running' } 'pause' { 'Paused' } default { 'Ready' } }
        $bc = $C.Ink; $bb = $C.IdleLine
    }
    [void](Draw-PillRight $g $bt (FKM 12) $NoColor $bc $bb ($W - $pad) (S 15) (S 24))

    $top = S 40
    $bottom = $H - (S 38)
    $dh = [math]::Max((S 30), $bottom - $top)
    Draw-Clock $g $st.Text (Get-ClockColor $st) 0 $top $W $dh

    $mc = $C.Sub
    if ($st.Run -eq 'wrap') {
        $msg = if ($st.Rem -gt 0) { Get-RemainingMessage $st.Rem } else { 'Meeting end time reached' }
    }
    elseif (Test-FinishHint $st) { $msg = $script:MsgFinish; $mc = $C.Accent }
    elseif ($st.Level -eq 'over' -or $st.Run -eq 'pause') { $msg = '' }
    elseif ($st.Closing) { $msg = Get-RemainingMessage $st.Rem }
    elseif (Test-UndoHint) { $msg = $script:MsgUndo; $mc = $C.Accent }
    elseif ($st.Run -eq 'idle' -and (Get-MeetingLeft) -le 0) { $msg = 'Press Start to track overtime' }
    elseif ($st.Run -eq 'idle') { $msg = $script:MsgIdle -f (Fmt $st.Budget) }
    else { $msg = 'Allocated {0}' -f (Fmt $st.Budget) }
    Draw-Text $g $msg (FKM 13) $mc $pad $bottom $cw (S 22) 'Center'

    if ($st.Run -eq 'wrap') { return }
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
    $btnRun.Text = switch ($st.Run) { 'run' { 'Pause' } 'pause' { 'Resume' } default { 'Start' } }
    $isLast = $script:Idx -ge $script:People.Count - 1
    $wrapping = $st.Run -eq 'wrap'
    $startWrap = $isLast -and $script:WrapMinutes -gt 0 -and -not $wrapping
    $btnNext.Text = if ($startWrap) { 'Wrap-up' } elseif ($isLast) { 'Finish' } else { 'Next' }
    $btnRun.Visible = -not $wrapping
    # Next/finish only while the clock runs: hidden before the start and while paused.
    $btnNext.Visible = $script:Sw.IsRunning -or $wrapping
    $btnUndo.Enabled = Test-UndoAllowed
    $btnBarRun.Text = $btnRun.Text
    $btnBarRun.Visible = $script:BarMode -and -not $wrapping
    $btnBarNext.Text = if ($startWrap) { 'Start wrap-up' } else { $btnNext.Text }
    $btnBarRun.Glyph = if ($script:Sw.IsRunning) { 'pause' } else { 'play' }
    $btnBarNext.Glyph = if ($startWrap) { 'wrap' } elseif ($isLast) { 'stop' } else { 'next' }
    $nextTip = if ($startWrap) { 'Start wrap-up (N / →)' } elseif ($isLast) { 'Finish the meeting (N / →)' } else { 'Start the next speaker (N / →)' }
    if ($tips.GetToolTip($btnNext) -ne $nextTip) {
        $tips.SetToolTip($btnNext, $nextTip)
    }
    $btnBarNext.Enabled = $script:Sw.IsRunning -or $wrapping
    $btnBarUndo.Enabled = Test-UndoAllowed
    if ($script:BarMode) { Layout-BarControls }
    # The title doubles as the taskbar label while minimized.
    $speaker = $script:Idx + 1
    if ($script:BarMode) { $speaker = '{0}/{1}' -f $speaker, $script:People.Count }
    $head = if ($wrapping) { 'Wrap-up' } else { "Speaker $speaker" }
    $form.Text = '{0} · {1} · Time per Turn' -f $st.Text, $head
    $strip.Invalidate()
    $stage.Invalidate()
}

function Confirm-Action([string]$message, [string]$title) {
    $owner = $form
    if ($script:SetDlg -and -not $script:SetDlg.IsDisposed -and $script:SetDlg.Visible) { $owner = $script:SetDlg }
    [Windows.Forms.MessageBox]::Show($owner, $message, $title, 'YesNo', 'Warning', 'Button2') -eq 'Yes'
}

function Confirm-Overtime {
    Confirm-Action "The meeting end time has passed.
Continue and track overtime?" 'End time reached'
}

function Toggle-Run {
    if (Switch-RunState -ConfirmOvertime ${function:Confirm-Overtime} -ChooseWrap ${function:Choose-WrapReserve}) { Refresh-All }
}

function Go-Next {
    if (Move-ToNextSpeaker -ConfirmOvertime ${function:Confirm-Overtime} -ChooseWrap ${function:Choose-WrapReserve}) { Refresh-All }
}

function Reset-Current {
    if (Clear-CurrentSpeaker -ConfirmReset {
        Confirm-Action 'Reset elapsed and allocated time for this speaker?' 'Reset this speaker'
    }) { Refresh-All }
}

function Undo-Last {
    if (Restore-PreviousTurn) { Refresh-All }
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

function Choose-WrapReserve($options) {
    $palette = $Themes.light
    $dialog = New-Object Windows.Forms.Form
    try {
        $dialog.Name = 'WrapChoice'
        $dialog.Text = 'Available speaker time'
        $dialog.StartPosition = 'CenterParent'
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.MaximizeBox = $false
        $dialog.MinimizeBox = $false
        $dialog.ShowInTaskbar = $false
        $dialog.BackColor = $palette.Paper
        $body = @(
            ('{0} remaining. Estimated time at the planned end:' -f $options.Count)
            ''
            ('Keep wrap-up: {0} per speaker, {1} for wrap-up.' -f (Fmt $options.KeepShare), (Fmt $options.KeepReserve))
            ('Use wrap-up time: {0} per speaker, {1} for wrap-up.' -f (Fmt $options.UseShare), (Fmt $options.Reserve))
        ) -join [Environment]::NewLine
        $label = New-DlgLabel $body (FK 14) $palette.Ink 20 20 352 118
        $cancel = New-Button 'Cancel' 'quiet' 72 36 {} $palette
        $cancel.DialogResult = 'Cancel'
        $cancel.Location = New-Object Drawing.Point((S 20), (S 142))
        $keep = New-Button 'Keep wrap-up' 'outline' 112 36 {} $palette
        $keep.DialogResult = 'No'
        $keep.Location = New-Object Drawing.Point((S 100), (S 142))
        $use = New-Button 'Use wrap-up time' 'primary' 144 36 {} $palette
        $use.DialogResult = 'Yes'
        $use.Location = New-Object Drawing.Point((S 220), (S 142))
        $dialog.CancelButton = $cancel
        $dialog.Controls.AddRange(@($label, $cancel, $keep, $use))
        $dialog.ClientSize = New-Object Drawing.Size((S 392), (S 198))
        switch ($dialog.ShowDialog($form)) {
            'No' { 'keep' }
            'Yes' { 'use' }
            default { 'cancel' }
        }
    } finally { $dialog.Dispose() }
}

function Show-ScheduleNotice([string]$reason) {
    $palette = $Themes.light
    $notice = New-Object Windows.Forms.Form
    try {
        $notice.Name = 'ScheduleNotice'
        $notice.Text = 'Meeting settings'
        $notice.StartPosition = 'CenterParent'
        $notice.FormBorderStyle = 'FixedDialog'
        $notice.MaximizeBox = $false
        $notice.MinimizeBox = $false
        $notice.ShowInTaskbar = $false
        $notice.BackColor = $palette.Paper
        $heading = New-DlgLabel 'Adjust meeting settings' (FKM 20) $palette.Ink 24 20 296 32
        $body = New-DlgLabel $reason (FK 14) $palette.Sub 24 64 296 1
        $body.Name = 'Reason'
        $body.MaximumSize = New-Object Drawing.Size((S 296), 0)
        $body.AutoSize = $true
        $back = New-Button 'Back to settings' 'primary' 144 44 {} $palette
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
    $script:SetEndLabel.Text = if ($end.Date -gt (Get-Date).Date) { 'End time (tomorrow)' } else { 'End time' }
    $minutesLeft = ($end - (Get-Date)).TotalMinutes
    $capacity = [math]::Min(50, [math]::Max(0, [math]::Floor($minutesLeft)))
    $script:SetHint.Text = if ($capacity -eq 0) { 'Allow at least 1 min to start a meeting.' }
        elseif ($count -gt $capacity) { 'Capacity: {0}. Choose fewer speakers or a later end time.' -f $capacity }
        elseif ($script:SetWrap.Value -gt 0 -and $count + $script:SetWrap.Value -gt $minutesLeft) {
            'This schedule may require shorter turns or using some wrap-up time.'
        }
        else { 'Capacity: {0} (1 min per speaker).' -f $capacity }
}

function Show-Settings {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Name = 'Settings'
    $dlg.Text = 'Meeting settings'
    $dlg.ClientSize = New-Object Drawing.Size((S 340), (S 488))
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.TopMost = $true
    # Native controls (NumericUpDown, DateTimePicker) cannot be themed cleanly, so this dialog stays light.
    $L = $Themes.light
    $dlg.BackColor = $L.Paper
    $dlg.KeyPreview = $true

    $title = New-DlgLabel 'Settings' (FKM 22) $L.Ink 24 20 292 34

    $l1 = New-DlgLabel 'Speakers' (FKM 14) $L.Ink 24 72 140 22
    $num = New-Object MtSpeakerCount
    $num.Name = 'SpeakerCount'
    $num.TabIndex = 0
    $num.Minimum = 1
    # Keep over-limit typed drafts visible until Save can explain the limit.
    $num.Maximum = [int]::MaxValue
    $num.AccessibleDescription = 'Choose between 1 and 50 speakers.'
    $num.Value = [decimal]$script:People.Count
    $num.Font = FK 15
    $num.BorderStyle = 'FixedSingle'
    $num.SetBounds((S 24), (S 98), (S 120), (S 32))

    $l2 = New-DlgLabel 'End time' (FKM 14) $L.Ink 172 72 144 22
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
    $wrapLabel = New-DlgLabel 'Wrap-up (min)' (FKM 14) $L.Ink 24 176 292 22
    $wrap = New-Object Windows.Forms.NumericUpDown
    $wrap.Name = 'WrapMinutes'
    $wrap.AccessibleName = 'Wrap-up minutes'
    $wrap.TabIndex = 2
    $wrap.Minimum = 0
    $wrap.Maximum = 59
    $wrap.Value = $script:WrapMinutes
    $wrap.Font = FK 15
    $wrap.SetBounds((S 24), (S 202), (S 120), (S 32))
    $resetHint = New-DlgLabel "Changing speakers, end time, or wrap-up starts a new meeting." (FK 13) $L.Ink 24 244 292 48
    $script:SetNum = $num
    $script:SetDt = $dt
    $script:SetHint = $h1
    $script:SetWrap = $wrap
    $num.add_Increasing({
        param($sender, $eventArgs)
        $issue = Get-ScheduleIssue ([long]$sender.Value + 1) $script:SetProposedEnd
        if ($issue) {
            $eventArgs.Cancel = $true
            Show-ScheduleNotice $issue
        }
    })
    $num.add_ValueChanged({ Update-SettingsHint })
    $wrap.add_ValueChanged({ Update-SettingsHint })
    $dt.add_ValueChanged({
        $script:SetProposedEnd = Resolve-EndTime $script:SetDt.Value $script:End
        Update-SettingsHint
    })
    Update-SettingsHint

    $cbTop = New-Object Windows.Forms.CheckBox
    $cbTop.TabIndex = 3
    $cbTop.Text = 'Always on top'
    $cbTop.Font = FK 14
    $cbTop.ForeColor = $L.Ink
    $cbTop.Checked = $script:TopMostPref
    $cbTop.SetBounds((S 24), (S 300), (S 292), (S 26))

    $script:SetDlg = $dlg
    $script:SetStartOver = $false
    $restart = New-Button 'New meeting' 'quiet' 120 36 {
        $defaultEnd = Get-NextHour
        $issue = Get-ScheduleIssue ([int]$script:SetNum.Value) $defaultEnd
        if ($issue) {
            Show-ScheduleNotice ("Default end time: {0:HH:mm}.`n`n{1}`nTo use your own end time, choose Save in Settings." -f $defaultEnd, $issue)
            return
        }
        if (Confirm-Action ("Clear all turns and set the end time to {0:HH:mm}?" -f $defaultEnd) 'New meeting') {
            $script:SetProposedEnd = $defaultEnd; $script:SetStartOver = $true; $script:SetDlg.DialogResult = 'OK'; $script:SetDlg.Close()
        }
    } $L
    $restart.TabIndex = 4
    $restart.Location = New-Object Drawing.Point((S 24), (S 350))
    $h2 = New-DlgLabel "Clear all turns and restore the default end time." (FK 12) $L.Sub 156 348 170 40

    $save = New-Button 'Save' 'primary' 92 44 {
        $count = [int]$script:SetNum.Value
        if ($count -ne $script:People.Count -or $script:SetProposedEnd -ne $script:End -or $script:SetWrap.Value -ne $script:WrapMinutes) {
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
    $save.TabIndex = 6
    $dlg.AcceptButton = $save
    $save.Location = New-Object Drawing.Point((S 224), (S 420))
    $cancel = New-Button 'Cancel' 'outline' 84 44 { $script:SetDlg.DialogResult = 'Cancel'; $script:SetDlg.Close() } $L
    $cancel.TabIndex = 5
    $dlg.CancelButton = $cancel
    $cancel.Location = New-Object Drawing.Point((S 132), (S 420))

    $dlg.Controls.AddRange(@($title, $l1, $num, $l2, $dt, $h1, $wrapLabel, $wrap, $resetHint, $cbTop, $restart, $h2, $cancel, $save))

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $script:TopMostPref = $cbTop.Checked
        $form.TopMost = $script:TopMostPref -or $script:BarMode
        $count = [int]$num.Value
        if ($script:SetStartOver -or $count -ne $script:People.Count -or $script:SetProposedEnd -ne $script:End -or $wrap.Value -ne $script:WrapMinutes) {
            Start-Meeting $count $script:SetProposedEnd -WrapMinutes ([int]$wrap.Value)
        }
        try { Save-Config } catch { }
        Refresh-All
    }
    $dlg.Dispose()
}

# ---------------- controls ----------------
$btnRun  = New-Button 'Start' 'primary' $script:RunW 36 { Toggle-Run }
$btnNext = New-Button 'Next' 'ink' $script:NextW 36 { Go-Next }
$btnUndo = New-Button 'Undo' 'quiet' 68 36 { Undo-Last }
$btnSet = New-Button 'Settings' 'quiet' 68 36 { Show-Settings }
$btnLight = New-Button '☀' 'quiet' 32 30 { Choose-Theme 'light' }
$btnDark = New-Button '☾' 'quiet' 32 30 { Choose-Theme 'dark' }
$normalButtons = @($btnRun,$btnNext,$btnUndo,$btnSet,$btnLight,$btnDark)
$band.Controls.AddRange($normalButtons)
$tips = New-Object Windows.Forms.ToolTip
$tab = 0
foreach ($button in $normalButtons) { $button.TabIndex = $tab; $tab++ }
$btnLight.Font = Font-Px 'Segoe UI Symbol' (S 18)
$btnDark.Font = $btnLight.Font
$btnLight.AccessibleName = 'Light theme'
$btnDark.AccessibleName = 'Dark theme'
$tips.SetToolTip($btnRun, 'Start / pause (Space)')
$tips.SetToolTip($btnUndo, 'Undo the last advance, finish, or reset (Ctrl+Z)')
$tips.SetToolTip($btnSet, 'Set the speaker count, end time, and window behavior (S)')
$tips.SetToolTip($btnLight, 'Light theme')
$tips.SetToolTip($btnDark, 'Dark theme')
$btnBarRun = New-Button 'Start' 'primary' 56 28 { Toggle-Run }
$btnBarNext = New-Button 'Next' 'ink' 48 28 { Go-Next }
$btnBarUndo = New-Button 'Undo' 'quiet' 64 28 { Undo-Last }
$btnBarUndo.Glyph = 'undo'
$barButtons = @($btnBarRun,$btnBarNext,$btnBarUndo)
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
    $stage.BackColor = if ($script:BarMode) { $C.Strip } else { $C.Paper }
    $band.BackColor = $C.Band
    Set-ButtonKind $btnRun 'primary'
    Set-ButtonKind $btnNext 'ink'
    Set-ButtonKind $btnBarRun 'primary'
    Set-ButtonKind $btnBarNext 'ink'
    foreach ($button in @($btnUndo,$btnSet,$btnLight,$btnDark,$btnBarUndo)) { Set-ButtonKind $button 'quiet' }
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
    foreach ($button in @($btnDark,$btnLight)) {
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
# The same form becomes a compact bar with native maximize and close buttons.
$script:BarMode = $false
$script:NormalSize = $form.Size
$script:BarDrag = $null

function Layout-BarControls {
    if (-not $script:BarMode) { return }
    $frame = $form.Size - $form.ClientSize
    $minHeight = if ($form.ClientSize.Width -lt (S $script:BarTwoRowWidth)) { S 88 } else { S 58 }
    $form.MinimumSize = New-Object Drawing.Size(((S 300) + $frame.Width), ($minHeight + $frame.Height))
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

function Set-BarMode([bool]$on) {
    if ($on -eq $script:BarMode) { return }
    $script:BarDrag = $null
    $stage.Capture = $false
    $script:BarMode = $on
    $stage.BackColor = if ($on) { $C.Strip } else { $C.Paper }
    $form.SuspendLayout()
    if ($on) {
        $bounds = $form.Bounds
        $script:NormalSize = $bounds.Size
        $form.MinimumSize = [Drawing.Size]::Empty
        $form.MinimizeBox = $false
        $form.MaximizeBox = $true
        $frame = $form.Size - $form.ClientSize
        $height = if (($bounds.Width - $frame.Width) -lt (S $script:BarTwoRowWidth)) { S 88 } else { S 58 }
        $strip.Visible = $false
        $band.Visible = $false
        $form.SetBounds($bounds.X, $bounds.Y, $bounds.Width, ($height + $frame.Height))
        $form.TopMost = $true
    } else {
        $location = $form.Location
        $form.MaximizeBox = $false
        $form.MinimizeBox = $true
        $strip.Visible = $true
        $band.Visible = $true
        $form.MinimumSize = $script:NormalMin
        $form.SetBounds($location.X, $location.Y, $script:NormalSize.Width, $script:NormalSize.Height)
        $form.TopMost = $script:TopMostPref
        if ($form.IsHandleCreated -and $script:ThemeName -eq 'dark') { [MtNative]::DarkTitle($form.Handle, $true) }
    }
    foreach ($button in $barButtons) { $button.Visible = $on }
    $stage.Cursor = if ($on) { [Windows.Forms.Cursors]::SizeAll } else { [Windows.Forms.Cursors]::Default }
    $form.ResumeLayout()
    Layout-BarControls
    $stage.Invalidate()
    Refresh-All
    if ($on -and $btnBarRun.Visible) { $btnBarRun.Select() }
    elseif ($on) { $btnBarNext.Select() }
    elseif ($btnRun.Visible) { $btnRun.Select() }
    else { $btnNext.Select() }
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
    $script:BarDrag = $null
    $stage.Capture = $false
})
$stage.add_MouseCaptureChanged({
    if ($script:BarDrag -and -not $stage.Capture) {
        $script:BarDrag = $null
    }
})
$stage.add_Resize({ Layout-BarControls })

function Toggle-BarMode {
    Set-BarMode (-not $script:BarMode)
    try { Save-Config } catch { }
}
$form.add_SwitchViewRequested({ Toggle-BarMode })
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

$timer.add_Tick({ Refresh-All })

$form.add_FormClosing({
    $timer.Stop()
    try { Save-Config } catch { }
})

# ---------------- start ----------------
Set-Theme $script:ThemeName
Start-Meeting $script:Cfg.Count -WrapMinutes $script:Cfg.WrapMinutes
Refresh-All
Place-Corner
# Reopen as the presenter bar if that is how the timer was closed last time.
if ($script:Cfg.Bar) { Set-BarMode $true }
$timer.Start()
[void]$form.ShowDialog()
$form.Dispose()
$tips.Dispose()
