#Requires -Version 5.1
<#
.SYNOPSIS
    MicMuteBar — mutes all microphones globally and shows a status indicator on every monitor.
    Tray icon: right-click for Settings / Exit
    Config: config.json in the same folder
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── Config ─────────────────────────────────────────────────────────────────────
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$cfgPath   = Join-Path $scriptDir "config.json"
$defaults  = [ordered]@{
    BarColor      = "#FF2020"
    BarHeight     = 18
    BarPosition   = "top"     # top | bottom
    BarWidthPct   = 100       # 10-100
    BarText       = "MIC MUTED"
    BarOpacity    = 90        # 10-100
    HotkeyMods    = 7         # bitmask: 1=Ctrl 2=Shift 4=Alt 8=Win  (default: Ctrl+Shift+Alt)
    HotkeyVK      = 80        # virtual-key code (80 = P)
    IndicatorType    = "bar"     # bar | circle | border | corner
    CircleSize       = 80        # diameter in pixels
    CircleX          = 50        # % from left of primary screen
    CircleY          = 10        # % from top of primary screen
    BorderThickness  = 8         # border line thickness in pixels
    BorderGap        = 0         # inset from screen edge in pixels
    CornerSize       = 40        # corner square size in pixels
    CornerOffset     = 0         # offset from screen corners in pixels
    Pulse            = $false    # pulse (alternate between two colors) while muted
    PulseColor       = "#FF8000" # second color for the pulse effect
}
if (Test-Path $cfgPath) {
    $raw = Get-Content $cfgPath -Raw | ConvertFrom-Json
    foreach ($k in $defaults.Keys) {
        if ($null -eq $raw.$k) { $raw | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force }
    }
    $cfg = $raw
} else {
    $cfg = [PSCustomObject]$defaults
    $cfg | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8
}

# ── Assemblies ─────────────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── C# core ────────────────────────────────────────────────────────────────────
Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing' @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// ──── Win32 ────────────────────────────────────────────────────────────────────
public static class Win32 {
    [DllImport("user32.dll")] public static extern int   SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern int   GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern bool  SetLayeredWindowAttributes(IntPtr hWnd, uint crKey, byte bAlpha, uint dwFlags);
    [DllImport("user32.dll")] public static extern bool  SetWindowPos(IntPtr hWnd, IntPtr hWndAfter, int x, int y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool  SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool  SetForegroundWindow(IntPtr hWnd);
}

// ──── Core Audio COM interfaces ────────────────────────────────────────────────
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"), ClassInterface(ClassInterfaceType.None)]
class MMDeviceEnumeratorCom {}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IMMDeviceCollection ppDevices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice ppDevice);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr pClient);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr pClient);
}

[Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceCollection {
    [PreserveSig] int GetCount(out uint pcDevices);
    [PreserveSig] int Item(uint nDevice, out IMMDevice ppDevice);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    [PreserveSig] int Activate([MarshalAs(UnmanagedType.LPStruct)] Guid iid, int dwClsCtx,
                               IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
    [PreserveSig] int GetState(out int pdwState);
}

[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    void NotImpl01(); void NotImpl02(); void NotImpl03(); void NotImpl04();
    void NotImpl05(); void NotImpl06(); void NotImpl07(); void NotImpl08();
    void NotImpl09(); void NotImpl10(); void NotImpl11();
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
}

// ──── Audio helper ─────────────────────────────────────────────────────────────
public static class AudioHelper {
    static readonly Guid IID_IAudioEndpointVolume = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
    const int eCapture            = 1;
    const int DEVICE_STATE_ACTIVE = 1;
    const int CLSCTX_ALL          = 23;

    static List<IAudioEndpointVolume> GetMicVolumes() {
        var list = new List<IAudioEndpointVolume>();
        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
        IMMDeviceCollection col;
        if (enumerator.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, out col) != 0) return list;
        uint count; col.GetCount(out count);
        for (uint i = 0; i < count; i++) {
            IMMDevice dev; if (col.Item(i, out dev) != 0) continue;
            object iface;
            if (dev.Activate(IID_IAudioEndpointVolume, CLSCTX_ALL, IntPtr.Zero, out iface) != 0) continue;
            var vol = iface as IAudioEndpointVolume;
            if (vol != null) list.Add(vol);
        }
        return list;
    }

    public static void SetAllMuted(bool muted) {
        foreach (var v in GetMicVolumes())
            try { v.SetMute(muted, Guid.Empty); } catch {}
    }

    public static bool IsAnyMuted() {
        var vols = GetMicVolumes();
        if (vols.Count == 0) return false;
        bool m; vols[0].GetMute(out m); return m;
    }
}

// ──── Shared overlay base ──────────────────────────────────────────────────────
public class OverlayBase : Form {
    protected const int  WM_NCHITTEST      = 0x0084;
    protected const int  HTTRANSPARENT     = -1;
    protected const int  WS_EX_TRANSPARENT = 0x00000020;
    protected const int  WS_EX_NOACTIVATE  = 0x08000000;
    protected const int  WS_EX_TOOLWINDOW  = 0x00000080;
    protected const uint SWP_NOACTIVATE    = 0x0010;
    protected static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    protected int _x, _y;

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
            return cp;
        }
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_NCHITTEST) { m.Result = (IntPtr)HTTRANSPARENT; return; }
        base.WndProc(ref m);
    }
}

// ──── Click-through overlay bar ────────────────────────────────────────────────
public class BarForm : OverlayBase {
    string _text;
    int _w, _h;

    public BarForm(int x, int y, int w, int h, string hexColor, byte alpha, string text) {
        _x = x; _y = y; _w = w; _h = h; _text = text;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar   = false;
        TopMost         = true;
        BackColor       = ColorTranslator.FromHtml(hexColor);
        Opacity         = (double)alpha / 255.0;
        StartPosition   = FormStartPosition.Manual;
        AutoScaleMode   = AutoScaleMode.None;
        MinimumSize     = System.Drawing.Size.Empty;
        MaximumSize     = System.Drawing.Size.Empty;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        SetBounds(x, y, w, h);
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        Win32.SetWindowPos(Handle, HWND_TOPMOST, _x, _y, _w, _h, SWP_NOACTIVATE);
    }
    protected override void OnLoad(EventArgs e) {
        base.OnLoad(e);
        Win32.SetWindowPos(Handle, HWND_TOPMOST, _x, _y, _w, _h, SWP_NOACTIVATE);
    }
    protected override void OnVisibleChanged(EventArgs e) {
        base.OnVisibleChanged(e);
        if (Visible) Win32.SetWindowPos(Handle, HWND_TOPMOST, _x, _y, _w, _h, SWP_NOACTIVATE);
    }
    protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.Clear(BackColor); }
    protected override void OnPaint(PaintEventArgs e) {
        if (string.IsNullOrEmpty(_text)) return;
        float fs = Math.Max(7f, _h * 0.62f);
        using (var font = new Font("Segoe UI", fs, GraphicsUnit.Pixel))
            TextRenderer.DrawText(e.Graphics, _text, font, ClientRectangle, Color.White,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }
}

// ──── Click-through overlay circle ────────────────────────────────────────────
public class CircleForm : OverlayBase {
    int _size;

    public CircleForm(int x, int y, int size, string hexColor, byte alpha) {
        _x = x; _y = y; _size = size;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar   = false;
        TopMost         = true;
        BackColor       = ColorTranslator.FromHtml(hexColor);
        Opacity         = (double)alpha / 255.0;
        StartPosition   = FormStartPosition.Manual;
        AutoScaleMode   = AutoScaleMode.None;
        MinimumSize     = System.Drawing.Size.Empty;
        MaximumSize     = System.Drawing.Size.Empty;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        SetBounds(x, y, size, size);
    }

    void ClipToCircle() {
        using (var path = new GraphicsPath()) {
            path.AddEllipse(0, 0, _size, _size);
            Region = new Region(path);
        }
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        ClipToCircle();
        Win32.SetWindowPos(Handle, HWND_TOPMOST, _x, _y, _size, _size, SWP_NOACTIVATE);
    }
    protected override void OnLoad(EventArgs e) {
        base.OnLoad(e);
        Win32.SetWindowPos(Handle, HWND_TOPMOST, _x, _y, _size, _size, SWP_NOACTIVATE);
    }
    protected override void OnVisibleChanged(EventArgs e) {
        base.OnVisibleChanged(e);
        if (Visible) Win32.SetWindowPos(Handle, HWND_TOPMOST, _x, _y, _size, _size, SWP_NOACTIVATE);
    }
    protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.Clear(BackColor); }
    protected override void OnPaint(PaintEventArgs e) { /* region clips window to circle shape */ }
}

// ──── Anchor form: message loop + global hotkey via RegisterHotKey ───────────────
// RegisterHotKey delivers WM_HOTKEY through the normal message queue, so it works
// on the desktop, in apps, and everywhere — unlike WH_KEYBOARD_LL which is bypassed
// by the Windows shell when no application window has focus.
public class AnchorForm : Form {
    [DllImport("user32.dll")] static extern bool   RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool   UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("kernel32.dll")] static extern int    GlobalAddAtom(string lpString);
    [DllImport("kernel32.dll")] static extern ushort GlobalDeleteAtom(ushort nAtom);

    const int  WM_HOTKEY    = 0x0312;
    const uint MOD_ALT      = 0x0001;
    const uint MOD_CONTROL  = 0x0002;
    const uint MOD_SHIFT    = 0x0004;
    const uint MOD_WIN      = 0x0008;
    const uint MOD_NOREPEAT = 0x4000;

    int _atomId;
    public event EventHandler HotkeyFired;

    public AnchorForm() {
        Opacity         = 0;
        ShowInTaskbar   = false;
        FormBorderStyle = FormBorderStyle.None;
        Size            = new System.Drawing.Size(1, 1);
    }

    protected override CreateParams CreateParams {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x00000080; return cp; }  // WS_EX_TOOLWINDOW
    }

    public bool SetHotkey(int modMask, int vk) {
        ClearHotkey();
        string name = "MicMuteBar_" + GetHashCode();
        _atomId = GlobalAddAtom(name);
        if (_atomId == 0) return false;
        uint mods = MOD_NOREPEAT;
        if ((modMask & 1) != 0) mods |= MOD_CONTROL;
        if ((modMask & 2) != 0) mods |= MOD_SHIFT;
        if ((modMask & 4) != 0) mods |= MOD_ALT;
        if ((modMask & 8) != 0) mods |= MOD_WIN;
        if (!RegisterHotKey(Handle, _atomId, mods, (uint)vk)) {
            GlobalDeleteAtom((ushort)_atomId); _atomId = 0; return false;
        }
        return true;
    }

    public void ClearHotkey() {
        if (_atomId != 0 && IsHandleCreated) {
            UnregisterHotKey(Handle, _atomId);
            GlobalDeleteAtom((ushort)_atomId);
            _atomId = 0;
        }
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && _atomId != 0 && m.WParam.ToInt32() == _atomId) {
            if (HotkeyFired != null) HotkeyFired(this, EventArgs.Empty);
            return;
        }
        base.WndProc(ref m);
    }

    protected override void OnFormClosed(FormClosedEventArgs e) {
        ClearHotkey(); base.OnFormClosed(e);
    }
}
'@

# ── Tray icon (drawn programmatically, no .ico file needed) ───────────────────
function New-TrayIcon([bool]$muted) {
    $bmp   = New-Object System.Drawing.Bitmap 16,16
    $g     = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $col   = if ($muted) { [System.Drawing.Color]::FromArgb(220,30,30) } else { [System.Drawing.Color]::FromArgb(30,180,30) }
    $brush = New-Object System.Drawing.SolidBrush $col
    # Microphone silhouette
    $g.FillEllipse($brush, 5, 1, 6, 8)
    $g.FillRectangle($brush, 7, 9, 2, 4)
    $g.FillRectangle($brush, 4, 13, 8, 2)
    if ($muted) {
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
        $g.DrawLine($pen, 1, 1, 15, 15)
        $pen.Dispose()
    }
    $brush.Dispose(); $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

# ── Autostart ─────────────────────────────────────────────────────────────────
$startupFolder = [System.Environment]::GetFolderPath('Startup')
$shortcutPath  = Join-Path $startupFolder "MicMuteBar.lnk"

function Get-AutostartEnabled { Test-Path $shortcutPath }

function Set-Autostart([bool]$enable) {
    if ($enable) {
        $wsh = New-Object -ComObject WScript.Shell
        $sc  = $wsh.CreateShortcut($shortcutPath)
        $sc.TargetPath       = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $sc.WorkingDirectory = $scriptDir
        $sc.Save()
    } else {
        Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
    }
}

# ── Hotkey display helper ──────────────────────────────────────────────────────
function Get-HotkeyText([int]$mods, [int]$vk) {
    $parts = @()
    if ($mods -band 8) { $parts += "Win" }
    if ($mods -band 1) { $parts += "Ctrl" }
    if ($mods -band 2) { $parts += "Shift" }
    if ($mods -band 4) { $parts += "Alt" }
    try   { $parts += ([System.Windows.Forms.Keys]$vk).ToString() }
    catch { $parts += "VK$vk" }
    return ($parts -join "+")
}

# ── Create overlay bars (one per monitor) ─────────────────────────────────────
function New-Bars {
    $result = @()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $pct   = [Math]::Max(10, [Math]::Min(100, [int]$cfg.BarWidthPct))
        $alpha = [byte]([Math]::Max(10, [Math]::Min(100, [int]$cfg.BarOpacity)) * 255 / 100)
        $pos   = $cfg.BarPosition
        if ($pos -eq "left" -or $pos -eq "right") {
            # Vertical bar: BarHeight = thickness, BarWidthPct applies to screen height
            $bw  = [Math]::Max(2, [int]$cfg.BarHeight)
            $bh  = [int]($screen.Bounds.Height * $pct / 100)
            $bx  = if ($pos -eq "right") { $screen.Bounds.Right - $bw } else { $screen.Bounds.Left }
            $by  = $screen.Bounds.Top + [int](($screen.Bounds.Height - $bh) / 2)
            $result += New-Object BarForm $bx, $by, $bw, $bh, $cfg.BarColor, $alpha, ""
        } else {
            # Horizontal bar: BarHeight = thickness, BarWidthPct applies to screen width
            $bw  = [int]($screen.Bounds.Width * $pct / 100)
            $bh  = [Math]::Max(2, [int]$cfg.BarHeight)
            $bx  = $screen.Bounds.Left + [int](($screen.Bounds.Width - $bw) / 2)
            $by  = if ($pos -eq "bottom") { $screen.Bounds.Bottom - $bh } else { $screen.Bounds.Top }
            $result += New-Object BarForm $bx, $by, $bw, $bh, $cfg.BarColor, $alpha, $cfg.BarText
        }
    }
    return $result
}

# ── Create circle indicator (primary screen) ───────────────────────────────────
function New-Circle {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $size   = [Math]::Max(20, [int]$cfg.CircleSize)
    $cx     = [int]($screen.Bounds.Left + $screen.Bounds.Width  * [int]$cfg.CircleX / 100 - $size / 2)
    $cy     = [int]($screen.Bounds.Top  + $screen.Bounds.Height * [int]$cfg.CircleY / 100 - $size / 2)
    $alpha  = [byte]([Math]::Max(10, [Math]::Min(100, [int]$cfg.BarOpacity)) * 255 / 100)
    return New-Object CircleForm $cx, $cy, $size, $cfg.BarColor, $alpha
}

# ── Create border indicator (4 bars forming a complete frame per monitor) ───────
function New-BorderForms {
    $result = @()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $t     = [Math]::Max(1, [int]$cfg.BorderThickness)
        $g     = [Math]::Max(0, [int]$cfg.BorderGap)
        $alpha = [byte]([Math]::Max(10, [Math]::Min(100, [int]$cfg.BarOpacity)) * 255 / 100)
        $rx    = $screen.Bounds.Left + $g
        $ry    = $screen.Bounds.Top  + $g
        $rw    = $screen.Bounds.Width  - 2 * $g
        $rh    = $screen.Bounds.Height - 2 * $g
        # Top and bottom cover full width (including corners)
        $result += New-Object BarForm $rx,             $ry,              $rw, $t,          $cfg.BarColor, $alpha, ""
        $result += New-Object BarForm $rx,             ($ry+$rh-$t),     $rw, $t,          $cfg.BarColor, $alpha, ""
        # Left and right fill the middle height (corners already covered above)
        $result += New-Object BarForm $rx,             ($ry+$t),         $t,  ($rh-2*$t),  $cfg.BarColor, $alpha, ""
        $result += New-Object BarForm ($rx+$rw-$t),    ($ry+$t),         $t,  ($rh-2*$t),  $cfg.BarColor, $alpha, ""
    }
    return $result
}

# ── Create corner indicator (4 squares per monitor, one in each corner) ─────────
function New-CornerForms {
    $result = @()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $s     = [Math]::Max(4, [int]$cfg.CornerSize)
        $o     = [Math]::Max(0, [int]$cfg.CornerOffset)
        $alpha = [byte]([Math]::Max(10, [Math]::Min(100, [int]$cfg.BarOpacity)) * 255 / 100)
        $l     = $screen.Bounds.Left;  $r = $screen.Bounds.Right
        $top   = $screen.Bounds.Top;   $b = $screen.Bounds.Bottom
        $result += New-Object BarForm ($l+$o),     ($top+$o),  $s, $s, $cfg.BarColor, $alpha, ""  # top-left
        $result += New-Object BarForm ($r-$s-$o),  ($top+$o),  $s, $s, $cfg.BarColor, $alpha, ""  # top-right
        $result += New-Object BarForm ($l+$o),     ($b-$s-$o), $s, $s, $cfg.BarColor, $alpha, ""  # bottom-left
        $result += New-Object BarForm ($r-$s-$o),  ($b-$s-$o), $s, $s, $cfg.BarColor, $alpha, ""  # bottom-right
    }
    return $result
}

# ── Indicator lifecycle ────────────────────────────────────────────────────────
function New-Indicator {
    switch ($cfg.IndicatorType) {
        "circle" { $script:circle = New-Circle;       $script:bars = @() }
        "border" { $script:bars   = New-BorderForms;  $script:circle = $null }
        "corner" { $script:bars   = New-CornerForms;  $script:circle = $null }
        default  { $script:bars   = New-Bars;         $script:circle = $null }
    }
}

function Remove-Indicator {
    foreach ($b in $script:bars) { $b.Dispose() }
    $script:bars = @()
    if ($script:circle) { $script:circle.Dispose(); $script:circle = $null }
}

function Set-IndicatorVisible([bool]$show) {
    if ($cfg.IndicatorType -eq "circle" -and $script:circle) {
        if ($show) { $script:circle.Show() } else { $script:circle.Hide() }
    } else {
        foreach ($b in $script:bars) {
            if ($show) { $b.Show() } else { $b.Hide() }
        }
    }
}

function Set-IndicatorColor([string]$hex) {
    try {
        $color = [System.Drawing.ColorTranslator]::FromHtml($hex)
        foreach ($b in $script:bars)  { $b.BackColor = $color; $b.Refresh() }
        if ($script:circle)           { $script:circle.BackColor = $color; $script:circle.Refresh() }
    } catch {}
}

# ── Hotkey capture dialog ──────────────────────────────────────────────────────
function Show-HotkeyCapture {
    $cap = New-Object System.Windows.Forms.Form
    $cap.Text = "Set Hotkey"; $cap.Size = New-Object System.Drawing.Size 280,130
    $cap.FormBorderStyle = 'FixedDialog'; $cap.StartPosition = 'CenterScreen'
    $cap.TopMost = $true; $cap.MaximizeBox = $false; $cap.MinimizeBox = $false
    $cap.KeyPreview = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Press your key combination..."; $lbl.TextAlign = 'MiddleCenter'
    $lbl.Location = New-Object System.Drawing.Point 20,20; $lbl.Size = New-Object System.Drawing.Size 240,20
    $cap.Controls.Add($lbl)

    $prev = New-Object System.Windows.Forms.Label
    $prev.Text = ""; $prev.TextAlign = 'MiddleCenter'
    $prev.Location = New-Object System.Drawing.Point 20,48; $prev.Size = New-Object System.Drawing.Size 240,24
    $prev.Font = New-Object System.Drawing.Font "Segoe UI", 11, ([System.Drawing.FontStyle]::Bold)
    $cap.Controls.Add($prev)

    $script:_capturedHotkey = $null
    $cap.add_KeyDown({
        param($s, $e)
        $vk = [int]$e.KeyCode
        if ($vk -in @(0x10,0x11,0x12,0xA0,0xA1,0xA2,0xA3,0xA4,0xA5,0x5B,0x5C,0x5D)) { return }
        $mods = 0
        if ($e.Control) { $mods = $mods -bor 1 }
        if ($e.Shift)   { $mods = $mods -bor 2 }
        if ($e.Alt)     { $mods = $mods -bor 4 }
        if (([Win32]::GetAsyncKeyState(0x5B) -band 0x8000) -ne 0 -or
            ([Win32]::GetAsyncKeyState(0x5C) -band 0x8000) -ne 0) { $mods = $mods -bor 8 }
        $script:_capturedHotkey = @{ Mods = $mods; VK = $vk }
        $prev.Text = Get-HotkeyText $mods $vk
        $e.SuppressKeyPress = $true; $e.Handled = $true
        $s.DialogResult = 'OK'
        $s.Close()
    })
    $cap.ShowDialog() | Out-Null
    return $script:_capturedHotkey
}

# ── Settings dialog ────────────────────────────────────────────────────────────
function Show-Settings {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "MicMuteBar — Settings"
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.StartPosition = 'CenterScreen'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.TopMost = $true; $dlg.KeyPreview = $true

    # Helpers — $dlg accessed via PowerShell dynamic scope
    function Add-Sep([string]$text, [int]$y) {
        $s = New-Object System.Windows.Forms.Label; $s.Text = $text
        $s.Location = New-Object System.Drawing.Point 12,$y; $s.Size = New-Object System.Drawing.Size 340,18
        $s.ForeColor = [System.Drawing.Color]::Gray; $s.Font = New-Object System.Drawing.Font "Segoe UI",8
        $dlg.Controls.Add($s); return $s
    }
    function Add-Row([string]$lbl, $ctl, [int]$y) {
        $l = New-Object System.Windows.Forms.Label; $l.Text = $lbl
        $l.Location = New-Object System.Drawing.Point 12,($y+3); $l.Size = New-Object System.Drawing.Size 140,20
        $dlg.Controls.Add($l)
        $ctl.Location = New-Object System.Drawing.Point 158,$y; $ctl.Size = New-Object System.Drawing.Size 190,22
        $dlg.Controls.Add($ctl)
    }
    function Make-Nud([int]$mn,[int]$mx,[int]$v) {
        $n = New-Object System.Windows.Forms.NumericUpDown
        $n.Minimum=$mn; $n.Maximum=$mx; $n.Value=[Math]::Max($mn,[Math]::Min($mx,$v)); return $n
    }
    # Add a label+control row inside a panel (relative coords)
    function Panel-Row($pnl,[string]$lbl,$ctl,[int]$ry) {
        $l = New-Object System.Windows.Forms.Label; $l.Text = $lbl
        $l.Location = New-Object System.Drawing.Point 12,($ry+3); $l.Size = New-Object System.Drawing.Size 140,20
        $pnl.Controls.Add($l)
        $ctl.Location = New-Object System.Drawing.Point 158,$ry; $ctl.Size = New-Object System.Drawing.Size 190,22
        $pnl.Controls.Add($ctl)
    }

    $y = 12

    # ── General ──────────────────────────────────────────────────────────────────
    $txtText = New-Object System.Windows.Forms.TextBox; $txtText.Text = $cfg.BarText
    Add-Row "Text:" $txtText $y; $y += 32

    # Color row — hex input + live swatch + color picker
    $txtColor = New-Object System.Windows.Forms.TextBox; $txtColor.Text = $cfg.BarColor
    $lc = New-Object System.Windows.Forms.Label; $lc.Text = "Color (Hex):"
    $lc.Location = New-Object System.Drawing.Point 12,($y+3); $lc.Size = New-Object System.Drawing.Size 140,20; $dlg.Controls.Add($lc)
    $txtColor.Location = New-Object System.Drawing.Point 158,$y; $txtColor.Size = New-Object System.Drawing.Size 110,22; $dlg.Controls.Add($txtColor)
    $pnlColor = New-Object System.Windows.Forms.Panel
    $pnlColor.Location = New-Object System.Drawing.Point 272,$y; $pnlColor.Size = New-Object System.Drawing.Size 22,22
    $pnlColor.BorderStyle = 'FixedSingle'
    try { $pnlColor.BackColor = [System.Drawing.ColorTranslator]::FromHtml($cfg.BarColor) } catch {}
    $dlg.Controls.Add($pnlColor)
    $btnPick = New-Object System.Windows.Forms.Button
    $btnPick.Text = "Pick"; $btnPick.Location = New-Object System.Drawing.Point 298,$y
    $btnPick.Size = New-Object System.Drawing.Size 50,22; $dlg.Controls.Add($btnPick)
    $txtColor.add_TextChanged({ try { $pnlColor.BackColor = [System.Drawing.ColorTranslator]::FromHtml($txtColor.Text) } catch {} })
    $btnPick.add_Click({
        $cd = New-Object System.Windows.Forms.ColorDialog; $cd.FullOpen = $true
        try { $cd.Color = [System.Drawing.ColorTranslator]::FromHtml($txtColor.Text) } catch {}
        if ($cd.ShowDialog() -eq 'OK') { $txtColor.Text = "#{0:X2}{1:X2}{2:X2}" -f $cd.Color.R, $cd.Color.G, $cd.Color.B }
    })
    $y += 32

    $nudOpacity = Make-Nud 10 100 ([int]$cfg.BarOpacity)
    Add-Row "Opacity (%):" $nudOpacity $y; $y += 32

    $cboType = New-Object System.Windows.Forms.ComboBox; $cboType.DropDownStyle = 'DropDownList'
    @("bar","circle","border","corner") | ForEach-Object { $cboType.Items.Add($_) | Out-Null }
    $cboType.SelectedItem = switch ($cfg.IndicatorType) { "circle"{"circle"} "border"{"border"} "corner"{"corner"} default{"bar"} }
    Add-Row "Indicator:" $cboType $y; $y += 32

    # ── Indicator-specific options (dynamic) ──────────────────────────────────────
    $sepOpt = Add-Sep "" $y; $y += 22
    $optY   = $y  # all option panels sit at the same position

    function New-OptPanel {
        $p = New-Object System.Windows.Forms.Panel
        $p.Location = New-Object System.Drawing.Point 0,$optY
        $p.Size     = New-Object System.Drawing.Size 380,96
        $p.Visible  = $false
        $dlg.Controls.Add($p); return $p
    }

    # Bar options (3 rows)
    $pBar    = New-OptPanel
    $nudBarH = Make-Nud 2 120 ([int]$cfg.BarHeight)
    $nudBarW = Make-Nud 10 100 ([int]$cfg.BarWidthPct)
    $cboPos  = New-Object System.Windows.Forms.ComboBox; $cboPos.DropDownStyle = 'DropDownList'
    @("top","bottom","left","right") | ForEach-Object { $cboPos.Items.Add($_) | Out-Null }
    $cboPos.SelectedItem = switch ($cfg.BarPosition) { "bottom"{"bottom"} "left"{"left"} "right"{"right"} default{"top"} }
    Panel-Row $pBar "Thickness (px):" $nudBarH 0
    Panel-Row $pBar "Length (%):"     $nudBarW 32
    Panel-Row $pBar "Position:"       $cboPos  64

    # Circle options (3 rows)
    $pCircle  = New-OptPanel
    $nudCircS = Make-Nud 20 400 ([int]$cfg.CircleSize)
    $nudCircX = Make-Nud 0 100 ([int]$cfg.CircleX)
    $nudCircY = Make-Nud 0 100 ([int]$cfg.CircleY)
    Panel-Row $pCircle "Size (px):"      $nudCircS 0
    Panel-Row $pCircle "Position X (%):" $nudCircX 32
    Panel-Row $pCircle "Position Y (%):" $nudCircY 64

    # Border options (2 rows)
    $pBorder  = New-OptPanel
    $nudBordT = Make-Nud 1 60 ([int]$cfg.BorderThickness)
    $nudBordG = Make-Nud 0 200 ([int]$cfg.BorderGap)
    Panel-Row $pBorder "Thickness (px):"    $nudBordT 0
    Panel-Row $pBorder "Gap from edge (px):" $nudBordG 32

    # Corner options (2 rows)
    $pCorner  = New-OptPanel
    $nudCornS = Make-Nud 4 300 ([int]$cfg.CornerSize)
    $nudCornO = Make-Nud 0 200 ([int]$cfg.CornerOffset)
    Panel-Row $pCorner "Size (px):"        $nudCornS 0
    Panel-Row $pCorner "Edge offset (px):" $nudCornO 32

    $y = $optY + 96  # fixed height for options area (fits 3 rows)

    # ── Hotkey ───────────────────────────────────────────────────────────────────
    Add-Sep "── Hotkey ───────────────────────────────────────" $y | Out-Null; $y += 22
    $lhk = New-Object System.Windows.Forms.Label; $lhk.Text = "Shortcut:"
    $lhk.Location = New-Object System.Drawing.Point 12,($y+3); $lhk.Size = New-Object System.Drawing.Size 140,20; $dlg.Controls.Add($lhk)
    $txtHotkey = New-Object System.Windows.Forms.TextBox
    $txtHotkey.Text = Get-HotkeyText ([int]$cfg.HotkeyMods) ([int]$cfg.HotkeyVK); $txtHotkey.ReadOnly = $true
    $txtHotkey.Location = New-Object System.Drawing.Point 158,$y; $txtHotkey.Size = New-Object System.Drawing.Size 120,22; $dlg.Controls.Add($txtHotkey)
    $btnChange = New-Object System.Windows.Forms.Button
    $btnChange.Text = "Change"; $btnChange.Location = New-Object System.Drawing.Point 284,$y
    $btnChange.Size = New-Object System.Drawing.Size 64,22; $dlg.Controls.Add($btnChange)
    $script:_pendingMods = [int]$cfg.HotkeyMods; $script:_pendingVK = [int]$cfg.HotkeyVK
    $btnChange.add_Click({
        $cap = Show-HotkeyCapture
        if ($cap) {
            $script:_pendingMods = $cap.Mods; $script:_pendingVK = $cap.VK
            $txtHotkey.Text = Get-HotkeyText $cap.Mods $cap.VK
        }
    })
    $y += 36

    # ── Startup ───────────────────────────────────────────────────────────────────
    $chkAutostart = New-Object System.Windows.Forms.CheckBox
    $chkAutostart.Text = "Start with Windows"
    $chkAutostart.Checked = Get-AutostartEnabled
    $chkAutostart.AutoSize = $false
    $chkAutostart.Location = New-Object System.Drawing.Point 158,$y
    $chkAutostart.Size = New-Object System.Drawing.Size 200,22
    $dlg.Controls.Add($chkAutostart)
    $lAutost = New-Object System.Windows.Forms.Label; $lAutost.Text = "Startup:"
    $lAutost.Location = New-Object System.Drawing.Point 12,($y+3); $lAutost.Size = New-Object System.Drawing.Size 140,20; $dlg.Controls.Add($lAutost)
    $y += 32

    $chkBlink = New-Object System.Windows.Forms.CheckBox
    $chkBlink.Text = "Pulse when muted"
    $chkBlink.Checked = [bool]$cfg.Pulse
    $chkBlink.AutoSize = $false
    $chkBlink.Location = New-Object System.Drawing.Point 158,$y
    $chkBlink.Size = New-Object System.Drawing.Size 200,22
    $dlg.Controls.Add($chkBlink)
    $lBlink = New-Object System.Windows.Forms.Label; $lBlink.Text = "Effect:"
    $lBlink.Location = New-Object System.Drawing.Point 12,($y+3); $lBlink.Size = New-Object System.Drawing.Size 140,20; $dlg.Controls.Add($lBlink)
    $y += 32

    # Pulse second color — same picker pattern as main color
    $txtPulseColor = New-Object System.Windows.Forms.TextBox; $txtPulseColor.Text = $cfg.PulseColor
    $lpClr = New-Object System.Windows.Forms.Label; $lpClr.Text = "Pulse color:"
    $lpClr.Location = New-Object System.Drawing.Point 12,($y+3); $lpClr.Size = New-Object System.Drawing.Size 140,20; $dlg.Controls.Add($lpClr)
    $txtPulseColor.Location = New-Object System.Drawing.Point 158,$y; $txtPulseColor.Size = New-Object System.Drawing.Size 110,22; $dlg.Controls.Add($txtPulseColor)
    $pnlPulse = New-Object System.Windows.Forms.Panel
    $pnlPulse.Location = New-Object System.Drawing.Point 272,$y; $pnlPulse.Size = New-Object System.Drawing.Size 22,22
    $pnlPulse.BorderStyle = 'FixedSingle'
    try { $pnlPulse.BackColor = [System.Drawing.ColorTranslator]::FromHtml($cfg.PulseColor) } catch {}
    $dlg.Controls.Add($pnlPulse)
    $btnPulsePick = New-Object System.Windows.Forms.Button
    $btnPulsePick.Text = "Pick"; $btnPulsePick.Location = New-Object System.Drawing.Point 298,$y
    $btnPulsePick.Size = New-Object System.Drawing.Size 50,22; $dlg.Controls.Add($btnPulsePick)
    $txtPulseColor.add_TextChanged({ try { $pnlPulse.BackColor = [System.Drawing.ColorTranslator]::FromHtml($txtPulseColor.Text) } catch {} })
    $btnPulsePick.add_Click({
        $cd = New-Object System.Windows.Forms.ColorDialog; $cd.FullOpen = $true
        try { $cd.Color = [System.Drawing.ColorTranslator]::FromHtml($txtPulseColor.Text) } catch {}
        if ($cd.ShowDialog() -eq 'OK') { $txtPulseColor.Text = "#{0:X2}{1:X2}{2:X2}" -f $cd.Color.R, $cd.Color.G, $cd.Color.B }
    })
    $y += 32

    # ── Apply ─────────────────────────────────────────────────────────────────────
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "Apply"; $btnOK.Location = New-Object System.Drawing.Point 120,($y+6)
    $btnOK.Size = New-Object System.Drawing.Size 130,28; $btnOK.DialogResult = 'OK'
    $dlg.Controls.Add($btnOK); $dlg.AcceptButton = $btnOK
    # ClientSize sets the inner area — avoids title-bar being counted, preventing cut-off
    $dlg.ClientSize = New-Object System.Drawing.Size 380,($y+50)

    # ── Show/hide indicator panels on type change ─────────────────────────────────
    # Uses individual panel variables — avoids hashtable/array closure issues in ps2exe
    $refreshSections = {
        $sel = $cboType.SelectedItem
        $pBar.Visible    = ($sel -eq "bar")
        $pCircle.Visible = ($sel -eq "circle")
        $pBorder.Visible = ($sel -eq "border")
        $pCorner.Visible = ($sel -eq "corner")
        if ($sel -eq "bar")    { $sepOpt.Text = "── Bar ──────────────────────────────────────────" }
        if ($sel -eq "circle") { $sepOpt.Text = "── Circle ───────────────────────────────────────" }
        if ($sel -eq "border") { $sepOpt.Text = "── Border ───────────────────────────────────────" }
        if ($sel -eq "corner") { $sepOpt.Text = "── Corner ───────────────────────────────────────" }
    }
    & $refreshSections
    $cboType.add_SelectedIndexChanged($refreshSections)

    # ── ShowDialog ────────────────────────────────────────────────────────────────
    if ($dlg.ShowDialog() -eq 'OK') {
        $cfg.BarText         = $txtText.Text
        $cfg.BarColor        = $txtColor.Text
        $cfg.BarOpacity      = [int]$nudOpacity.Value
        $cfg.IndicatorType   = $cboType.SelectedItem
        $cfg.BarHeight       = [int]$nudBarH.Value
        $cfg.BarWidthPct     = [int]$nudBarW.Value
        $cfg.BarPosition     = $cboPos.SelectedItem
        $cfg.CircleSize      = [int]$nudCircS.Value
        $cfg.CircleX         = [int]$nudCircX.Value
        $cfg.CircleY         = [int]$nudCircY.Value
        $cfg.BorderThickness = [int]$nudBordT.Value
        $cfg.BorderGap       = [int]$nudBordG.Value
        $cfg.CornerSize      = [int]$nudCornS.Value
        $cfg.CornerOffset    = [int]$nudCornO.Value
        $cfg.HotkeyMods      = $script:_pendingMods
        $cfg.HotkeyVK        = $script:_pendingVK
        $cfg.Pulse           = [bool]$chkBlink.Checked
        $cfg.PulseColor      = $txtPulseColor.Text
        $cfg | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8
        Set-Autostart $chkAutostart.Checked
        return $true
    }
    return $false
}

# ── Main ──────────────────────────────────────────────────────────────────────
[System.Windows.Forms.Application]::EnableVisualStyles()
[Win32]::SetProcessDPIAware() | Out-Null

$muted  = [AudioHelper]::IsAnyMuted()
$bars   = @()
$circle = $null
New-Indicator

# Tray icon
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon    = New-TrayIcon $muted
$tray.Text    = if ($muted) { "MicMuteBar - MUTED" } else { "MicMuteBar" }
$tray.Visible = $true

$menu        = New-Object System.Windows.Forms.ContextMenuStrip
$miSet       = $menu.Items.Add("Settings")
$miAutostart = $menu.Items.Add("Start with Windows")
$menu.Items.Add("-") | Out-Null
$miExit      = $menu.Items.Add("Exit")
# Show menu manually via MouseUp: SetForegroundWindow brings it to the front and
# ContextMenuStrip.Show(Point) auto-positions above the taskbar — no clipping.
$tray.add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        [Win32]::SetForegroundWindow($script:anchor.Handle) | Out-Null
        $menu.Show([System.Windows.Forms.Cursor]::Position)
    }
})
$miAutostart.Checked = Get-AutostartEnabled

# Blink timer — toggles indicator visibility every 600 ms when Blink is enabled
$script:blinkVisible = $true
$script:blinkTimer   = New-Object System.Windows.Forms.Timer
$script:blinkTimer.Interval = 600
$script:blinkTimer.add_Tick({
    $script:blinkVisible = -not $script:blinkVisible
    if ($script:blinkVisible) { Set-IndicatorColor $cfg.BarColor } else { Set-IndicatorColor $cfg.PulseColor }
})

function Update-BlinkState {
    if ($script:muted -and $cfg.Pulse) {
        $script:blinkVisible = $true
        Set-IndicatorColor $cfg.BarColor   # always start from primary color
        Set-IndicatorVisible $true
        $script:blinkTimer.Start()
    } else {
        $script:blinkTimer.Stop()
        Set-IndicatorColor $cfg.BarColor   # reset to primary color when stopping
        Set-IndicatorVisible $script:muted
    }
}

Update-BlinkState

# Toggle mute
$script:toggle = {
    $script:muted = -not $script:muted
    [AudioHelper]::SetAllMuted($script:muted)
    Update-BlinkState
    $tray.Icon = New-TrayIcon $script:muted
    $tray.Text = if ($script:muted) { "MicMuteBar - MUTED" } else { "MicMuteBar" }
}

# Tray menu events
$miSet.add_Click({
    # Unregister hotkey while settings dialog is open so the capture dialog can catch it
    $script:anchor.ClearHotkey()
    if (Show-Settings) {
        Remove-Indicator
        [System.Windows.Forms.Application]::DoEvents()
        New-Indicator
        Update-BlinkState
    }
    # Sync tray menu checkmark with whatever autostart state is now saved
    $miAutostart.Checked = Get-AutostartEnabled
    # Re-register with whatever is now in config (new or unchanged)
    $script:anchor.SetHotkey([int]$cfg.HotkeyMods, [int]$cfg.HotkeyVK) | Out-Null
})
$miAutostart.add_Click({
    $newState = -not (Get-AutostartEnabled)
    Set-Autostart $newState
    $miAutostart.Checked = $newState
})
$miExit.add_Click({
    $script:blinkTimer.Stop()
    [AudioHelper]::SetAllMuted($false)
    $tray.Visible = $false
    $script:anchor.Close()  # OnFormClosed calls ClearHotkey automatically
})

# Double-click tray icon = toggle
$tray.add_DoubleClick($script:toggle)

# Anchor form: message loop + global hotkey (RegisterHotKey works on desktop too)
$anchor = New-Object AnchorForm
$anchor.add_HotkeyFired($script:toggle)
# Force HWND creation before Application.Run so RegisterHotKey gets a valid handle
# without relying on a Load-event closure (closures can't resolve $cfg in ps2exe).
$null = $anchor.Handle
$anchor.SetHotkey([int]$cfg.HotkeyMods, [int]$cfg.HotkeyVK) | Out-Null
[System.Windows.Forms.Application]::Run($anchor)
