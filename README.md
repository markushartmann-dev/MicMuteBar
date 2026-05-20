# MicMuteBar

Global microphone mute for Windows with a persistent status bar on every monitor.

---

## What it does

Press **Win+M** to mute or unmute all microphones at once. While muted, a colored bar appears across the top of every connected monitor — impossible to miss, even on a 4-monitor setup.

- **One hotkey** mutes every microphone in the system simultaneously
- **Status bar** appears on all monitors when muted, disappears when unmuted
- **Click-through** — the bar never blocks anything you're working on
- **Tray icon** shows current state at a glance; right-click for settings and exit

No Python. No .NET SDK. No installation. Runs on any Windows 10/11 machine with PowerShell 5.1, which is built into Windows.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (pre-installed on all modern Windows)
- No additional software needed

---

## Getting started

1. Download or clone the repository
2. Double-click **`Start.bat`**
3. A microphone icon appears in the system tray
4. Press **Win+M** to toggle mute

The bar appears on all monitors while muted and disappears when you unmute.

---

## Settings

Right-click the tray icon → **Einstellungen** (Settings):

| Option | Default | Description |
|---|---|---|
| Text | `MIC MUTED` | Text shown in the bar (leave empty for no text) |
| Color | `#FF2020` | Bar background color (any hex value) |
| Height | `18 px` | Bar height in pixels |
| Width | `100 %` | Bar width as percentage of screen width |
| Position | `top` | `top` or `bottom` of each screen |

Settings are saved to `config.json` in the same folder.

---

## How it works

MicMuteBar is a single PowerShell script (~380 lines) with no external dependencies.

- **Hotkey** — uses a low-level Windows keyboard hook (`SetWindowsHookEx WH_KEYBOARD_LL`), so Win+M is always intercepted regardless of what other applications are doing with that shortcut
- **Audio** — controls all capture devices via the Windows Core Audio API (COM) directly, no third-party audio library required
- **Overlay** — one borderless, always-on-top WinForms window per monitor; click-through via `WM_NCHITTEST → HTTRANSPARENT`
- **Tray** — standard `NotifyIcon` with a programmatically drawn icon that reflects mute state

---

## Autostart with Windows

1. Press **Win+R**, type `shell:startup`, press Enter
2. Create a shortcut to `Start.bat` in that folder

MicMuteBar will now start automatically when you log in.

---

## License

MIT
