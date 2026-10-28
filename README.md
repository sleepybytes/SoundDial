# SoundDial

A macOS menu-bar app for per-app volume and per-app output routing, controlled from the keyboard.
Send Chrome to the MacBook speakers and Slack to your EarPods, turn one app down without touching the rest,
and switch outputs with a hotkey.

Requires macOS 15+. Uses Core Audio process taps, so no audio driver is installed.

## Build & run

```bash
./build.sh            # builds and signs build/SoundDial.app
open build/SoundDial.app
./build.sh install    # copies it to /Applications (needed for "Launch at login")
```

On first launch macOS asks for **System Audio Recording** access. SoundDial won't change any app's
audio until you allow it. You can grant it later in System Settings › Privacy & Security.

## Using it

- **Menu bar** (dial icon): default output and input, the output device's volume, and a row for every app that is
  playing audio. Each row has its own volume, mute and output device.
- **Configure…** opens the routing window, with one row per app. Set its output, volume, mute and a
  *mic while recording* rule. Use **Add App…** to set up an app before it plays anything. Rules are saved.
- **Hotkeys**. The selected app follows whichever app is frontmost.

| Keys | Action |
|---|---|
| ⌃⌥ ↑ / ↓ | Selected app volume ±5% (hold to repeat) |
| ⌃⌥ ← / → | Select previous / next app that's playing |
| ⌃⌥ M | Mute / unmute selected app |
| ⌃⌥ 1 / 2 / 3 | Send selected app to output slot 1 / 2 / 3 |
| ⌃⌥ 0 | Send selected app back to the default output |
| ⌃⌥⇧ 1 / 2 / 3 | Make slot 1 / 2 / 3 the default output |
| ⌃⌥⇧ ↑ / ↓ | Volume of the selected app's output device |

Slots are set under Configure › Hotkeys. By default they are built-in speakers, then USB or Bluetooth
headphones, then a DisplayPort or HDMI monitor.

## How it works

Each app that needs a change gets a process tap, which mutes the original audio. The tap feeds a private
aggregate device that plays the audio on the chosen output at the chosen gain. Apps with no rules are not tapped.
Monitors with no hardware volume, such as DisplayPort displays, use a software gain instead.

## Limits

- **Mic per app**: macOS can't give each app its own microphone without a virtual audio driver. Instead, when an app
  with a mic rule starts recording, SoundDial switches the *system default input* to that mic. It switches back
  when the app stops recording. This only works with apps whose mic setting is "System default".
- Tapped apps get a few milliseconds of extra latency.
- An app can only play on one output at a time.
- DRM-protected audio may not be tappable.
