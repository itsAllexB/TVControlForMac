// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Hidden command-line mode for diagnostics: exercises the exact production services
/// without the UI. Not shown in any help; used for development and troubleshooting.
/// The LG commands and `--osd-preview` are here; the rest live in `AtvCli` (Google TV),
/// `AdbCli` (ADB brightness), `UpdateCli` (updates) and `SelfTestCli`.
/// docs/development.md lists them all.
///
///   TVControlForMac --scan                 discover TVs on the LAN
///   TVControlForMac --probe <host>         LG: connect, pair (stored key if known), report state
///   TVControlForMac --set <host> <0-100>   LG: connect, pair, set OLED Light
///   TVControlForMac --osd-preview [options] ask the running app to show the OSD (see OsdTestRequest)
enum CliMode {
    static var isRequested: Bool {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return false }
        // Any other "--flag" is CLI mode too (and gets told it's unknown): a mistyped
        // diagnostics command must not start the whole app instead.
        return args[1].hasPrefix("--") && !appFlags.contains(args[1])
    }

    /// Flags the app itself takes when it's launched normally.
    private static let appFlags: Set<String> = ["--page", AppInfo.updatedArg, AppInfo.backgroundArg]

    private static func isKnown(_ flag: String) -> Bool {
        ["--scan", "--probe", "--set", "--mac", "--raw", "--osd-preview"].contains(flag)
            || AtvCli.commands.contains(flag)
            || AdbCli.commands.contains(flag)
            || UpdateCli.commands.contains(flag)
            || SelfTestCli.commands.contains(flag)
            || FakeTvCli.commands.contains(flag)
    }

    static func runIfRequested() async -> Bool {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return false }
        guard isKnown(args[1]) else {
            print("Unknown option \(args[1]).")
            exit(2)
        }

        let extra = Array(args.dropFirst())
        if AtvCli.commands.contains(args[1]) { await AtvCli.run(extra); return true }
        if AdbCli.commands.contains(args[1]) { await AdbCli.run(extra); return true }
        if UpdateCli.commands.contains(args[1]) { await UpdateCli.run(extra); return true }
        if SelfTestCli.commands.contains(args[1]) { await SelfTestCli.run(extra); return true }
        if FakeTvCli.commands.contains(args[1]) { await FakeTvCli.run(extra); return true }

        switch args[1] {
        case "--scan":
            print("Scanning for TVs (about 4 s)…")
            let tvs = await SsdpDiscovery.findTvs { tv in
                print("  found: \(tv.name)  \(tv.host)  \(tv.model)  [\(tv.kind.label)]")
            }
            print("\(tvs.count) TV(s) found.")
            return true

        case "--probe" where args.count >= 3:
            await probe(host: args[2], setValue: nil)
            return true

        case "--set" where args.count >= 4:
            await probe(host: args[2], setValue: Int(args[3]))
            return true

        case "--mac" where args.count >= 3:
            print(WakeOnLan.tryResolveMac(host: args[2]) ?? "MAC not resolved")
            return true

        case "--raw" where args.count >= 4:
            await raw(host: args[2], uri: args[3])
            return true

        case "--osd-preview":
            // Asks a RUNNING TVControlForMac app to show the OSD (test/debug hook). With no
            // options it shows the regular Preview (the active TV, its current settings);
            // options turn it into a scripted OSD test that bypasses TVs and settings.
            let options = Array(args.dropFirst(2))
            if options.isEmpty {
                DistributedNotificationCenter.default().post(
                    name: .init("com.itsallexb.TVControlForMac.osd-preview"), object: nil)
            } else {
                guard let request = OsdTestRequest(arguments: options) else {
                    print(OsdTestRequest.usage)
                    return true
                }
                DistributedNotificationCenter.default().postNotificationName(
                    OsdTestRequest.notification, object: nil, userInfo: request.userInfo,
                    deliverImmediately: true)
            }
            try? await Task.sleep(nanoseconds: 300_000_000) // let the notification deliver
            print("preview requested")
            return true

        default:
            return false
        }
    }

    private static func raw(host: String, uri: String) async {
        let store = DeviceStore()
        let device = store.loadDevices().first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
        guard let device, !device.clientKey.isEmpty else {
            print("host not paired yet — run --probe first")
            return
        }
        let client = WebOSClient(host: host)
        do {
            try await client.connect(port: device.secure ? 3001 : 3000, secure: device.secure)
            _ = try await client.register(clientKey: device.clientKey)
            let resp = try await client.request(uri, timeout: 5)
            let data = try JSONSerialization.data(withJSONObject: resp, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("error: \(error.localizedDescription)")
        }
        client.dispose()
    }

    private static func probe(host: String, setValue: Int?) async {
        // Reuse a stored client key when this host is already added in the app.
        let store = DeviceStore()
        let devices = store.loadDevices()
        let known = devices.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
        let device = known ?? TvDevice(name: "probe", host: host)

        let controller = WebOsController(device: device)
        let done = AsyncStream<Bool>.makeStream()

        controller.onStatusChanged = { status, message in
            switch status {
            case .connecting: print("connecting to \(host)…")
            case .awaitingPairing: print("PAIRING: accept the prompt on the TV now")
            case .connected:
                print("connected (\(device.secure ? "wss:3001" : "ws:3000"))")
                done.continuation.yield(true)
            case .error: print("error: \(message ?? "?")"); done.continuation.yield(false)
            case .disconnected, .needsPairing, .awaitingCode: break
            }
        }
        controller.onBacklightReported = { value in print("backlight = \(value)") }
        controller.onPowerStateReported = { state in print("powerState = \(state)") }
        controller.onDeviceChanged = {
            print("client-key = \(device.clientKey.isEmpty ? "(none)" : "(set)")  mac = \(device.macAddress)")
            if known != nil { store.saveDevices(devices) } // persist re-pair for the app
        }

        controller.start()

        var ok = false
        for await result in done.stream { ok = result; break }
        guard ok else { controller.dispose(); return }

        if let value = setValue {
            print("setting backlight to \(value)…")
            controller.setBacklight(value)
            try? await Task.sleep(nanoseconds: 1_500_000_000) // let the debounced write land
        } else {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // let MAC/power-state reports arrive
        }

        controller.dispose()
        print("done.")
    }
}
