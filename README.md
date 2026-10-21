# Display Monk

A free, open-source menu bar app and command-line tool for controlling your Mac's displays:
hardware brightness, contrast, volume and input switching over DDC/CI, software dimming,
resolutions with HiDPI scaling, refresh rate and rotation.

Requires macOS 13 Ventura or later. Works on both Apple Silicon and Intel Macs.

Website: <https://alwinovungal.github.io/Display-Monk/> (source in `site/`, published by the
**Pages** workflow).

## Features

| | Menu bar app | CLI |
|---|---|---|
| Brightness: native (Apple displays), DDC (external monitors) or software (gamma) | ✓ | ✓ (native, DDC) |
| Combined brightness: backlight first, then software dimming down to black | ✓ | |
| High Resolution (HiDPI) for external displays, instantly, with a resolution dropdown | ✓ | ✓ (`hidpi`) |
| Display arrangement (left/right/above/below, alignment) and main display | ✓ | |
| Contrast, speaker volume and mute over DDC | ✓ | ✓ |
| Input switching (HDMI, DisplayPort, USB-C, …) | ✓ | ✓ |
| Raw read/write of any VCP code | | ✓ |
| Resolution list with HiDPI modes, refresh rate | ✓ | ✓ |
| Rotation | ✓ | ✓ |
| Brightness/volume keys control the display under the pointer, with an on-screen display | ✓ | |
| Remembers per-display settings, launch at login | ✓ | |

## Install

Download `DisplayMonk.zip` from the [latest release](https://github.com/AlwinOvungal/Display-Monk/releases/latest),
unzip it and move **Display Monk.app** to `/Applications`.

Builds aren't signed with an Apple Developer ID, so macOS blocks the first launch ("Apple could
not verify…"). Click **Done**, then either:

- open **System Settings → Privacy & Security**, scroll to **Security** and click **Open Anyway**, or
- run `xattr -dr com.apple.quarantine "/Applications/Display Monk.app"` in Terminal.

The app lives in the menu bar (sun icon); it has no Dock icon or window.

The `displaymonk` command-line tool is attached to the same release. Put it somewhere on your `PATH`,
for example `/usr/local/bin`.

### Build from source

```sh
swift build                 # debug build
swift run DisplayMonkApp    # run the menu bar app unbundled
swift run displaymonk list  # run the CLI
scripts/bundle.sh           # universal release: build/Display Monk.app and build/displaymonk
```

### Releasing

Publish a release on GitHub with a tag like `v0.2.0`. The **Release** workflow builds the universal
app with that version and attaches `DisplayMonk.zip` and `displaymonk` to it. To rebuild the files
for an existing release, run the workflow from **Actions → Release → Run workflow** with its tag.

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
displaymonk hidpi                    # HiDPI status of the first external display
sudo displaymonk hidpi enable        # add HiDPI resolutions (restart to use them)
sudo displaymonk hidpi disable
```

`set` only writes the everyday controls (brightness, contrast, volume, mute, input) unless you
pass `--force`, and level values are capped at the maximum the monitor reports.

`-d/--display` accepts a list index, `main`, `builtin`, `external`, `id:<n>` or part of a
display name. DDC commands default to the first display with a DDC connection, and the others
default to the main display.

Software dimming only lasts while the process that set it is running (macOS restores gamma
tables when it exits), so it is only offered in the app.

## HiDPI on external displays

Apple Silicon Macs don't offer sharp HiDPI ("Retina") sizes for most sub-4K monitors. Turn on
**High Resolution (HiDPI)** for a display and it takes effect **immediately**, with no password
and no restart. Then pick a size from the **Resolution** dropdown.

HiDPI starts at **1600 × 900** on 2K (2560×1440) and other 16:9 monitors up to 3200 pixels wide.
On 4K monitors, where 1600 × 900 would be blurry, it starts at the size matching Apple's own
displays (about 110 points per inch, e.g. 2560 × 1440 on a 27" 4K). Your last choice is
remembered and takes precedence.

How it works:

- **Right away:** a HiDPI virtual screen renders the desktop and your display mirrors it. This
  works on every Mac, including M4/M5, but only while Display Monk is running.
- **Optionally permanent:** the **…** menu next to the switch has **Make HiDPI Permanent…**. It
  adds the HiDPI sizes to macOS's own configuration for that display model (in
  `/Library/Displays/Contents/Resources/Overrides/`) and needs your administrator password. You
  never have to restart for it: after your next normal restart, Display Monk switches from the
  virtual screen to native HiDPI when it starts, and from then on HiDPI works without the app.
  If another app (for example BetterDisplay) already configured the display, its settings are
  kept and a backup is restored when you remove permanent HiDPI.

Both only change how the desktop is rendered and scaled. The monitor keeps getting its normal
native signal and refresh rate, and no EDID is overridden. The display is never switched off or
reconnected. HiDPI renders twice the pixels, so it uses somewhat more graphics power (as Apple's
own Retina modes do).

To undo it, turn the switch off. To remove the permanent configuration, use **…** → **Remove
Permanent HiDPI…** (or `sudo displaymonk hidpi disable`); its sizes disappear after the next
restart. If you ever need to recover by hand, delete the display's file under
`/Library/Displays/Contents/Resources/Overrides/` and restart.

## Arranging displays

With more than one display connected, each external display has a **Position** dropdown
(Left of / Right of / Above / Below the MacBook) and an **Align** dropdown (Top / Center / Bottom,
or Left / Center / Right). **Set as Main** moves the menu bar and Dock to that display. Only the
desktop layout changes. Positions dragged in System Settings that don't match a preset show
as "Custom position".

## Brightness down to black

With **Combined** brightness (the default for monitors with DDC and Apple displays), the top
three quarters of the slider control the real backlight. The bottom quarter dims the image in
software once the backlight is at its minimum, all the way to black. The on-screen display shows
"Min HW" in that range. Software dimming only changes the gamma table, so macOS undoes it when
Display Monk quits. Turn Combined off in the display's brightness menu (Native/DDC).

## Safety and battery

- **No polling:** the app does nothing while idle. Values are re-read only at launch, after
  displays change, and when you open the menu.
- **Gentle on monitors:** repeated identical DDC writes are skipped and writes are spaced at
  least 100 ms apart. Nothing is sent while displays sleep or for 2 s after they wake. The menu
  only sends everyday controls, always within the monitor's reported range.
- **Reversible changes:** a refresh rate change, a change to a non-native unscaled size, or a
  rotation must be confirmed within 15 seconds or it reverts. HiDPI sizes and virtual-screen
  sizes only change rendering, so they apply without a prompt.

## Permissions

- **Accessibility** is needed only if you turn on the brightness or volume key options. macOS
  will ask when you enable them (System Settings → Privacy & Security → Accessibility).
- **After updating Display Monk**, macOS silently stops trusting the new copy even though the
  Accessibility switch still looks on. The menu shows a warning when this happens. Select
  Display Monk in the Accessibility list, remove it with **–**, then add it again with **+**.
- Brightness keys work for the external display under the pointer. Over the MacBook's own
  screen they keep controlling it as usual.
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
| HiDPI (install) | A display override plist with `scale-resolutions` entries (framebuffer width and height at 2× plus a HiDPI flag), written with administrator rights |
| HiDPI (virtual screen) | A `CGVirtualDisplay` with HiDPI modes, mirrored to the physical display with `CGConfigureDisplayMirrorOfDisplay` |
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
Resources                 Info.plist, AppIcon.svg/.icns, MenuBarIcon.svg
scripts                   bundle.sh (builds the .app), make-icons.py (regenerates AppIcon.icns)
```

The menu bar icon is drawn in code from the paths in `Resources/MenuBarIcon.svg`
(`Sources/DisplayMonkApp/MenuBarIcon.swift`). After editing `Resources/AppIcon.svg`, run
`pip install cairosvg pillow && python3 scripts/make-icons.py` to rebuild `AppIcon.icns`.

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
7. Drag brightness to 0 on an external monitor: the backlight reaches its minimum, then the
   image fades to black. Quit the app and it comes back.
8. Turn on HiDPI: it applies instantly at 2560 × 1440 HiDPI on a 27" QHD monitor, and the
   Resolution dropdown lists the other HiDPI sizes. Optionally make it permanent; after a
   restart the same size comes back natively.
9. With the brightness key option on and the pointer on the external display, the brightness
   keys change it and show the popup.
10. Position the external display Left of the MacBook with Bottom alignment and check the mouse
    crosses over there; Set as Main moves the menu bar.
11. Leave the menu closed for a minute: Activity Monitor shows about 0% CPU for Display Monk.

## Acknowledgements

The DDC techniques here are well established in the open-source community. Thanks to
[MonitorControl](https://github.com/MonitorControl/MonitorControl),
[m1ddc](https://github.com/waydabber/m1ddc) and
[displayplacer](https://github.com/jakehilborn/displayplacer),
[DeskPad](https://github.com/Stengo/DeskPad) and [Acuity](https://github.com/paulhkang94/acuity)
(all MIT-licensed), whose published work documents the Apple Silicon DDC path, display
matching, rotation, virtual displays and the display override format.

Display Monk is an independent project and is not affiliated with BetterDisplay or its developer.

## License

MIT. See [LICENSE](LICENSE).
