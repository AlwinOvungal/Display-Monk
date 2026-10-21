# Display Monk

A free, open-source menu bar app and command-line tool for controlling your Mac's displays:
hardware brightness, contrast, volume and input switching over DDC/CI, software dimming,
resolutions with HiDPI scaling, refresh rate and rotation.

Requires macOS 13 Ventura or later. Works on both Apple Silicon and Intel Macs.

## Features

| | Menu bar app | CLI |
|---|---|---|
| Brightness: native (Apple displays), DDC (external monitors) or software (gamma) | ✓ | ✓ (native, DDC) |
| Contrast, speaker volume and mute over DDC | ✓ | ✓ |
| Input switching (HDMI, DisplayPort, USB-C, …) | ✓ | ✓ |
| Raw read/write of any VCP code | | ✓ |
| Resolution list with HiDPI modes, refresh rate | ✓ | ✓ |
| Rotation | ✓ | ✓ |
| Brightness/volume keys control the display under the pointer, with an on-screen display | ✓ | |
| Remembers per-display settings, launch at login | ✓ | |

## Install

Download `DisplayMonk.zip` from the latest CI run's artifacts (Actions → Build → DisplayMonk),
unzip it and move **Display Monk.app** to `/Applications`. Builds are ad-hoc signed, so the first
time you open it, right-click the app and choose **Open**.

The `displaymonk` command-line tool is in the same artifact. Put it somewhere on your `PATH`,
for example `/usr/local/bin`.

### Build from source

```sh
swift build                 # debug build
swift run DisplayMonkApp    # run the menu bar app unbundled
swift run displaymonk list  # run the CLI
scripts/bundle.sh           # universal release: build/Display Monk.app and build/displaymonk
```

## Command-line usage

```sh
displaymonk list                     # displays, how each is controlled, current mode
displaymonk list --probe             # also test each DDC connection
displaymonk brightness               # read brightness of the main display
displaymonk brightness 60 -d external
displaymonk brightness +10 -d "DELL"
displaymonk volume -10               # relative changes work for every level command
displaymonk mute toggle
displaymonk input hdmi1              # vga1 vga2 dvi1 dvi2 dp1 dp2 hdmi1 hdmi2 usbc, or a code like 0x0f
displaymonk get 0x10                 # raw VCP read
displaymonk set contrast 70          # raw VCP write
displaymonk modes                    # * marks the current mode
displaymonk set-mode 1920x1080@60 --hidpi
displaymonk rotate 90
```

`-d/--display` accepts a list index, `main`, `builtin`, `external`, `id:<n>` or part of a
display name. DDC commands default to the first display with a DDC connection, and the others
default to the main display.

Software dimming only lasts while the process that set it is running (macOS restores gamma
tables when it exits), so it is only offered in the app.

## Permissions

- **Accessibility** is needed only if you turn on the brightness or volume key options. macOS
  will ask when you enable them (System Settings → Privacy & Security → Accessibility).
- The app is not sandboxed: DDC needs direct IOKit access.

## How it works

| Feature | Mechanism |
|---|---|
| DDC on Apple Silicon | `IOAVServiceWriteI2C`/`ReadI2C` on the `DCPAVServiceProxy` under each external framebuffer, matched to displays via the framebuffer's EDID UUID and registry path |
| DDC on Intel | `IOI2CSendRequest` through the display's `IOFramebuffer` |
| Native brightness | `DisplayServicesGet/SetBrightness` (private DisplayServices framework) |
| Software dimming | Scaled gamma tables with `CGSetDisplayTransferByTable` |
| Modes and HiDPI | `CGDisplayCopyAllDisplayModes` with `kCGDisplayShowDuplicateLowResolutionModes`, `CGConfigureDisplayWithDisplayMode` |
| Rotation | `MPDisplay.setOrientation:` from the private MonitorPanel framework |
| Media keys | A `CGEventTap` for `NX_SYSDEFINED` auxiliary-button events |

Private symbols are resolved at runtime with `dlsym`. If a future macOS removes one, the feature
that needs it stops working, but the app still launches.

### Project layout

```
Sources/DisplayMonkCore   Pure Swift: DDC/CI framing, EDID parsing, mode selection, argument parsing (tested on Linux and macOS)
Sources/DisplayKit        macOS display access: DDC transports, brightness, modes, rotation
Sources/DisplayMonkApp    SwiftUI menu bar app
Sources/displaymonk       CLI (swift-argument-parser)
Tests/DisplayMonkCoreTests
```

## Testing on real hardware

Unit tests cover everything that doesn't need a display. With a monitor attached, check:

1. `displaymonk list --probe`: every external monitor shows `ddc` and a brightness value.
2. `displaymonk brightness 30 -d external` changes the monitor's backlight; `volume`, `contrast`
   and `input` behave the same way (not every monitor implements all of them).
3. `displaymonk brightness 50 -d builtin` changes a MacBook's built-in screen.
4. `displaymonk modes`, then `set-mode` to a HiDPI mode and back.
5. App: sliders work for each display; turn on the key options and check that the brightness
   keys change the external monitor under the pointer and show the HUD; set a display to
   *Software*, dim it, quit, and check the brightness returns to normal.
6. Unplug and replug a monitor: the menu updates and DDC still works.

## Acknowledgements

The DDC techniques here are well established in the open-source community. Thanks to
[MonitorControl](https://github.com/MonitorControl/MonitorControl),
[m1ddc](https://github.com/waydabber/m1ddc) and
[displayplacer](https://github.com/jakehilborn/displayplacer) (all MIT-licensed), whose
published work documents the Apple Silicon DDC path, display matching and rotation.

Display Monk is an independent project and is not affiliated with BetterDisplay or its developer.

## License

MIT. See [LICENSE](LICENSE).
