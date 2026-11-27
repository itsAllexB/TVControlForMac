# Developing TVControlForMac

A native Mac app in Swift (SwiftUI and AppKit), built with Swift Package Manager into a
plain app bundle. It has no third-party dependencies. This page covers building it, how it
talks to each kind of TV, where things live, and how a release is made.

- [Building](#building)
- [Signing](#signing)
- [Trying a build without touching your real setup](#trying-a-build-without-touching-your-real-setup)
- [Diagnostics from the command line](#diagnostics-from-the-command-line)
- [How it talks to the TV](#how-it-talks-to-the-tv)
- [The Local Network permission](#the-local-network-permission)
- [Adding a TV brand](#adding-a-tv-brand)
- [Project layout](#project-layout)
- [Updates](#updates)
- [Making a release](#making-a-release)

## Building

**You need** macOS 14 or newer and Xcode, or only the Command Line Tools
(`xcode-select --install`).

**Build and run**

```bash
./build.sh debug --run
```

| Command | What it does |
|---|---|
| `./build.sh` | Release build into `dist/TVControlForMac.app` |
| `./build.sh debug` | Debug build |
| `./build.sh release --run` | Release build, then opens it |
| `./build.sh release --package` | Release build, plus the release zip and dmg in `dist/`, with their SHA-256 |

The script builds with SwiftPM, puts the binary, `Support/Info.plist` and
`Support/AppIcon.icns` together into `dist/TVControlForMac.app`, and signs it. A release
build runs on Apple silicon and Intel; a debug build is for the Mac it was built on.
`swift build` on its own gives you the bare binary in `.build/`, which is enough for the
[command-line diagnostics](#diagnostics-from-the-command-line) but isn't an app. To edit in
Xcode, open `Package.swift`.

Always look at the app as `build.sh` built it. SwiftPM records the deployment target
(macOS 14) in the binary as the SDK it was built with, and macOS 26 and later then draw
the app the old way: no Liquid Glass, a flat sidebar, the old toolbar and controls.
`build.sh` passes the linker the real SDK version and stops if the binary doesn't record
it. `vtool -show-build <binary>` shows what a binary says.

## Signing

`build.sh` signs the app with the certificate named in `SIGN_IDENTITY` if that's set.
Otherwise it uses **LGforMac Local Signing** if your keychain has it (the certificate
releases are signed with, from when the app had that name), then
**TVControlForMac Local Signing**, and ad hoc as a last resort.

That matters because macOS ties the Local Network permission to the app's signing
identity, and so does the updater's same-signer check. An ad-hoc signature is a new
identity on every build, so each build may have to be allowed on the local network again.
A self-signed certificate keeps one identity across builds. To make one:

1. Open **Keychain Access** and choose
   **Keychain Access → Certificate Assistant → Create a Certificate…**.
2. Name it `TVControlForMac Local Signing`, set **Identity Type** to **Self-Signed Root**
   and **Certificate Type** to **Code Signing**, and select **Create**.
3. Run `security find-identity -p codesigning` to check it's there. It's listed as not
   trusted, which doesn't stop `codesign` from using it.

The first build that uses it may ask for access to the key. Choose **Always Allow**.

## Trying a build without touching your real setup

The app keeps its data in `~/Library/Application Support/TVControlForMac`, and only one
copy runs per data folder. To run a second copy on throwaway data next to the one you use:

```bash
TVCONTROL_DATA_DIR=/tmp/tvcontrol-trial \
  dist/TVControlForMac.app/Contents/MacOS/TVControlForMac --page power
```

A copy started this way leaves the login item alone, doesn't check for updates by itself,
and doesn't close a copy that's already running. `--page` opens straight on `home`,
`schedule`, `power`, `hotkeys` (the Keyboard Shortcut page), `osd` or `settings`.

## Diagnostics from the command line

The binary doubles as a test tool: given one of these as its first argument, it runs the
app's own services without a window, prints what happens and exits.

```bash
swift build
.build/debug/TVControlForMac --scan
```

| Command | What it does |
|---|---|
| `--scan` | Searches the network for TVs (about 4 seconds) |
| `--probe <ip>` | Connects to an LG, pairing if needed, and reports its state |
| `--set <ip> <0-100>` | Sets an LG's brightness |
| `--raw <ip> <ssap-uri>` | Sends one SSAP request to a paired LG and prints the answer |
| `--mac <ip>` | Looks up a TV's MAC address in the ARP cache |
| `--osd-preview` | Asks the running app to show the on-screen display |
| `--atv-pair <ip>` | Pairs with a Google TV (type the code it shows) |
| `--atv-probe <ip> [seconds]` | Connects to a paired Google TV and reports its state |
| `--atv-power <ip> on\|off\|toggle` | Switches a Google TV on or off |
| `--atv-unpaired <ip>` | Connects with a certificate the TV doesn't know and prints how it refuses |
| `--atv-pfx-new <file>`, `--atv-pfx-read <file>` | Writes a new pairing certificate; reads one from a `.p12`, base64 text or a settings backup |
| `--adb-setup <ip>` | Sets up brightness over ADB (approve it on the TV) |
| `--adb-get <ip>` | Reads the brightness over ADB |
| `--adb-set <ip> <0-100>` | Sets the brightness over ADB |
| `--adb-shell <ip> <command>` | Runs one shell command on the TV over ADB |
| `--adb-key new\|pub\|roundtrip\|sign` | Makes and checks ADB keys, for comparing with `openssl` and `adb` |
| `--update-check` | Asks GitHub for the latest release and says what the updater would do |
| `--update-kind [app]`, `--update-signature [app]` | Whether a copy can replace itself, and who signed it |
| `--update-verify <zip> <version>` | Runs the updater's checks on a release zip |
| `--update-download` | Downloads and checks the latest release (trial runs only) |
| `--selftest`, `--atv-selftest`, `--adb-selftest`, `--update-selftest` | Offline self-tests; no TV or network needed |
| `--fake-tv [options]` | Stand-in TVs on 127.0.0.1 for trying the app's screens: a Google TV (6466/6467) with a TCL-style `adbd` (5555), and with `lg` an LG (3000). Commands typed on its stdin (`standby`, `wake`, `drop`, `forget`, `adb-forget`, `status`…) change what it does; `CliFakeTv.swift` lists them all |

An option the binary doesn't know is refused, so a typo never starts the app.

The commands use the TVs and pairing in the app's data folder, so `TVCONTROL_DATA_DIR`
applies to them too. A binary started from Terminal uses Terminal's Local Network
permission, not the app's, so a command can reach a TV that the app can't.

## How it talks to the TV

### LG webOS

webOS speaks **SSAP over a WebSocket**: `wss://<tv>:3001` on 2022 and newer models,
`ws://<tv>:3000` on older ones. The app tries whichever worked last time first.

1. **Pair.** A registration handshake makes the TV show an accept prompt and return a
   `client-key`, which is saved and reused so it never prompts again.
2. **Set brightness.** The `luna://com.webos.settingsservice/setSystemSettings` call with
   `{ "category": "picture", "settings": { "backlight": "<0-100>" } }`. A normal SSAP client
   isn't allowed to make it directly, so it goes through the notification API:
   `ssap://system.notifications/createAlert` creates an alert whose button and close action
   carry the call, and `closeAlert` closes it, which makes the TV run it. This works on
   stock, unrooted TVs.
3. **Read brightness.** `ssap://settings/getSystemSettings`.
4. **Power.** `ssap://system/turnOff`, and `…tvpower/power/turnOffScreen` / `turnOnScreen`
   to blank and restore only the panel. `…tvpower/power/getPowerState` reports `Active`,
   `Screen Off` or `Suspend`, and doubles as a liveness probe: a TV that loses power
   doesn't close the WebSocket, so without asking, the app would keep saying "connected".
5. **Wake.** A TV that's off can't be reached over SSAP, so waking is a Wake-on-LAN packet.
   The MAC addresses come from the TV itself while it's reachable
   (`ssap://com.webos.service.connectionmanager/getinfo`, both Wi-Fi and wired), and the
   packet goes to each. The ARP cache is the fallback, for firmware without `getinfo`;
   macOS doesn't always let an app read it.

References: bscpylgtv, ColorControl, lgtv2.

### Google TV / Android TV

These speak the **Android TV Remote protocol v2**: protobuf messages over TLS, the same
thing Google's phone remote uses. The TLS connections go through Network.framework.

1. **Pair** (port 6467). The app makes a self-signed client certificate and connects with
   it, and the TV shows a 6-character code. The app answers with a SHA-256 over both
   certificates' public keys plus the code. From then on the TV trusts that certificate,
   which is saved with the TV as PKCS#12. The Windows version stores it the same way,
   which is why a backup moves between the two with its pairing intact.
2. **Control** (port 6466). The TV reports whether it's on or in standby, and pings every
   few seconds; silence means the connection is dead. Power is `KEYCODE_POWER`, a *toggle*,
   so it's only sent when the TV's reported state says which way it will go.
3. **Wake.** The power key if the TV kept its connection in standby, plus Wake-on-LAN for
   the ones that didn't. The MAC address is learned over ADB once brightness is set up,
   or from the ARP cache.

No developer mode is needed for pairing and power. Reference: tronikos/androidtvremote2.

### Brightness on TCL Google TVs (ADB)

The remote protocol carries no picture settings, and Android's own display-brightness
setting does nothing on these sets. The panel is driven by TCL's picture pipeline, behind
a system service called `tcl_tv_display`. The TV's own slider calls
`setBacklight(applyType, value, actType)` on it (binder transaction 100; `getBacklight()`
is 101), and an ADB shell can make the same call:

```
service call tcl_tv_display 100 i32 1 i32 <0-100> i32 2
```

The app speaks ADB itself (`Services/AdbClient.swift`: the TCP protocol, RSA
authentication, one shell command at a time), so nothing extra is installed. The key the
TV approved is saved with the TV.

Those transaction numbers are positions in TCL's interface and could differ on another
firmware. So the app checks the service's interface name, checks that the value it reads
is a plausible 0 to 100, and reads the first write of each connection back. If that
doesn't match, brightness is switched off for that TV rather than risk calling something
else. Worked out and tested on a 65C765 (Android 14) with the Windows version.

## The Local Network permission

macOS asks once whether the app may find devices on the local network (the text comes from
`NSLocalNetworkUsageDescription` in `Support/Info.plist`). While that's denied, every
connection to a TV fails, with `NSURLErrorDomain -1009` ("the Internet connection appears
to be offline") for the WebSocket.

On recent macOS (26 and later) the prompt sometimes never appears: the app is blocked
silently and isn't even listed under **System Settings → Privacy & Security → Local
Network**. A plain `URLSession` connection doesn't make macOS register the app, but
Network.framework does. So after three failed connection attempts in a row
(`AppState.noteConnectOutcome`), the app sends an SSDP search, starts a Bonjour browse and
opens an `NWConnection` to the first TV, which brings the prompt up. The Home page then
shows **Can't reach your TVs**, with **Ask Again** (the same probes) and
**Open Settings**, and the menu bar pop-up points there.

Keep in mind while developing that the permission belongs to the signing identity (see
[Signing](#signing)).

## Adding a TV brand

Every TV is driven through the `TvController` protocol (`Services/TvController.swift`):
status, pairing, power, brightness. The rest of the app doesn't know which brand it's
talking to.

- **A new kind of TV** (its own protocol): add a `TvKind` (`Models/Models.swift`),
  implement `TvController`, and teach `TvControllerFactory` to create it and to recognise
  it by the ports it listens on. `SsdpDiscovery` finds TVs on the network.
- **Brightness for another Google TV brand**: the connection, setup and safety net already
  exist in `AdbBrightness`. What's missing is that brand's equivalent of
  `AdbTclBacklight`: how to read and set the backlight from an ADB shell. `adb logcat`
  while moving the TV's own brightness slider is how the TCL call was found.

Whatever you add, read values back before trusting a write. A call that "succeeds" is not
the same as a panel that changed.

`TvKind` values and the JSON keys in `Models/Models.swift` are shared with the Windows
version, so backups stay interchangeable. Add the same kind with the same number on both.

## Project layout

Source paths are under `Sources/TVControlForMac/`.

| Path | Purpose |
|------|---------|
| `Services/TvController.swift`, `TvControllerFactory.swift` | What every TV driver offers; creating the right one, and brand detection |
| `Services/WebOSClient.swift`, `WebOsController.swift`, `SsapPayloads.swift` | LG: the WebSocket, and per-TV lifecycle, reconnect, power, brightness |
| `Services/AndroidTvRemoteClient.swift`, `AndroidTvController.swift`, `AndroidTvIdentity.swift`, `Pkcs12.swift`, `ProtoWire.swift` | Google TV: TLS, the client certificate and its PKCS#12 form, code pairing, the remote connection, power |
| `Services/AdbClient.swift`, `AdbBrightness.swift`, `AdbTclBacklight.swift` | Google TV brightness over ADB |
| `Services/RuleTargets.swift` | Which TVs a schedule, power rule or hotkey applies to (pure logic) |
| `Services/ScheduleService.swift`, `PowerEventService.swift`, `HotkeyService.swift` | Schedules, the Mac's sleep, wake, display and shutdown events, global hotkeys |
| `Services/SsdpDiscovery.swift`, `WakeOnLan.swift`, `ScreenService.swift` | Finding TVs, waking them, matching them to displays |
| `Services/UpdateService.swift`, `AppInfo.swift` | Finding, verifying and installing app updates; the app's name, version and repository |
| `Services/DeviceStore.swift`, `AppPaths.swift` | Settings as JSON in the data folder, the log, and carrying LGforMac's data over |
| `Services/AutostartService.swift` | Launch at login (`SMAppService`) |
| `Models/Models.swift` | `TvDevice`, `AppSettings` and the rest of what's saved |
| `App/TVControlForMacApp.swift` | Start-up, single instance, the menu bar item, the window |
| `App/AppState.swift`, `TvState.swift` | What the UI shows and does, for the app and for each TV |
| `App/UpdateManager.swift` | When to check for updates, and installing them |
| `App/CliMode.swift`, `CliAndroidTv.swift`, `CliAdb.swift`, `CliUpdate.swift`, `CliSelfTest.swift`, `CliFakeTv.swift` | The command-line diagnostics, self-tests and stand-in TVs |
| `UI/` | The window and its six pages, the menu bar pop-up, the on-screen display, Identify Displays, shared rows and the "i" button (`Components.swift`), the updates section |
| `Support/Info.plist`, `Support/AppIcon.icns` | The bundle's settings, and the app icon (designed art, committed as is) |
| `build.sh` | Build script |

## Updates

`UpdateService` asks GitHub for the repository's latest release (drafts and pre-releases
don't count). An update is only installed if:

- the release has a file named exactly `TVControlForMac-<version>.zip`,
- it comes from the repository's release downloads over HTTPS,
- it matches the size and SHA-256 hash GitHub lists for it, and
- the app inside has the bundle id `com.itsallexb.TVControlForMac`, the version the
  release is for, and a valid signature, made by the same signer as the running app when
  that app is signed with a certificate.

What that adds up to: the download checks (name, address, size, hash) only protect the
file on its way here. Whoever can publish a release on the repository decides what they
say. The signer check is what protects a copy signed with a certificate: an update has to
be signed with that same certificate, so a release from anyone without its key is refused.
A copy signed ad hoc has no such check, because every ad-hoc build is a different signer;
it trusts the GitHub repository and the connection to it, and nothing else.

Only a copy that can replace itself installs: one in a folder the user can write to, not
run from the disk image or from where it was downloaded (macOS runs such a copy from a
read-only location). Others say there's a new version and open the release page. After
installing, the new version starts with `--updated` (and `--background` when the update
went in unattended, so it comes back without its window). A build in `dist/` of its own
source checkout never updates itself.

**Rehearsing an update** without publishing anything: a trial run (see above) accepts
`TVCONTROL_UPDATE_FEED` (the address of a stand-in for GitHub's "latest release" answer)
and `TVCONTROL_INSTALL_KIND` (`SelfUpdating`, `Manual` or `None`: which kind of copy to
behave as; without it a rehearsal behaves as `Manual`). `TVCONTROL_UPDATE_HELPER_FAIL`
(`move-aside`, `move-new`, `verify` or `launch`) makes that step of the swap fail, to
watch the old version come back. All are ignored unless `TVCONTROL_DATA_DIR` is set too.

## Making a release

1. In `Support/Info.plist`, set `CFBundleShortVersionString` (for example `3.0.1`) and
   raise `CFBundleVersion`.
2. `./build.sh release --package`
3. Publish a GitHub release tagged `v<version>` (for example `v3.0.1`) with both files
   from `dist/`, named exactly as the build wrote them. The updater looks for the zip's
   name.

The version has two or three parts (`3.1`, `3.0.1`); the updater doesn't read a fourth.
`--package` checks the zip the way the updater will (`--update-verify`) and removes the
release files again if a check fails. It refuses to package an ad-hoc signed build unless
`ALLOW_ADHOC_RELEASE=1` is set.

Sign every release with the same certificate, and keep a backup of its private key.
Copies signed with it refuse an update signed by anyone else, so without the key they
could never update themselves again. To try the updater, rehearse it as above rather than publishing a
test release: every copy out there installs whatever the latest release is.
