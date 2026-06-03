# MicMuteBar

Global microphone mute for Windows with a persistent status indicator on every monitor.

---

## What it does

Press your hotkey to mute or unmute all microphones at once. While muted, a colored indicator appears on every connected monitor — impossible to miss, even on a 4-monitor setup.

The default shortcut is **Ctrl+Shift+Alt+P**, but you can change it to any combination you like — directly inside the app, no config file editing required.

- **One hotkey** mutes every microphone simultaneously — works across Teams, Zoom, Discord, and any other app
- **Works everywhere** — desktop, Explorer, any application, even when nothing is focused
- **Status indicator** appears on all monitors when muted, disappears when unmuted
- **Four indicator styles** — bar, circle, border (full screen frame), or corner squares
- **Optional pulse** — the indicator alternates between two colors while muted, fully configurable
- **Click-through** — the indicator never blocks anything you're working on
- **Configurable hotkey** — set any key combination you like via Settings
- **Autostart** — toggle Windows startup via tray menu or Settings
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
4. Press **Ctrl+Shift+Alt+P** to toggle mute (or assign your own shortcut in Settings)

The indicator appears on all monitors while muted and disappears when you unmute.

---

## Settings

Right-click the tray icon → **Settings**:

### General
| Option | Default | Description |
|---|---|---|
| Text | `MIC MUTED` | Text shown in the bar (leave empty for no text) |
| Color | `#FF2020` | Indicator color — type any hex value or click **Pick** to open the color chooser |
| Opacity | `90 %` | Transparency (10 = nearly invisible, 100 = fully opaque) |
| Indicator | `bar` | `bar` · `circle` · `border` · `corner` — see sections below |

### Bar
| Option | Default | Description |
|---|---|---|
| Thickness | `18 px` | Thickness of the bar in pixels |
| Length | `100 %` | Length as percentage of the screen edge |
| Position | `top` | `top` · `bottom` · `left` · `right` — which edge of each screen |

### Circle
| Option | Default | Description |
|---|---|---|
| Size | `80 px` | Diameter in pixels |
| Position X | `50 %` | Horizontal position on primary screen (% from left) |
| Position Y | `10 %` | Vertical position on primary screen (% from top) |

### Border
A complete rectangular frame around every monitor.

| Option | Default | Description |
|---|---|---|
| Thickness | `8 px` | Width of the border line |
| Gap from edge | `0 px` | Inset from the screen edge (0 = flush with edge) |

### Corner
A small square in each corner of every monitor.

| Option | Default | Description |
|---|---|---|
| Size | `40 px` | Width and height of each corner square |
| Edge offset | `0 px` | Distance from the screen corner (0 = flush with corner) |

### Hotkey
| Option | Default | Description |
|---|---|---|
| Shortcut | `Ctrl+Shift+Alt+P` | Click **Change** and press any key combination — takes effect immediately |

### Startup & Effect
| Option | Default | Description |
|---|---|---|
| Start with Windows | off | Also available via tray right-click |
| Pulse when muted | off | Alternates the indicator between two colors while muted |
| Pulse color | `#FF8000` | Second color for the pulse — click **Pick** to choose |

Settings are saved to `config.json` in the same folder.

---

## Autostart with Windows

Right-click the tray icon → **Start with Windows** to toggle autostart on or off, or use the checkbox in Settings.
A checkmark indicates it is enabled. MicMuteBar will start automatically on login.

---

## How it works

MicMuteBar is a single PowerShell script (~850 lines) with no external dependencies.

- **Hotkey** — uses `RegisterHotKey` (Windows global hotkey API), so the shortcut fires regardless of which application or window is focused — including the desktop
- **Audio** — controls all capture devices via the Windows Core Audio API (COM) directly, no third-party audio library required
- **Bar / Border / Corner overlays** — borderless, always-on-top WinForms windows; click-through via `WS_EX_TRANSPARENT` in `CreateParams` + `WM_NCHITTEST → HTTRANSPARENT`; transparency via `Form.Opacity`
- **Circle overlay** — same click-through approach; circular shape via `Form.Region` clipping
- **Pulse** — `System.Windows.Forms.Timer` at 600 ms alternates `BackColor` between the two configured colors while muted; indicator stays visible, only the color changes
- **Autostart** — creates/removes a shortcut in the Windows startup folder via `WScript.Shell`
- **Tray** — standard `NotifyIcon` with a programmatically drawn icon that reflects mute state; context menu uses `SetForegroundWindow` + manual `Show(Point)` so it always appears above the taskbar

---

## License

MIT
