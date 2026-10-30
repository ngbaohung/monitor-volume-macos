# Monitor Volume

A menu bar app that controls the built-in speakers of an external monitor (tested with a
ViewSonic VA3456 on the HDMI port of a Mac mini M4) using the normal volume keys.

macOS can't change the volume of HDMI audio. The app offers two modes, switchable in the panel:

- **Monitor**: changes the monitor's **own hardware volume** over DDC/CI (MCCS VCP `0x62`
  volume, `0x8D` mute). No audio is processed, but every computer on the monitor shares the level.
- **Mac**: turns the Mac's audio down in software using a Core Audio process tap, without touching
  the monitor's own volume. The monitor keeps the level set in Monitor mode, which is what another
  computer (e.g. Windows) on the same monitor gets. Needs the *System Audio Recording* permission,
  and macOS shows a recording indicator while it runs.

A fresh install starts in Mac mode. Each mode keeps its own level, and switching modes never
changes the monitor's volume. Example: set Monitor to 70%, switch to Mac and set it to 30%. The Mac
plays at 30% of the monitor's 70%, and Windows gets 70%.

## Features

- Volume Up / Down / Mute keys control the currently selected output: the monitor via DDC/CI,
  any other device (Mac speakers, headphones) via macOS as usual. Each press = 1% on the monitor
- Circular volume-knob overlay and a Control Center-style menu bar panel
- Switch the sound output, and choose which device plays alerts and sound effects
- Opens at login (enabled on first launch, toggle in the menu), optionally setting the monitor
  to a chosen level (default 10%) when it starts at login
- Optionally resets the monitor to 100% when the Mac sleeps or shuts down, so another computer
  on the same monitor gets full volume; the monitor's level is restored when the Mac wakes

## Build & install

Requires macOS 26+ and the Swift toolchain (Command Line Tools are enough).

```sh
./scripts/build-app.sh            # builds "build/Monitor Volume.app"
./scripts/build-app.sh --install  # also copies it to /Applications and launches it
```

On first launch, open the menu bar icon → **Open Accessibility Settings…** and enable
*Monitor Volume*. The volume keys need this permission.

### Signing note

The app is signed ad-hoc by default, so macOS forgets the Accessibility permission after each
rebuild. To keep the permission, create a self-signed "Code Signing" certificate in Keychain
Access and build with `SIGN_IDENTITY="Your Cert Name" ./scripts/build-app.sh --install`.

## Backup installer

```sh
./scripts/make-dmg.sh   # creates dist/MonitorVolume-<version>.dmg
```

The DMG contains the app, an Applications shortcut and install notes. Keep a copy off this Mac
(iCloud Drive, USB drive) so you can reinstall after a reset. The app isn't notarized, so on a
fresh Mac use System Settings › Privacy & Security › **Open Anyway** the first time.

## How Mac mode works

A process tap captures the audio other apps send to the monitor's HDMI stream and mutes the
original while it's being read. A private aggregate device (the tap plus the HDMI device) plays the
captured audio back to the monitor with the gain applied. Only audio headed to the monitor is
affected; alerts going to the Mac's speakers are untouched. If the app quits or crashes, the tap
disappears and audio plays normally again.

## Troubleshooting

- **"No DDC/CI monitor found"**: enable DDC/CI in the monitor's OSD menu, then click Refresh.
- **Keys still change the Mac's volume**: check the Accessibility permission. If you just rebuilt
  the app, remove the old entry and add it again.
- **Mac mode says it needs permission**: System Settings › Privacy & Security › Screen & System
  Audio Recording › enable Monitor Volume. Like Accessibility, rebuilding the app resets this.
- **Mac mode is paused**: it only runs while the monitor is the selected sound output.
