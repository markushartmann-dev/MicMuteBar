# MicMuteBar

Global microphone mute for Windows with a persistent status indicator on every monitor.

---

## What it does

Press your configured hotkey (default: **Win+M**) to mute or unmute all microphones at once. While muted, a colored indicator appears on every connected monitor — impossible to miss, even on a 4-monitor setup.

- **One hotkey** mutes every microphone simultaneously — works across Teams, Zoom, Discord, and any other app
- **Status indicator** appears on all monitors when muted, disappears when unmuted
- **Two indicator styles** — full-width bar or a freely positionable circle
- **Click-through** — the indicator never blocks anything you're working on
- **Configurable hotkey** — set any key combination you like
- **Autostart** — optional one-click Windows startup integration
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
2. Double-click **`MicMuteBar.exe`**
3. A microphone icon appears in the system tray
4. Press **Win+M** to toggle mute

The indicator appears on all monitors while muted and disappears when you unmute.

---

## Settings

Right-click the tray icon → **Settings**:

### General
| Option | Default | Description |
|---|---|---|
| Text | `MIC MUTED` | Text shown in the bar (leave empty for no text) |
| Color | `#FF2020` | Indicator color (any hex value) |
| Opacity | `90 %` | Transparency (10 = nearly invisible, 100 = fully opaque) |
| Indicator | `bar` | `bar` — full-width bar on every monitor · `circle` — single dot, freely positionable |

### Bar
| Option | Default | Description |
|---|---|---|
| Bar Height | `18 px` | Height of the bar in pixels |
| Bar Width | `100 %` | Width as percentage of each screen |
| Bar Position | `top` | `top` or `bottom` of each screen |

### Circle
| Option | Default | Description |
|---|---|---|
| Circle Size | `80 px` | Diameter in pixels |
| Circle X | `50 %` | Horizontal position on primary screen (% from left) |
| Circle Y | `10 %` | Vertical position on primary screen (% from top) |

### Hotkey
| Option | Default | Description |
|---|---|---|
| Shortcut | `Win+M` | Click **Change** and press any key combination |

Settings are saved to `config.json` in the same folder.

---

## Autostart with Windows

Right-click the tray icon → **Start with Windows** to toggle autostart on or off.  
A checkmark indicates it is enabled. MicMuteBar will start automatically on login.

---

## How it works

MicMuteBar is a single PowerShell script (~340 lines) with no external dependencies.

- **Hotkey** — uses a low-level Windows keyboard hook (`SetWindowsHookEx WH_KEYBOARD_LL`), so the hotkey is always intercepted regardless of what other applications are doing
- **Audio** — controls all capture devices via the Windows Core Audio API (COM) directly, no third-party audio library required
- **Bar overlay** — one borderless, always-on-top WinForms window per monitor; click-through via `WS_EX_TRANSPARENT` in `CreateParams` + `WM_NCHITTEST → HTTRANSPARENT`; transparency via `Form.Opacity`
- **Circle overlay** — same click-through approach; circular shape via `Form.Region` clipping
- **Autostart** — creates/removes a shortcut in the Windows startup folder via `WScript.Shell`
- **Tray** — standard `NotifyIcon` with a programmatically drawn icon that reflects mute state

---

## License

MIT
