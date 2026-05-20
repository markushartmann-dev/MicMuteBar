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
    HotkeyMods    = 8         # bitmask: 1=Ctrl 2=Shift 4=Alt 8=Win
    HotkeyVK      = 77        # virtual-key code (77 = M)
    IndicatorType = "bar"     # bar | circle
    CircleSize    = 80        # diameter in pixels
    CircleX       = 50        # % from left of primary screen
    CircleY       = 10        # % from top of primary screen
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

// ──── Low-level keyboard hook (always active, overrides any other app) ─────────
public class KeyboardHook : IDisposable {
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] static extern bool   UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }

    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN     = 0x0100;
    const int WM_SYSKEYDOWN  = 0x0104;

    int  _modMask, _triggerVK;
    bool _ctrlDown, _shiftDown, _altDown, _winDown;
    IntPtr _hookId;
    LowLevelKeyboardProc _cb;  // keep reference to prevent GC collection
    public bool Suspended { get; set; }
    public event EventHandler Fired;

    public KeyboardHook(int modMask, int triggerVK) {
        _modMask = modMask; _triggerVK = triggerVK;
        _cb = Callback;
        _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _cb, IntPtr.Zero, 0);
    }

    IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (!Suspended && nCode >= 0) {
            var info = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            bool down = wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN;
            int  vk   = (int)info.vkCode;

            if (vk == 0xA2 || vk == 0xA3) _ctrlDown  = down;
            if (vk == 0xA0 || vk == 0xA1) _shiftDown = down;
            if (vk == 0xA4 || vk == 0xA5) _altDown   = down;
            if (vk == 0x5B || vk == 0x5C) _winDown   = down;

            if (vk == _triggerVK && down) {
                int cur = 0;
                if (_ctrlDown)  cur |= 1;
                if (_shiftDown) cur |= 2;
                if (_altDown)   cur |= 4;
                if (_winDown)   cur |= 8;
                if (cur == _modMask) {
                    if (Fired != null) Fired(this, EventArgs.Empty);
                    return (IntPtr)1;  // suppress the keystroke
                }
            }
        }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    public void Dispose() {
        if (_hookId != IntPtr.Zero) { UnhookWindowsHookEx(_hookId); _hookId = IntPtr.Zero; }
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
        $bw    = [int]($screen.Bounds.Width * $pct / 100)
        $bh    = [Math]::Max(2, [int]$cfg.BarHeight)
        $bx    = $screen.Bounds.Left + ($screen.Bounds.Width - $bw) / 2
        $by    = if ($cfg.BarPosition -eq "bottom") { $screen.Bounds.Bottom - $bh } else { $screen.Bounds.Top }
        $alpha = [byte]([Math]::Max(10, [Math]::Min(100, [int]$cfg.BarOpacity)) * 255 / 100)
        $result += New-Object BarForm $bx, $by, $bw, $bh, $cfg.BarColor, $alpha, $cfg.BarText
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

# ── Indicator lifecycle ────────────────────────────────────────────────────────
function New-Indicator {
    if ($cfg.IndicatorType -eq "circle") {
        $script:circle = New-Circle
        $script:bars   = @()
    } else {
        $script:bars   = New-Bars
        $script:circle = $null
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
    $dlg.Text = "MicMuteBar - Settings"; $dlg.Size = New-Object System.Drawing.Size 380,530
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.StartPosition = 'CenterScreen'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.TopMost = $true; $dlg.KeyPreview = $true

    function Add-Sep([string]$text, [int]$y) {
        $s = New-Object System.Windows.Forms.Label; $s.Text = $text
        $s.Location = New-Object System.Drawing.Point 12,$y; $s.Size = New-Object System.Drawing.Size 340,18
        $s.ForeColor = [System.Drawing.Color]::Gray; $s.Font = New-Object System.Drawing.Font "Segoe UI",8
        $dlg.Controls.Add($s)
    }
    function Add-Row([string]$lbl, $ctl, [int]$y) {
        $l = New-Object System.Windows.Forms.Label; $l.Text = $lbl
        $l.Location = New-Object System.Drawing.Point 12,($y+3); $l.Size = New-Object System.Drawing.Size 140,20
        $dlg.Controls.Add($l)
        $ctl.Location = New-Object System.Drawing.Point 158,$y; $ctl.Size = New-Object System.Drawing.Size 190,22
        $dlg.Controls.Add($ctl)
    }

    $y = 12

    # General
    $txtText    = New-Object System.Windows.Forms.TextBox;       $txtText.Text = $cfg.BarText
    $txtColor   = New-Object System.Windows.Forms.TextBox;       $txtColor.Text = $cfg.BarColor
    $nudOpacity = New-Object System.Windows.Forms.NumericUpDown; $nudOpacity.Minimum=10; $nudOpacity.Maximum=100
    $nudOpacity.Value = [Math]::Max(10,[Math]::Min(100,[int]$cfg.BarOpacity))
    $cboType    = New-Object System.Windows.Forms.ComboBox;      $cboType.DropDownStyle='DropDownList'
    @("bar","circle") | ForEach-Object { $cboType.Items.Add($_) | Out-Null }
    $cboType.SelectedItem = if ($cfg.IndicatorType -eq "circle") { "circle" } else { "bar" }

    Add-Row "Text:"          $txtText    $y; $y += 32
    Add-Row "Color (Hex):"   $txtColor   $y; $y += 32
    Add-Row "Opacity (%):"   $nudOpacity $y; $y += 32
    Add-Row "Indicator:"     $cboType    $y; $y += 32

    # Bar
    Add-Sep "── Bar ──────────────────────────────────────────" $y; $y += 22
    $nudHeight = New-Object System.Windows.Forms.NumericUpDown; $nudHeight.Minimum=2;  $nudHeight.Maximum=120
    $nudHeight.Value = [Math]::Max(2,[Math]::Min(120,[int]$cfg.BarHeight))
    $nudWidth  = New-Object System.Windows.Forms.NumericUpDown; $nudWidth.Minimum=10;  $nudWidth.Maximum=100
    $nudWidth.Value  = [Math]::Max(10,[Math]::Min(100,[int]$cfg.BarWidthPct))
    $cboPos    = New-Object System.Windows.Forms.ComboBox;      $cboPos.DropDownStyle='DropDownList'
    @("top","bottom") | ForEach-Object { $cboPos.Items.Add($_) | Out-Null }
    $cboPos.SelectedItem = if ($cfg.BarPosition -eq "bottom") { "bottom" } else { "top" }

    Add-Row "Bar Height (px):" $nudHeight $y; $y += 32
    Add-Row "Bar Width (%):"   $nudWidth  $y; $y += 32
    Add-Row "Bar Position:"    $cboPos    $y; $y += 32

    # Circle
    Add-Sep "── Circle ───────────────────────────────────────" $y; $y += 22
    $nudSize = New-Object System.Windows.Forms.NumericUpDown; $nudSize.Minimum=20; $nudSize.Maximum=400
    $nudSize.Value = [Math]::Max(20,[Math]::Min(400,[int]$cfg.CircleSize))
    $nudCX = New-Object System.Windows.Forms.NumericUpDown; $nudCX.Minimum=0; $nudCX.Maximum=100
    $nudCX.Value = [Math]::Max(0,[Math]::Min(100,[int]$cfg.CircleX))
    $nudCY = New-Object System.Windows.Forms.NumericUpDown; $nudCY.Minimum=0; $nudCY.Maximum=100
    $nudCY.Value = [Math]::Max(0,[Math]::Min(100,[int]$cfg.CircleY))

    Add-Row "Circle Size (px):" $nudSize $y; $y += 32
    Add-Row "Circle X (%):"     $nudCX   $y; $y += 32
    Add-Row "Circle Y (%):"     $nudCY   $y; $y += 32

    # Hotkey
    Add-Sep "── Hotkey ───────────────────────────────────────" $y; $y += 22
    $lblHK = New-Object System.Windows.Forms.Label
    $lblHK.Text = "Shortcut:"; $lblHK.Location = New-Object System.Drawing.Point 12,($y+3)
    $lblHK.Size = New-Object System.Drawing.Size 140,20; $dlg.Controls.Add($lblHK)

    $txtHotkey = New-Object System.Windows.Forms.TextBox
    $txtHotkey.Text = Get-HotkeyText ([int]$cfg.HotkeyMods) ([int]$cfg.HotkeyVK)
    $txtHotkey.ReadOnly = $true
    $txtHotkey.Location = New-Object System.Drawing.Point 158,$y; $txtHotkey.Size = New-Object System.Drawing.Size 120,22
    $dlg.Controls.Add($txtHotkey)

    $btnChange = New-Object System.Windows.Forms.Button
    $btnChange.Text = "Change"; $btnChange.Location = New-Object System.Drawing.Point 284,$y
    $btnChange.Size = New-Object System.Drawing.Size 64,22; $dlg.Controls.Add($btnChange)

    $script:_pendingMods = [int]$cfg.HotkeyMods
    $script:_pendingVK   = [int]$cfg.HotkeyVK

    $btnChange.add_Click({
        $script:hotkey.Suspended = $true
        $cap = Show-HotkeyCapture
        $script:hotkey.Suspended = $false
        if ($cap) {
            $script:_pendingMods = $cap.Mods
            $script:_pendingVK   = $cap.VK
            $txtHotkey.Text = Get-HotkeyText $cap.Mods $cap.VK
        }
    })
    $y += 36

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Apply"; $btn.Location = New-Object System.Drawing.Point 120,($y+8)
    $btn.Size = New-Object System.Drawing.Size 130,28; $btn.DialogResult = 'OK'
    $dlg.Controls.Add($btn); $dlg.AcceptButton = $btn

    if ($dlg.ShowDialog() -eq 'OK') {
        $hotkeyChanged   = ($script:_pendingMods -ne [int]$cfg.HotkeyMods -or $script:_pendingVK -ne [int]$cfg.HotkeyVK)
        $cfg.BarText       = $txtText.Text
        $cfg.BarColor      = $txtColor.Text
        $cfg.BarOpacity    = [int]$nudOpacity.Value
        $cfg.IndicatorType = $cboType.SelectedItem
        $cfg.BarHeight     = [int]$nudHeight.Value
        $cfg.BarWidthPct   = [int]$nudWidth.Value
        $cfg.BarPosition   = $cboPos.SelectedItem
        $cfg.CircleSize    = [int]$nudSize.Value
        $cfg.CircleX       = [int]$nudCX.Value
        $cfg.CircleY       = [int]$nudCY.Value
        $cfg.HotkeyMods    = $script:_pendingMods
        $cfg.HotkeyVK      = $script:_pendingVK
        $cfg | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8
        if ($hotkeyChanged) {
            $script:hotkey.Dispose()
            $script:hotkey = New-Object KeyboardHook $script:_pendingMods, $script:_pendingVK
            $script:hotkey.add_Fired($script:toggle)
        }
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
$tray.ContextMenuStrip = $menu
$miAutostart.Checked = Get-AutostartEnabled

Set-IndicatorVisible $muted

# Toggle mute
$script:toggle = {
    $script:muted = -not $script:muted
    [AudioHelper]::SetAllMuted($script:muted)
    Set-IndicatorVisible $script:muted
    $tray.Icon = New-TrayIcon $script:muted
    $tray.Text = if ($script:muted) { "MicMuteBar - MUTED" } else { "MicMuteBar" }
}

# Low-level hook for the configured hotkey (always fires regardless of other apps)
$hotkey = New-Object KeyboardHook ([int]$cfg.HotkeyMods), ([int]$cfg.HotkeyVK)
$hotkey.add_Fired($script:toggle)

# Tray menu events
$miSet.add_Click({
    if (Show-Settings) {
        Remove-Indicator
        [System.Windows.Forms.Application]::DoEvents()
        New-Indicator
        Set-IndicatorVisible $script:muted
    }
})
$miAutostart.add_Click({
    $newState = -not (Get-AutostartEnabled)
    Set-Autostart $newState
    $miAutostart.Checked = $newState
})
$miExit.add_Click({
    [AudioHelper]::SetAllMuted($false)
    $hotkey.Dispose()
    $tray.Visible = $false
    $script:anchor.Close()
})

# Double-click tray icon = toggle
$tray.add_DoubleClick($script:toggle)

# Anchor form: keeps the message loop alive (required for ps2exe EXE)
$anchor = New-Object System.Windows.Forms.Form
$anchor.Opacity       = 0
$anchor.ShowInTaskbar = $false
$anchor.WindowState   = 'Minimized'
$anchor.Size          = New-Object System.Drawing.Size 1,1
[System.Windows.Forms.Application]::Run($anchor)
