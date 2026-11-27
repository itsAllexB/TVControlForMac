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
- [x] **Screenshots** of the Mac app for the README (`docs/images/`). Retake the Home
      one with an LG and a Google TV both connected.

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
- [x] **Google TV from the Mac**, on a TCL 65C765 (Android 14): code pairing, the paired
      connection, power off and on, brightness over ADB with read-back, and the MAC address
      learned over ADB. Done from the command-line diagnostics; the same in the app's
      window has only been driven against the fake TV (`--fake-tv`).
- [ ] **Wake-on-LAN** end to end for LG. (The TCL came back from standby with the magic
      packet and the power key both sent.)
- [ ] **Power automation** live: off on sleep, off on shutdown, display sleep (screen off
      and turn off), on when the displays wake.
- [ ] **Launch at login**, including the "At login, show" choice.
- [ ] **Schedules** firing on the minute, and catching up after sleep.
- [ ] **Updates** end to end, from a real release: in-place install and the "Install" wait.
- [ ] **Importing a TVControlForWin backup** with a Google TV in it.

## On-screen display: the macOS style

Redrawn in 3.0 to the system volume pop-up's measured geometry on macOS 27 (a 308 × 66 pt
Liquid Glass capsule hanging below the menu bar), with its entrance and exit timed against
screen recordings. The level has 10 segments, one per 10 %, where the system's has 16: on
purpose, so 10 % steps fill whole segments. Each style now keeps its own panel, which is
what fixed the pop-up sometimes appearing empty.

- [x] Tone, metrics, the segmented level and the animation match the system pop-up over
      neutral backgrounds (within a few levels per pixel).
- [x] The private `OSDManager` / `OSDUIHelper` route is a dead end: on macOS 27 it draws
      the old square pop-up at the bottom of the screen, and the new capsule belongs to
      `MenuBarAgent`, which needs entitlements an app like this can't have.
- [ ] Over saturated colours the system boosts what's behind the glass more than ours
      does, and bends it more while the pop-up scales in.
- [ ] Check the sun glyph against the system's own brightness pop-up (needs BetterDisplay
      or any other brightness-key app switched off while comparing).
- [ ] Compare against the system pop-up with macOS in dark mode.
- [ ] On macOS 14 and 15 it falls back to a dark material capsule; untested there.

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

## From the reviews, still open
- [ ] **LG pairing prompt**: an LG without a stored key shows its accept prompt at every
      app start, and again every few seconds after a decline. It should say "Not paired"
      with a **Pair** button and only show the prompt when asked, as Google TVs do.
- [ ] Windows-style on-screen display: a second show within its 0.25 s entrance may not
      resize the pill, and its shadow may be stale after a size change (unconfirmed).
- [ ] `--osd-preview --theme` and `--anchor fallback` stick until the app restarts.

## Maybe / later
- [ ] Show a TV's power state in the menu bar icon, as well as on the Home page.
- [ ] Optional per-TV shortcuts, in addition to the pointer targeting.
