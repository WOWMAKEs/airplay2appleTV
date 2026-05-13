# airplay2appleTV

A macOS CLI tool to instantly turn on, off, or toggle Apple TV AirPlay / Screen Mirroring.

> CLI command: `airplay-tv`

> Note: Apple does not expose a stable public CLI/API for AirPlay display target selection. This tool uses macOS Accessibility automation to interact with Control Center. First-time use requires granting "Accessibility" permission to your terminal app.

## Build

```sh
swift build
```

## Install

```sh
chmod +x install.sh
./install.sh
```

## First-time Permission Setup

```sh
airplay-tv setup
```

Then go to:

```text
System Settings > Privacy & Security > Accessibility
```

Allow your terminal app (Terminal, iTerm2, Codex, etc.).

## Usage

By default operates on the first available Apple TV (index 1):

```sh
airplay-tv on      # Turn on (shows "already on" if already on)
airplay-tv off     # Turn off (shows "already off" if already off)
airplay-tv toggle  # Toggle
airplay-tv status  # Check current state
airplay-tv list    # List available devices
```

Specify device index:

```sh
airplay-tv on --index 2
airplay-tv off --index 2
```

Specify device name:

```sh
airplay-tv on --device "Living Room Apple TV"
```

Debug UI structure:

```sh
airplay-tv debug
```

## Environment Variables

```sh
export AIRPLAY_TV_INDEX=1   # Default device index
```

## Quick Alias Examples

Add to your shell config (e.g., `~/.zshrc`):

```sh
alias aptv='airplay-tv toggle'
alias aptv-on='airplay-tv on'
alias aptv-off='airplay-tv off'
alias aptv-status='airplay-tv status'
```

## How It Works

- `on` / `off` commands first check current state via `status`, only toggles if needed
- If device name is not visible in UI, automatically falls back to index 1
- Uses macOS Control Center Accessibility automation

## Troubleshooting

- If "Screen Mirroring" cannot be found, open Control Center manually once to make the "Screen Mirroring" widget visible
- Different macOS versions may have different Control Center structures. If Apple updates the UI, the embedded automation script may need adjustment