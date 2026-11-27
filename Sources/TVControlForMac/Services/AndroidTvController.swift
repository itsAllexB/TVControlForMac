// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import SystemConfiguration

/// Controller for one Android TV / Google TV (TCL, Sony, Philips, Hisense…): pairs with a code,
/// keeps the remote-control connection alive, and turns the TV on and off. The protocol carries
/// key presses and power state but no picture settings; brightness, where a brand allows it at
/// all, goes over ADB (`AdbBrightness`).
final class AndroidTvController: TvController {
    /// How many times, and how far apart, powerOn retries waking an unreachable TV.
    private static let wakeAttempts = 4
    private static let wakeRetryDelay: TimeInterval = 3

    /// How long the TV gets to report its new power state after a power key press.
    private static let powerSettle: TimeInterval = 8

    /// How long the first power report may trail the handshake.
    private static let powerReport: TimeInterval = 2

    private static let pairingStartTimeout: TimeInterval = 8
    private static let codeEntryTimeout: TimeInterval = 180

    /// The TV must refuse our certificate this many times running before we believe it.
    private static let rejectionsBeforeUnpairing = 2

    let device: TvDevice

    private let gate = NSLock()
    private var connectTask: Task<Void, Never>?
    private var disposed = false
    private var client: AndroidTvRemoteClient?
    private var rejections = 0
    private var currentStatus: TvStatus = .disconnected
    // The last connect failure logged while not connected, so a TV that stays off doesn't
    // write the same line every backoff round.
    private var lastFailureLogged: String?

    // Pairing puts a dialog on the TV, so it only ever starts because the user asked.
    private let pairRequested = AsyncMailbox<Void>()
    private var codeEntry: AsyncMailbox<String>?
    private var needsPairingMessage: String?

    // KEYCODE_POWER is a toggle: two presses racing each other would cancel out. A mailbox
    // holding one token is the lock: take it to enter, post it back to leave.
    private let powerLock = AsyncMailbox<Void>(holding: ())

    // Posted to cut the reconnect backoff short when we have reason to think the TV is back.
    private let retryNow = AsyncMailbox<Void>()

    // Brightness isn't part of the remote protocol; where it's possible at all it goes over ADB.
    private let brightness: AdbBrightness
    private var startupApplied = false

    var status: TvStatus { gate.withLock { currentStatus } }
    var supportsBrightness: Bool { brightness.state == .ready }
    var acceptsBrightness: Bool { supportsBrightness || brightness.holds }
    var brightnessSetup: BrightnessSetup { brightness.state }
    var canWake: Bool { !device.macAddress.isEmpty }

    var getStartupBrightness: (() -> Int?)?
    var onStatusChanged: ((TvStatus, String?) -> Void)?
    var onDeviceChanged: (() -> Void)?
    var onBacklightReported: ((Int) -> Void)?
    var onPowerStateReported: ((String) -> Void)?
    var onCapabilitiesChanged: (() -> Void)?

    init(device: TvDevice) {
        self.device = device
        // AdbBrightness asks back about us, but `self` can't be captured before init ends.
        let owner = WeakOwner<AndroidTvController>()
        brightness = AdbBrightness(device: device,
                                   deviceChanged: { owner.value?.onDeviceChanged?() },
                                   tvIsOn: { owner.value?.tvIsOn ?? false })
        owner.value = self
        brightness.onStateChanged = { [weak self] in self?.brightnessStateChanged() }
        brightness.onReported = { [weak self] value in
            guard let self else { return }
            self.device.lastBacklight = value
            self.onBacklightReported?(value)
        }
    }

    private var tvIsOn: Bool {
        guard let client = currentClient else { return false }
        return client.isConnected && client.isOn != false
    }

    private var currentClient: AndroidTvRemoteClient? { gate.withLock { client } }

    func setUpBrightness() {
        let brightness = brightness
        Task.detached { await brightness.setUp() }
    }

    private func brightnessStateChanged() {
        onCapabilitiesChanged?()

        // Schedule catch-up: once per session, the first time brightness is usable.
        let first: Bool = gate.withLock {
            guard brightness.state == .ready, !startupApplied else { return false }
            startupApplied = true
            return true
        }
        if first, let target = getStartupBrightness?() {
            device.lastBacklight = target
            onBacklightReported?(target) // sync the slider
            brightness.set(target)       // push to the TV
        }
    }

    private func setStatus(_ s: TvStatus, _ message: String? = nil) {
        gate.withLock { currentStatus = s }
        onStatusChanged?(s, message)
    }

    // MARK: - Connection lifecycle

    /// Connects and keeps the connection alive, retrying with backoff until disposed.
    func start() {
        // One critical section, so neither a second start() nor a dispose() can slip in
        // between the check and the task being recorded (and then never cancelled).
        gate.withLock {
            guard connectTask == nil, !disposed else { return }
            // Detached: the loop must run on the global executor, never the caller's actor.
            connectTask = Task.detached { [weak self] () -> Void in
                await self?.runConnectLoop()
            }
        }
    }

    private func runConnectLoop() async {
        var delay: TimeInterval = 1
        while !Task.isCancelled {
            do {
                if device.clientCertificate.isEmpty {
                    try await pair()
                    continue // paired → connect right away; not paired → wait for the next request
                }

                setStatus(.connecting)
                guard AndroidTvIdentity.isReadable(device.clientCertificate) else {
                    // A saved certificate that can't even be read (a damaged file, a backup in
                    // a form this app doesn't know) will never connect. Pairing again is the
                    // only way forward, so offer that rather than "Reconnecting" for ever.
                    Log.write("\(device.host): the saved certificate can't be read — pairing again is needed")
                    gate.withLock { needsPairingMessage = "Needs pairing again" }
                    device.clientCertificate = ""
                    onDeviceChanged?()
                    continue
                }
                let credential = try AndroidTvIdentity.loadClientCertificate(device.clientCertificate)
                let client = AndroidTvRemoteClient()
                client.onPowerChanged = { [weak self] on in self?.powerChanged(on) }
                gate.withLock { self.client = client }

                try await client.connect(host: device.host, credential: credential)
                Log.write("Connected to \(device.host) via Android TV Remote (\(client.vendor) \(client.model))")
                setStatus(.connected)
                delay = 1 // reset backoff on success
                gate.withLock {
                    rejections = 0
                    lastFailureLogged = nil
                }

                resolveMacInBackground()
                let brightness = brightness
                let mightSupport = AdbTclBacklight.mightSupport(vendor: client.vendor)
                Task.detached { await brightness.resume(mightSupport: mightSupport) }
                try await client.run()
            } catch {
                if Task.isCancelled { break }
                handleConnectFailure(error)
            }

            cleanupClient()
            if Task.isCancelled { break }

            // Back off, but come straight back if a wake attempt says the TV should be up.
            do { _ = try await retryNow.take(timeout: delay) } catch { break }
            delay = min(delay * 2, 15) // exponential backoff, capped at 15 s
        }
    }

    private func handleConnectFailure(_ error: Error) {
        let atvError = error as? AndroidTvError

        if atvError?.isCertificateRejected == true {
            // The TV was reset or had its paired remotes cleared. Don't re-pair on our own:
            // that would pop a code dialog on a TV nobody may be sitting at. And only believe
            // it the second time running, so one odd handshake can't cost a working pairing.
            let unpair: Bool = gate.withLock {
                rejections += 1
                guard rejections >= Self.rejectionsBeforeUnpairing else { return false }
                rejections = 0
                needsPairingMessage = "Needs pairing again"
                return true
            }
            if unpair {
                Log.write("\(device.host): the TV no longer accepts our certificate — pairing again is needed")
                device.clientCertificate = ""
                onDeviceChanged?()
                // Say so now: the loop only gets to pair() after its backoff, and until then
                // the card would go on saying "Connecting…".
                setStatus(.needsPairing, "Needs pairing again")
            } else {
                Log.write("\(device.host): the TV refused our certificate (\(error.localizedDescription)); trying once more")
                setStatus(.disconnected, "Reconnecting")
            }
            return
        }

        let wasConnected = status == .connected
        if wasConnected {
            Log.write("\(device.host): connection lost (\(error.localizedDescription))")
        } else {
            let message = error.localizedDescription
            let repeated: Bool = gate.withLock {
                defer { lastFailureLogged = message }
                return lastFailureLogged == message
            }
            if !repeated { Log.write("\(device.host): connect failed: \(message)") }
        }
        let unreachable = atvError?.isUnreachable ?? false
        setStatus(.disconnected, wasConnected || !unreachable ? "Reconnecting" : "Can't reach the TV")
    }

    private func powerChanged(_ on: Bool) {
        Log.write("\(device.host): power = \(on ? "on" : "standby")")
        onPowerStateReported?(on ? "Active" : "Standby")
        brightness.tvPowerChanged(on: on)
    }

    // MARK: - Pairing

    func requestPairing() {
        pairRequested.post(())
    }

    func submitPairingCode(_ code: String) {
        gate.withLock { codeEntry }?.post(code)
    }

    /// Waits for the user to ask, then runs one pairing attempt: the TV shows a code, the user
    /// types it into the app, and on success the certificate we used is saved as the credential.
    /// Returns either way; the caller checks whether a certificate now exists.
    private func pair() async throws {
        let message = gate.withLock { needsPairingMessage }
        if !pairRequested.isFull {
            setStatus(.needsPairing, message ?? "Not paired")
        }
        _ = try await pairRequested.take(timeout: nil) // taking it also resets the request
        gate.withLock { needsPairingMessage = nil }

        setStatus(.connecting)
        defer { gate.withLock { codeEntry = nil } }
        do {
            let (credential, pfx) = try AndroidTvIdentity.createClientCertificate()
            let session = try await AndroidTvPairingSession.start(
                host: device.host, credential: credential, clientName: Self.clientName,
                timeout: Self.pairingStartTimeout)
            defer { session.close() }

            let entryDeadline = Date().addingTimeInterval(Self.codeEntryTimeout)
            var prompt = "Enter the code from the TV"
            while true {
                let typed = AsyncMailbox<String>()
                gate.withLock { codeEntry = typed }
                setStatus(.awaitingCode, prompt)

                guard let code = try await typed.take(timeout: entryDeadline.timeIntervalSinceNow) else {
                    throw AndroidTvError.timedOut("Code entry")
                }
                do {
                    try await session.finish(code: code, timeout: entryDeadline.timeIntervalSinceNow)
                    break
                } catch let error as PairingCodeError {
                    prompt = error.message // a typo — the code on the TV is still valid
                }
            }

            device.clientCertificate = pfx
            onDeviceChanged?()
            Log.write("\(device.host): paired")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            Log.write("\(device.host): pairing failed: \(error.localizedDescription)")
            let timedOut: Bool
            if case .timedOut? = error as? AndroidTvError { timedOut = true } else { timedOut = false }
            gate.withLock {
                needsPairingMessage = timedOut ? "Pairing timed out" : "Pairing failed. Is the TV on?"
            }
        }
    }

    /// The name the TV shows for this app while pairing, and in its list of paired remotes.
    static var clientName: String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?)
            ?? Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        return "TVControlForMac (\(name))"
    }

    // MARK: - Power

    /// Puts the TV in standby. False if it isn't connected or didn't confirm.
    @discardableResult
    func turnOff() async -> Bool {
        guard let client = currentClient, client.isConnected else { return false }
        do {
            return try await setPower(client, on: false)
        } catch {
            if !(error is CancellationError) { Log.write("\(device.host): turn off FAILED: \(error.localizedDescription)") }
            return false
        }
    }

    // The remote protocol can't blank just the panel. Standby is the nearest thing, and a
    // Google TV resumes from it in a second or two.
    @discardableResult
    func screenOff() async -> Bool { await turnOff() }

    /// Powers the TV on, by whichever route reaches it.
    ///
    /// A TV in ordinary standby keeps its network up, holds the connection open and takes a
    /// power key (a TCL C765 answers in ~0.2 s). One that shuts down fully instead (seen on the
    /// same TCL when it had a system update pending) falls off Wi-Fi seconds after going dark,
    /// yet the connection goes on looking open until the missing pings give it away, so a key
    /// press can vanish without an error, and Wake-on-LAN didn't reach it either. Hence both
    /// routes on every attempt: a magic packet, which is harmless to a TV that's awake, and the
    /// key; and a key that gets no answer is taken as proof the connection is dead.
    func powerOn() async {
        let mac = device.macAddress
        let hasMac = !mac.isEmpty
        do {
            for _ in 0..<Self.wakeAttempts {
                if Task.isCancelled { return }
                if hasMac { await WakeOnLan.send(mac: mac) }

                if let client = currentClient, client.isConnected {
                    // A send that throws is the same news as one that gets no answer: this
                    // connection is dead (typical after the Mac wakes), so drop it and go round.
                    var answered = false
                    do {
                        answered = try await setPower(client, on: true)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.write("\(device.host): power key not sent (\(error.localizedDescription))")
                    }
                    if answered { return }

                    // Reconnecting also means the next key press acts on a freshly reported
                    // state, so a TV that was merely slow to answer isn't toggled back off.
                    Log.write("\(device.host): no answer to the power key — dropping the connection")
                    client.dispose()
                } else if !hasMac {
                    Log.write("\(device.host): can't wake — not connected, and the MAC address isn't learned yet")
                    return
                }

                // Give the TV a moment to bring its network up, nudging the reconnect loop
                // rather than waiting out its backoff.
                var waited: TimeInterval = 0
                while waited < Self.wakeRetryDelay, !(currentClient?.isConnected ?? false) {
                    retryNow.post(()) // no-op when a nudge is already pending
                    try await Task.sleep(nanoseconds: 500_000_000)
                    waited += 0.5
                }
            }

            if let last = currentClient, last.isConnected, try await setPower(last, on: true) {
                return
            }
            Log.write("\(device.host): didn't come back after \(Self.wakeAttempts) wake attempts — " +
                      "to be woken remotely the TV has to stay on the network in standby " +
                      "(Google TV: Power & Energy > Energy Modes > Increased)")
        } catch is CancellationError {
            return
        } catch {
            Log.write("\(device.host): power on FAILED: \(error.localizedDescription)")
        }
    }

    /// Turns the TV off if it says it's on, wakes it otherwise.
    func togglePower() async {
        if let client = currentClient, client.isConnected,
           (try? await client.waitForPowerReport(timeout: Self.powerReport)) == true {
            await turnOff()
            return
        }
        await powerOn()
    }

    // Presses the power key only if the TV isn't already in the wanted state, then waits for
    // it to confirm. The key is a toggle, so with the state unknown we'd be guessing which way
    // it goes: better to do nothing than to switch a TV on at shutdown.
    private func setPower(_ client: AndroidTvRemoteClient, on: Bool) async throws -> Bool {
        _ = try await powerLock.take(timeout: nil)
        defer { powerLock.post(()) }

        let current = try await client.waitForPowerReport(timeout: Self.powerReport)
        if current == on { return true }
        guard current != nil else {
            Log.write("\(device.host): power state unknown — not sending the power toggle")
            return false
        }

        try await client.sendKey(AndroidTvRemoteClient.keyPower)
        let done = try await client.waitForPower(on: on, timeout: Self.powerSettle)
        Log.write("\(device.host): power key -> \(done ? (on ? "on" : "standby") : "no change reported")")
        return done
    }

    // ARP the TV's MAC once per device while it's reachable, so WoL works after it goes off.
    private func resolveMacInBackground() {
        guard device.macAddress.isEmpty else { return }
        let host = device.host
        Task.detached(priority: .utility) { [weak self] in
            guard let self, !self.isDisposed else { return }
            guard let mac = WakeOnLan.tryResolveMac(host: host), !self.isDisposed else { return }
            self.device.macAddress = mac
            Log.write("\(host): MAC learned \(mac)")
            self.onDeviceChanged?()
        }
    }

    private var isDisposed: Bool { gate.withLock { disposed } }

    // MARK: - Brightness

    func setBacklight(_ value: Int) {
        guard acceptsBrightness else { return }
        device.lastBacklight = max(0, min(100, value))
        brightness.set(value)
    }

    // MARK: - Teardown

    private func cleanupClient() {
        let old: AndroidTvRemoteClient? = gate.withLock {
            defer { client = nil }
            return client
        }
        if let old {
            old.onPowerChanged = nil
            old.dispose()
            brightness.suspend()
        }
    }

    func dispose() {
        let task: Task<Void, Never>? = gate.withLock {
            disposed = true
            defer { connectTask = nil }
            return connectTask
        }
        task?.cancel()
        cleanupClient()
        brightness.dispose()
    }
}

/// A weak reference that can be handed out before its target finishes initializing.
private final class WeakOwner<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

/// Holds at most one value for async code to wait on: a one-shot signal, a typed reply, or
/// (holding a single token) a lock. Every wait can time out and reacts to task cancellation,
/// so nothing waiting on one can outlive `dispose()`.
final class AsyncMailbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var full = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Value?, Error>)] = []
    private var nextId: UInt64 = 0

    /// One `take`'s progress, shared by its body and its cancellation handler (guarded by `lock`).
    private final class Wait: @unchecked Sendable {
        var started = false
        var cancelled = false
    }

    init() {}

    init(holding value: Value) {
        self.value = value
        full = true
    }

    /// True when a value is waiting to be taken.
    var isFull: Bool { lock.withLock { full } }

    /// Hands `value` to the longest waiter, or keeps it if nobody waits. Returns false (and
    /// drops `value`) when one is already kept.
    @discardableResult
    func post(_ value: Value) -> Bool {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.continuation.resume(returning: value)
            return true
        }
        defer { lock.unlock() }
        if full { return false }
        self.value = value
        full = true
        return true
    }

    /// Takes the value, waiting up to `timeout` seconds (forever when nil). Returns nil when
    /// the time runs out; throws `CancellationError` when the task is cancelled.
    func take(timeout: TimeInterval?) async throws -> Value? {
        try Task.checkCancellation()
        let id: UInt64 = lock.withLock { nextId += 1; return nextId }
        let wait = Wait()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value?, Error>) in
                lock.lock()
                wait.started = true
                if full {
                    let v = value
                    value = nil
                    full = false
                    lock.unlock()
                    continuation.resume(returning: v)
                    return
                }
                if wait.cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let timeout, timeout <= 0 {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiters.append((id, continuation))
                lock.unlock()

                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.removeWaiter(id)?.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Value?, Error>? = lock.withLock {
                if let found = takeWaiter(id) { return found }
                // Cancelled before the body ran: leave a note for it to find.
                if !wait.started { wait.cancelled = true }
                return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func removeWaiter(_ id: UInt64) -> CheckedContinuation<Value?, Error>? {
        lock.withLock { takeWaiter(id) }
    }

    // Callers hold `lock`.
    private func takeWaiter(_ id: UInt64) -> CheckedContinuation<Value?, Error>? {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return waiters.remove(at: index).continuation
    }
}
