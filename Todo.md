# TVControlForMac TODO

Ideas and next steps after **v3.0**.

## Distribution & polish
- [x] **App icon**: a designed TV icon with a sunset glow and ⌘ on the screen, the Mac
      sibling of the Windows icon.
- [ ] **Notarization** (Developer ID): ends the first-launch block, and the Local Network
      permission being asked again whenever the signature changes.
- [x] **Release files**: `build.sh release --package` writes the dmg and the zip.
- [x] **Automatic updates**: daily check against GitHub releases, installed in the
      background when the app can replace itself (Settings → Updates).
- [x] **Renamed** from LGforMac to TVControlForMac. Data carries over on first run, and a
      running LGforMac is closed.
- [x] README rewritten for end users, `docs/development.md`, `CONTRIBUTING.md`. Licence is
      now AGPL-3.0-or-later.
- [ ] **GitHub repository renamed** to TVControlForMac and the first 3.0 release cut.
- [ ] **Screenshots** of the Mac app for the README (`docs/images/`).

## Features
- [x] **SSDP auto-discovery**: finds LG and Google TVs on the network.
- [x] **Power automation**: turn the TVs on and off with the Mac (login, wake, sleep,
      shutdown, display sleep).
- [x] **Google TV / Android TV** (TCL, Sony, Philips…): discovery, code pairing, power on
      and off over the Android TV Remote protocol. Ported from the Windows version.
- [x] **Brightness on TCL Google TVs**: over ADB, through TCL's `tcl_tv_display` service.
- [ ] **Brightness on other Google TV brands** (Sony, Philips, Hisense…): each keeps its
      picture controls somewhere different. The recipe that found TCL's: record
      `adb logcat` while moving the TV's own brightness slider, then look for the service
      call behind it.
- [ ] **More brands**: Samsung (Tizen), Roku, Fire TV, Vizio each need their own driver
      behind `TvController`.
- [ ] **Extra picture sliders**: contrast, black level, energy saving (OLED brightness
      limiter). Same luna call as the backlight.
- [ ] **Sunrise and sunset**: schedule brightness to the sun instead of fixed clock times.
- [x] **Per-TV schedule targeting**: each schedule picks its TVs, or all of them.
- [x] **Per-TV power rules**: a TV follows the shared rules or has its own.
- [x] **Shortcut target**: the TV under the pointer, all TVs, or one fixed TV.
- [x] **Linked displays**: each TV knows its display, **Identify Displays** shows which is
      which, and **Automate only while connected** leaves a TV alone while a MacBook is
      away from it.
- [ ] **Scheduled power**: turn a TV off or on at a set time, alongside brightness
      schedules.

## Not yet tested on real hardware
- [ ] **Google TV from the Mac**: pairing, power, and TCL brightness over ADB (so far
      tested only with the Windows version, on a TCL 65C765).
- [ ] **Wake-on-LAN** end to end, for LG and Google TV.
- [ ] **Power automation** live: off on sleep, off on shutdown, display sleep (screen off
      and turn off), on when the displays wake.
- [ ] **Launch at login**, including the "At login, show" choice.
- [ ] **Schedules** firing on the minute, and catching up after sleep.
- [ ] **Updates** end to end, from a real release: in-place install and the "Install" wait.
- [ ] **Importing a TVControlForWin backup** with a Google TV in it.

## On-screen display: make the macOS style truly native

The macOS style is a real `NSGlassEffectView` capsule below the menu bar (name row,
dotted track, sun icons, full-capsule corners), but it still doesn't pass for the system
volume and brightness pop-up. Known gaps and leads:

- [ ] **Tone and contrast**: the system pop-up is a darker, luminance-adaptive glass with
      a **white** fill in both appearances. Ours follows the app's appearance (`.primary`
      content on plain `.regular` glass), so it renders light on light on bright
      wallpapers. Leads: BetterDisplay ships "adaptive vs system appearance" glass styles
      for exactly this reason (their adaptive style is limited to about 63 px height,
      which suggests a constrained system variant). Look at `NSGlassEffectView` tinting, a
      forced dark appearance on the panel, or private glass variants.
- [ ] **Entrance and exit animation**: the system's spring and timing differ from our
      linear slide and fade. Capture it (screen recording, frame by frame) and match.
- [ ] **Exact metrics**: measure the real pop-up (width, insets, font, track thickness,
      dot spacing, icon sizes, shadow) from 2x screenshots and match them.
- [ ] **Slider knob**: check whether the system pop-up shows a knob at the fill edge.
- [ ] Check whether the private `OSDManager` / `OSDUIHelper` path does anything useful on
      macOS 26 and 27. In a normal app it summons the Control Center pop-up (per
      MonitorControl), but the value bar reportedly doesn't follow. Retest from the app,
      not a sandboxed command-line run, where the XPC lookup was denied.

## Updater hardening
- [ ] Limit how much a release zip may unpack to, so a hostile release can't fill the disk
      before the signature is checked.
- [ ] Remember a release that failed its checks, instead of downloading it again each day,
      and point to the download page for it.
- [ ] If the app takes more than a minute to quit, the swap helper gives up without
      restarting it. Start the old version again in that case.
- [ ] A swap inside `/Applications` under macOS's App Management protection is untested.
- [ ] A way to move to a new signing certificate (Developer ID) without stranding copies
      signed with the current one.

## Maybe / later
- [ ] Show a TV's power state in the menu bar icon, as well as on the Home page.
- [ ] Optional per-TV shortcuts, in addition to the pointer targeting.
