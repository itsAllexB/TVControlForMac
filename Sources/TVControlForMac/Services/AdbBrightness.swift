// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import SystemConfiguration

/// Brightness for one Android TV over ADB: the one-time setup, the connection, and debounced
/// writes. Owned by `AndroidTvController`, which tells it when the TV comes and goes.
///
/// ADB is a separate channel from the remote-control connection and, unlike it, has to be
/// switched on by the owner (USB debugging) and approved on the TV. So nothing here ever
/// contacts ADB with an unapproved key unless the user asked for setup — that's what would put
/// an "Allow USB debugging?" dialog on a TV nobody may be sitting at.
///
/// All work runs in tasks this object owns, so `dispose()` stops it wherever it is, whoever
/// started it.
final class AdbBrightness: @unchecked Sendable {
    private static let debounceMs = 150
    private static let commandTimeout: TimeInterval = 3
    private static let resumeAttempts = 3
    private static let resumeRetryDelay: TimeInterval = 3
    private static let approvalTimeout: TimeInterval = 90

    private static let maxRefusals = 3     // refused writes in a row before giving up on this TV
    private static let refusalRetryMs = 2000

    private let device: TvDevice
    private let deviceChanged: () -> Void
    private let tvIsOn: () -> Bool

    // One ADB conversation at a time: the client runs a single command stream.
    private let adbLock = AdbLock()
    private let gate = NSLock()
    private let debounceQueue = DispatchQueue(label: "TVControlForMac.AdbBrightness.debounce")

    private var adb: AdbClient?
    private var connecting: AdbClient? // mid-handshake, so suspend/dispose can cut it short too
    private var verified = false       // a write on this connection has been read back
    private var refusals = 0           // writes in a row the TV has turned down
    private var resumeFailed = false   // the last quiet reconnect couldn't reach ADB
    private var macLookupDone = false  // asked the TV for its MAC once; don't keep asking
    private var offeredKey: String?    // made for a setup the TV hasn't answered yet (never saved)
    private var debounceItem: DispatchWorkItem?
    private var pendingValue = 0
    private var hasPending = false
    private var writing = false        // a value taken from `pending` is still on its way
    private var disposed = false
    private var work: [UInt64: Task<Void, Never>] = [:]
    private var nextWorkId: UInt64 = 0

    // A value that couldn't be delivered because the TV was off or unreachable (typically a
    // schedule firing overnight). Pushed as soon as the TV is back.
    private var missedWhileOff: Int?

    private var currentState: BrightnessSetup = .unknown

    /// - Parameters:
    ///   - deviceChanged: called after something persisted on the device changed.
    ///   - tvIsOn: whether the TV is connected and switched on right now.
    init(device: TvDevice, deviceChanged: @escaping () -> Void, tvIsOn: @escaping () -> Bool) {
        self.device = device
        self.deviceChanged = deviceChanged
        self.tvIsOn = tvIsOn
    }

    var state: BrightnessSetup {
        gate.lock(); defer { gate.unlock() }
        return currentState
    }

    /// True when a value passed to `set` won't be lost even though brightness isn't `.ready`:
    /// the TV has approved us before, so the value is kept and delivered once ADB is back.
    /// That's how a schedule that fires while the TV is unreachable still lands.
    var holds: Bool { !device.adbKey.isEmpty && state != .unsupported }

    /// Fires whenever `state` changes (any thread).
    var onStateChanged: (() -> Void)?
    /// Fires with the TV's current brightness when it's read (any thread).
    var onReported: ((Int) -> Void)?

    private func setState(_ state: BrightnessSetup) {
        gate.lock()
        let changed = currentState != state
        currentState = state
        gate.unlock()
        if changed { onStateChanged?() }
    }

    /// The name the TV shows in its "Allow USB debugging?" dialog.
    static var keyName: String { "TVControlForMac@" + localHostName() }

    // ----- Lifecycle, driven by the controller -----

    /// The TV just connected. With a key it has already approved, reconnect quietly and read
    /// the brightness; without one, offer setup if `mightSupport` says it's worth it, and
    /// otherwise settle on `.unavailable`.
    func resume(mightSupport: Bool) async {
        await runOwned { [self] in await resumeNow(mightSupport: mightSupport) }
    }

    private func resumeNow(mightSupport: Bool) async {
        if device.adbKey.isEmpty {
            let current = state
            if current == .unknown || current == .unavailable {
                setState(mightSupport ? .offered : .unavailable)
            }
            return
        }
        setResumeFailed(false)

        // A TV that's just woken may take a few seconds to bring ADB back up.
        for attempt in 0..<Self.resumeAttempts {
            if Task.isCancelled { return }
            do {
                try await withAdbLock {
                    try await connect(key: device.adbKey, onApprovalNeeded: nil)
                    try await probe()
                }
                applyMissedIfAny()
                return
            } catch is CancellationError {
                return
            } catch let error as AdbRejection where error.needsApproval {
                // The TV forgot us (debugging authorisations revoked, or a factory reset).
                Log.write("\(device.host): ADB key no longer approved — brightness needs setting up again")
                closeConnection()
                setState(.offered)
                return
            } catch {
                if Task.isCancelled { return }
                closeConnection()
                if attempt == Self.resumeAttempts - 1 {
                    // Most likely USB debugging was switched off. Keep the key: turning it
                    // back on and running setup again won't need a new approval. In case ADB
                    // was only slow to come up, the next power-on report tries once more.
                    Log.write("\(device.host): ADB not reachable (\(error.localizedDescription)) — brightness unavailable")
                    setResumeFailed(true)
                    setState(.offered)
                    return
                }
            }

            do { try await Task.sleep(nanoseconds: UInt64(Self.resumeRetryDelay * 1_000_000_000)) }
            catch { return }
        }
    }

    /// The user asked for brightness: connect, getting the TV's approval if it doesn't know us.
    /// Every outcome lands in `state`.
    func setUp() async {
        await runOwned { [self] in await setUpNow() }
    }

    private func setUpNow() async {
        let current = state
        if current == .connecting || current == .awaitingApproval || current == .ready { return }

        // Reuse a saved key (the TV may still trust it); otherwise make one, saved only on
        // success. A key that was offered and went unanswered is kept for the next try this
        // session: if the owner selects Allow after we stopped waiting, the TV has approved
        // that key, and a new one would only put the dialog up again.
        let key: String
        if !device.adbKey.isEmpty {
            key = device.adbKey
        } else if let offered = offeredKeyNow() {
            key = offered
        } else {
            do { key = try AdbClient.createKey() }
            catch {
                Log.write("\(device.host): brightness setup failed: \(error.localizedDescription)")
                return
            }
            setOfferedKey(key)
        }

        setState(.connecting)
        do {
            try await withAdbLock {
                try await connect(key: key, onApprovalNeeded: { [weak self] in self?.setState(.awaitingApproval) })
                if device.adbKey != key {
                    device.adbKey = key
                    deviceChanged()
                }
                setOfferedKey(nil)
                try await probe()
            }

            if state == .ready {
                Log.write("\(device.host): brightness over ADB is set up")
                setResumeFailed(false)
                applyMissedIfAny()
            }
        } catch is CancellationError {
        } catch let error as AdbRejection {
            Log.write("\(device.host): brightness setup failed: \(error.localizedDescription)")
            closeConnection()
            setState(.unsupported)
        } catch {
            if Task.isCancelled { return }
            // Nobody answered the dialog → back to "offer it". Anything else at this point is
            // the connection itself failing: ADB isn't listening, i.e. debugging is off.
            let unanswered = state == .awaitingApproval
            Log.write("\(device.host): brightness setup failed: \(unanswered ? "no answer on the TV" : error.localizedDescription)")
            closeConnection()
            setState(unanswered ? .offered : .needsDebugging)
        }
    }

    private func offeredKeyNow() -> String? {
        gate.lock(); defer { gate.unlock() }
        return offeredKey
    }

    private func setOfferedKey(_ key: String?) {
        gate.lock(); defer { gate.unlock() }
        offeredKey = key
    }

    /// The TV went away (connection lost or standby): the ADB link is dead weight now.
    func suspend() {
        closeConnection()
    }

    /// The TV reported its power state; coming on is when a held value is delivered.
    func tvPowerChanged(on: Bool) {
        if !on {
            closeConnection()
        } else if resumeFailedNow() {
            Task.detached { [self] in await resume(mightSupport: true) } // delivers a held value itself
        } else {
            applyMissedIfAny()
        }
    }

    // ----- Writing -----

    /// Queues a brightness change; only the latest value within the debounce window is sent.
    func set(_ value: Int) {
        let value = max(0, min(100, value))
        gate.lock()
        pendingValue = value
        hasPending = true
        gate.unlock()
        scheduleFlush(afterMs: Self.debounceMs)
    }

    /// Sends a queued value now instead of after the debounce, and returns once it has been
    /// dealt with, refused-write retries included (at their usual spacing). For the
    /// diagnostics CLI, which has nothing else to wait on.
    func flushNow() async {
        while true {
            gate.withLock {
                debounceItem?.cancel()
                debounceItem = nil
            }
            await runOwned { [self] in await flush() }
            let retrying = gate.withLock {
                guard hasPending && !disposed else { return false }
                debounceItem?.cancel() // the retry is ours to run, not the timer's
                debounceItem = nil
                return true
            }
            if !retrying || Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.refusalRetryMs) * 1_000_000)
        }
    }

    private func scheduleFlush(afterMs delay: Int) {
        gate.lock()
        guard !disposed else { gate.unlock(); return }
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task.detached { await self.runOwned { await self.flush() } }
        }
        debounceItem = item
        gate.unlock()
        debounceQueue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: item)
    }

    private func flush() async {
        guard let value = takePending() else { return }
        defer { gate.withLock { writing = false } }

        if state != .ready {
            // Set up, but not usable at the moment (typically the TV hasn't been reachable since
            // the app started): keep the value for when it is.
            if holds { setMissed(value) }
            return
        }

        if !tvIsOn() {
            setMissed(value)
            Log.write("\(device.host): TV is off — holding brightness \(value) until it's back")
            return
        }

        do {
            try await withAdbLock {
                // An idle ADB connection can die without a trace; one reconnect covers that.
                var attempt = 0
                while true {
                    do {
                        try await write(value)
                        return
                    } catch let error where attempt == 0 && !Task.isCancelled
                                && !(error is CancellationError) && !(error is AdbRejection) {
                        closeConnection()
                        attempt += 1
                    }
                }
            }
        } catch is CancellationError {
        } catch let error as AdbRejection where error.needsApproval {
            Log.write("\(device.host): ADB key no longer approved — brightness needs setting up again")
            closeConnection()
            setState(.offered)
        } catch {
            if Task.isCancelled { return }
            closeConnection()
            setMissed(value)
            Log.write("\(device.host): brightness \(value) FAILED (\(error.localizedDescription)) — holding until the TV is back")
        }
    }

    // One write attempt, connecting first if needed. Caller holds adbLock.
    private func write(_ value: Int) async throws {
        if !(currentAdb()?.isConnected ?? false) {
            try await connect(key: device.adbKey, onApprovalNeeded: nil)
        }
        guard let adb = currentAdb() else { throw AdbConnectionError.closed }

        let verify = gate.withLock { !verified }

        let result = try await AdbTclBacklight.set(adb, value, verify: verify,
                                                   until: .now() + Self.commandTimeout)
        let refusedTooOften = gate.withLock {
            if result == .refused { refusals += 1 }
            return refusals >= Self.maxRefusals
        }

        switch result {
        case .applied:
            gate.withLock {
                verified = true
                refusals = 0
                missedWhileOff = nil
            }

        case .refused where !refusedTooOften:
            // Seen as a passing thing while the TV is still waking: keep the value and try
            // again shortly, unless a newer one has come in.
            Log.write("\(device.host): brightness \(value) refused by the TV — trying again shortly")
            let retry = gate.withLock {
                guard !hasPending else { return false }
                pendingValue = value
                hasPending = true
                return true
            }
            if retry { scheduleFlush(afterMs: Self.refusalRetryMs) }

        case .refused, .notApplied:
            // Accepted but not applied, or refused time after time: these aren't the calls
            // we think they are on this firmware. Stop writing.
            Log.write("\(device.host): brightness writes don't take — turning brightness off for this TV")
            gate.withLock { refusals = 0 }
            closeConnection()
            setState(.unsupported)
        }
    }

    private func applyMissedIfAny() {
        if state != .ready { return } // keep holding it until brightness works again

        gate.lock()
        let missed = missedWhileOff
        missedWhileOff = nil
        gate.unlock()
        guard let value = missed else { return }

        Log.write("\(device.host): TV is back — applying held brightness \(value)")
        onReported?(value) // sync the slider
        set(value)
    }

    // ----- Connection (callers hold adbLock) -----

    private func connect(key: String, onApprovalNeeded: (() -> Void)?) async throws {
        closeConnection()
        let client = AdbClient()
        let stopped = gate.withLock {
            if !disposed { connecting = client }
            return disposed
        }
        if stopped { throw CancellationError() }

        defer {
            gate.withLock { if connecting === client { connecting = nil } }
        }
        try await client.connect(host: device.host, port: AdbClient.defaultPort, keyBase64: key,
                                 keyName: Self.keyName, onApprovalNeeded: onApprovalNeeded,
                                 approvalTimeout: onApprovalNeeded == nil ? 0 : Self.approvalTimeout)

        // suspend() or dispose() while the handshake ran: they closed this client already,
        // and it mustn't come back as the live connection.
        let keep = gate.withLock {
            guard connecting === client && !disposed else { return false }
            adb = client
            verified = false
            return true
        }
        if !keep {
            client.dispose()
            throw AdbConnectionError.closed
        }
    }

    // Checks this TV has a brightness control we know, and reads its current value.
    private func probe() async throws {
        guard let adb = currentAdb() else { throw AdbConnectionError.closed }
        let deadline = DispatchTime.now() + Self.commandTimeout
        let available = try await AdbTclBacklight.isAvailable(adb, until: deadline)
        if !available {
            await learnMacIfNeeded(adb) // ADB works even where brightness doesn't
            closeConnection()
            setState(.unsupported)
            return
        }

        // Report what the TV is at before announcing ready: becoming ready is what triggers the
        // schedule catch-up, and its value has to be the one that sticks, not this reading.
        // Nor while a newer value is held, queued or being written: the TV reporting power
        // on after a reconnect hands a held value over before this read, and the slider
        // would otherwise go back to what the TV had while the TV gets the new value.
        if let current = try await AdbTclBacklight.get(adb, until: deadline),
           !gate.withLock({ hasPending || writing || missedWhileOff != nil }) {
            onReported?(current)
        }
        setState(.ready)
        await learnMacIfNeeded(adb)
    }

    private func closeConnection() {
        gate.lock()
        let live = adb
        let pending = connecting
        adb = nil
        connecting = nil
        gate.unlock()
        live?.dispose()
        pending?.dispose()
    }

    // ----- MAC address (macOS only) -----

    // On macOS the ARP table is often unreadable from a GUI app (local-network privacy), so a
    // Google TV's MAC, which Wake-on-LAN needs, may never be learned the way TVControlForWin
    // does it. With a shell on the TV we can simply ask it. Wi-Fi first, then wired, the same
    // order the LG path stores them in. A side errand: any failure is logged and dropped, and
    // it never stands in the way of brightness (a timeout here only costs a reconnect).
    // sysfs is the plain way; `ip link` is there for firmware whose SELinux policy keeps the
    // shell out of /sys/class/net. Its "brd ff:ff:…" is dropped by parseMacs as broadcast.
    static let macCommand = "for i in wlan0 eth0; do cat /sys/class/net/$i/address 2>/dev/null"
        + " || ip link show $i 2>/dev/null | grep link/ether; done"

    private func learnMacIfNeeded(_ adb: AdbClient) async {
        let wanted = gate.withLock { !macLookupDone && device.macAddress.isEmpty && !disposed }
        guard wanted else { return }

        do {
            let output = try await adb.shell(Self.macCommand, until: .now() + Self.commandTimeout)
            gate.withLock { macLookupDone = true } // the TV answered; asking again won't change its answer

            let macs = Self.parseMacs(output)
            guard !macs.isEmpty else {
                Log.write("\(device.host): no MAC address in the TV's answer")
                return
            }
            guard device.macAddress.isEmpty else { return }
            device.macAddress = macs.joined(separator: ",")
            Log.write("\(device.host): MAC learned over ADB \(device.macAddress)")
            deviceChanged()
        } catch {
            Log.write("\(device.host): MAC lookup over ADB failed: \(error.localizedDescription)")
        }
    }

    /// Every usable MAC address in `output`, in order, as "AA:BB:CC:DD:EE:FF", without
    /// duplicates. All-zero, broadcast and multicast addresses can't be woken and are dropped.
    static func parseMacs(_ output: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![0-9A-Fa-f:])[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}(?![0-9A-Fa-f:])"#) else { return [] }
        var macs: [String] = []
        for match in regex.matches(in: output, range: NSRange(output.startIndex..., in: output)) {
            guard let range = Range(match.range, in: output) else { continue }
            let octets = output[range].split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard octets.count == 6,
                  octets.contains(where: { $0 != 0 }),
                  octets[0] & 0x01 == 0 // multicast bit; also rules out FF:FF:FF:FF:FF:FF
            else { continue }
            let mac = octets.map { String(format: "%02X", $0) }.joined(separator: ":")
            if !macs.contains(mac) { macs.append(mac) }
        }
        return macs
    }

    // ----- Plumbing -----

    // Runs `body` in a task this object owns, so dispose() can cancel it, and so it never
    // runs on the caller's actor. Cancelling the caller cancels it too.
    private func runOwned(_ body: @escaping @Sendable () async -> Void) async {
        let task = Task.detached { await body() }
        let id: UInt64? = gate.withLock {
            guard !disposed else { return nil }
            nextWorkId += 1
            work[nextWorkId] = task
            return nextWorkId
        }
        if id == nil { task.cancel() }

        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }

        if let id { gate.withLock { work[id] = nil } }
    }

    private func withAdbLock<T>(_ body: () async throws -> T) async throws -> T {
        try await adbLock.acquire()
        defer { adbLock.release() }
        return try await body()
    }

    private func currentAdb() -> AdbClient? {
        gate.lock(); defer { gate.unlock() }
        return adb
    }

    private func takePending() -> Int? {
        gate.lock(); defer { gate.unlock() }
        guard hasPending else { return nil }
        hasPending = false
        writing = true
        return pendingValue
    }

    private func setMissed(_ value: Int?) {
        gate.lock(); defer { gate.unlock() }
        missedWhileOff = value
    }

    private func setResumeFailed(_ value: Bool) {
        gate.lock(); defer { gate.unlock() }
        resumeFailed = value
    }

    private func resumeFailedNow() -> Bool {
        gate.lock(); defer { gate.unlock() }
        return resumeFailed
    }

    // The Mac's local (Bonjour) host name, "Alexs-MacBook-Pro": short like Windows' machine
    // name, and available without a DNS lookup.
    private static func localHostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let name = String(cString: buffer)
            if let short = name.split(separator: ".").first, !short.isEmpty { return String(short) }
        }
        return "Mac"
    }

    func dispose() {
        gate.lock()
        disposed = true
        debounceItem?.cancel()
        debounceItem = nil
        let tasks = Array(work.values)
        work.removeAll()
        gate.unlock()
        for task in tasks { task.cancel() }
        closeConnection()
    }
}
