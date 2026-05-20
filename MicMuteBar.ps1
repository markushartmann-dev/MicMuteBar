#Requires -Version 5.1
<#
.SYNOPSIS
    MicMuteBar — Win+M mutet alle Mikrofone, zeigt roten Balken auf jedem Monitor.
    Tray-Icon: Rechtsklick → Einstellungen / Beenden
    Konfiguration: config.json im selben Ordner
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ── Config ─────────────────────────────────────────────────────────────────────
$cfgPath = Join-Path $PSScriptRoot "config.json"
$defaults = [ordered]@{
    BarColor       = "#FF2020"
    BarHeight      = 18
    BarPosition    = "top"   # top | bottom
    BarWidthPct    = 100     # 10-100
    BarText        = "MIC MUTED"
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

# ── C# Kern: Audio (Core Audio COM) + Hotkey + BarForm ────────────────────────
Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing' @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// ──── Win32 ────────────────────────────────────────────────────────────────────
public static class Win32 {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern int  SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern int  GetWindowLong(IntPtr hWnd, int nIndex);
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
    const int eCapture           = 1;
    const int DEVICE_STATE_ACTIVE = 1;
    const int CLSCTX_ALL         = 23;

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

// ──── Click-through overlay bar ────────────────────────────────────────────────
public class BarForm : Form {
    const int WM_NCHITTEST  = 0x0084;
    const int HTTRANSPARENT = -1;

    string _text;

    public BarForm(int x, int y, int w, int h, string hexColor, double opacity, string text) {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar   = false;
        TopMost         = true;
        BackColor       = ColorTranslator.FromHtml(hexColor);
        Opacity         = opacity;
        StartPosition   = FormStartPosition.Manual;
        AutoScaleMode   = AutoScaleMode.None;   // kein DPI-Rescaling
        MinimumSize     = System.Drawing.Size.Empty;
        Location        = new System.Drawing.Point(x, y);
        Size            = new System.Drawing.Size(w, h);
        _text = text;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    // Alle Mausklicks durchreichen – zuverlaessiger als WS_EX_TRANSPARENT
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_NCHITTEST) {
            m.Result = (IntPtr)HTTRANSPARENT;
            return;
        }
        base.WndProc(ref m);
    }

    protected override void OnPaintBackground(PaintEventArgs e) {
        e.Graphics.Clear(BackColor);
    }

    protected override void OnPaint(PaintEventArgs e) {
        if (string.IsNullOrEmpty(_text)) return;
        float fs = Math.Max(7f, ClientSize.Height * 0.62f);
        using (var font = new Font("Segoe UI", fs, GraphicsUnit.Pixel)) {
            TextRenderer.DrawText(e.Graphics, _text, font, ClientRectangle, Color.White,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        }
    }
}

// ──── Low-level keyboard hook (immer aktiv, ueberschreibt andere Apps) ────────
public class KeyboardHook : IDisposable {
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] static extern bool   UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT {
        public uint vkCode, scanCode, flags, time;
        public IntPtr dwExtraInfo;
    }

    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN     = 0x0100;
    const int WM_SYSKEYDOWN  = 0x0104;
    const int VK_M           = 0x4D;
    const int VK_LWIN        = 0x5B;
    const int VK_RWIN        = 0x5C;

    IntPtr _hookId;
    LowLevelKeyboardProc _cb;  // Referenz halten, sonst GC
    bool _winDown;
    public event EventHandler Fired;

    public KeyboardHook() {
        _cb = Callback;
        _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _cb, IntPtr.Zero, 0);
    }

    IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            var info = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            bool down = wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN;
            if (info.vkCode == VK_LWIN || info.vkCode == VK_RWIN) {
                _winDown = down;
            } else if (_winDown && info.vkCode == VK_M && down) {
                if (Fired != null) Fired(this, EventArgs.Empty);
                return (IntPtr)1;  // Taste unterdruecken
            }
        }
        return CallNextHookEx(_hookId, nCode, wParam, lParam);
    }

    public void Dispose() {
        if (_hookId != IntPtr.Zero) { UnhookWindowsHookEx(_hookId); _hookId = IntPtr.Zero; }
    }
}
'@

# ── Tray-Icon erzeugen (programmatisch, kein .ico nötig) ──────────────────────
function New-TrayIcon([bool]$muted) {
    $bmp = New-Object System.Drawing.Bitmap 16,16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $col = if ($muted) { [System.Drawing.Color]::FromArgb(220,30,30) }
           else        { [System.Drawing.Color]::FromArgb(30,180,30) }
    $brush = New-Object System.Drawing.SolidBrush $col
    # Mikrofon-Silhouette
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

# ── Balken pro Monitor anlegen ─────────────────────────────────────────────────
function New-Bars {
    $result = @()
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $pct = [Math]::Max(10, [Math]::Min(100, [int]$cfg.BarWidthPct))
        $bw  = [int]($screen.Bounds.Width * $pct / 100)
        $bh  = [Math]::Max(2, [int]$cfg.BarHeight)
        $bx  = $screen.Bounds.Left + ($screen.Bounds.Width - $bw) / 2
        $by  = if ($cfg.BarPosition -eq "bottom") { $screen.Bounds.Bottom - $bh }
               else { $screen.Bounds.Top }
        $bar = New-Object BarForm $bx, $by, $bw, $bh, $cfg.BarColor, 0.88, $cfg.BarText
        $result += $bar
    }
    return $result
}

# ── Einstellungen-Dialog ───────────────────────────────────────────────────────
function Show-Settings {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "MicMuteBar - Einstellungen"
    $dlg.Size = New-Object System.Drawing.Size 320, 272
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterScreen'
    $dlg.TopMost = $true

    $fields = @(
        @{ Label="Text:";              Key="BarText";     Type="text" }
        @{ Label="Farbe (Hex):";       Key="BarColor";    Type="text" }
        @{ Label="Balkenhöhe (px):";   Key="BarHeight";   Type="number"; Min=2;  Max=60  }
        @{ Label="Balkenbreite (%):";  Key="BarWidthPct"; Type="number"; Min=10; Max=100 }
        @{ Label="Position:";          Key="BarPosition"; Type="combo";  Items=@("top","bottom") }
    )

    $y = 12
    $controls = @{}
    foreach ($f in $fields) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $f.Label; $lbl.Location = New-Object System.Drawing.Point 12,$y
        $lbl.Size = New-Object System.Drawing.Size 140,20
        $dlg.Controls.Add($lbl)
        if ($f.Type -eq "combo") {
            $ctl = New-Object System.Windows.Forms.ComboBox
            $ctl.DropDownStyle = 'DropDownList'
            $f.Items | ForEach-Object { $ctl.Items.Add($_) | Out-Null }
            $ctl.SelectedItem = $cfg.($f.Key)
        } elseif ($f.Type -eq "number") {
            $ctl = New-Object System.Windows.Forms.NumericUpDown
            $ctl.Minimum = $f.Min; $ctl.Maximum = $f.Max
            $ctl.Value   = [Math]::Max($f.Min, [Math]::Min($f.Max, [int]$cfg.($f.Key)))
        } else {
            $ctl = New-Object System.Windows.Forms.TextBox
            $ctl.Text = $cfg.($f.Key)
        }
        $ctl.Location = New-Object System.Drawing.Point 158,$y
        $ctl.Size     = New-Object System.Drawing.Size 130,22
        $dlg.Controls.Add($ctl)
        $controls[$f.Key] = $ctl
        $y += 32
    }

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Übernehmen"; $btn.Location = New-Object System.Drawing.Point 90,($y+4)
    $btn.Size = New-Object System.Drawing.Size 130,28; $btn.DialogResult = 'OK'
    $dlg.Controls.Add($btn); $dlg.AcceptButton = $btn

    if ($dlg.ShowDialog() -eq 'OK') {
        $cfg.BarText     = $controls["BarText"].Text
        $cfg.BarColor    = $controls["BarColor"].Text
        $cfg.BarHeight   = [int]$controls["BarHeight"].Value
        $cfg.BarWidthPct = [int]$controls["BarWidthPct"].Value
        $cfg.BarPosition = $controls["BarPosition"].SelectedItem
        $cfg | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8
        return $true
    }
    return $false
}

# ── Hauptprogramm ──────────────────────────────────────────────────────────────
[System.Windows.Forms.Application]::EnableVisualStyles()

$muted = [AudioHelper]::IsAnyMuted()
$bars  = New-Bars

# Tray-Icon
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon    = New-TrayIcon $muted
$tray.Text    = if ($muted) { "MicMuteBar - MUTED" } else { "MicMuteBar" }
$tray.Visible = $true

$menu    = New-Object System.Windows.Forms.ContextMenuStrip
$miSet   = $menu.Items.Add("Einstellungen")
$miExit  = $menu.Items.Add("Beenden")
$tray.ContextMenuStrip = $menu

# Balken anzeigen/verbergen
function Set-BarsVisible([bool]$show) {
    foreach ($b in $bars) {
        if ($show) { $b.Show(); $b.BringToFront() }
        else       { $b.Hide() }
    }
}

Set-BarsVisible $muted

# Toggle-Funktion
$toggle = {
    $script:muted = -not $script:muted
    [AudioHelper]::SetAllMuted($script:muted)
    Set-BarsVisible $script:muted
    $tray.Icon = New-TrayIcon $script:muted
    $tray.Text = if ($script:muted) { "MicMuteBar - MUTED" } else { "MicMuteBar" }
}

# Low-level Hook fuer Win+M (funktioniert immer, egal was andere Apps belegen)
$hotkey = New-Object KeyboardHook
$hotkey.add_Fired($toggle)

# Tray-Menü Events
$miSet.add_Click({
    if (Show-Settings) {
        foreach ($b in $script:bars) { $b.Dispose() }
        [System.Windows.Forms.Application]::DoEvents()
        $script:bars = New-Bars
        Set-BarsVisible $script:muted
    }
})
$miExit.add_Click({
    [AudioHelper]::SetAllMuted($false)
    $hotkey.Dispose()
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# Doppelklick auf Tray = Toggle
$tray.add_DoubleClick($toggle)

[System.Windows.Forms.Application]::Run()
