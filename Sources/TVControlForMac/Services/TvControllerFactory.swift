// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network

enum TvControllerFactory {
    /// The Android TV Remote protocol's control port; a TV that answers on it is a
    /// Google TV / Android TV.
    static let androidTvRemotePort: UInt16 = 6466

    static func create(_ device: TvDevice) -> TvController {
        switch device.kind {
        case .androidTv:
            return AndroidTvController(device: device)
        case .webOs:
            return WebOsController(device: device)
        }
    }

    /// Which protocol the TV at `host` speaks, judged by the ports it answers on. Nil when
    /// none answers (the TV is off, or the address is wrong): guessing then would save the
    /// TV as the wrong kind for good.
    static func detectKind(host: String) async -> TvKind? {
        // Probe all at once and take the first port that answers: no TV listens on both
        // families, and the ports it doesn't have may be silently dropped rather than refused.
        await withTaskGroup(of: TvKind?.self) { group in
            group.addTask { await isPortOpen(host: host, port: androidTvRemotePort) ? .androidTv : nil }
            group.addTask { await isPortOpen(host: host, port: 3000) ? .webOs : nil }
            group.addTask { await isPortOpen(host: host, port: 3001) ? .webOs : nil }
            for await kind in group {
                if let kind {
                    group.cancelAll()
                    return kind
                }
            }
            return nil
        }
    }

    /// True when a TCP connection to `host:port` succeeds within `timeout`.
    static func isPortOpen(host: String, port: UInt16, timeout: TimeInterval = 1.5) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let finished = OnceFlag()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                @Sendable func finish(_ open: Bool) {
                    guard finished.set() else { return }
                    connection.cancel()
                    continuation.resume(returning: open)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .failed, .cancelled: finish(false)
                    case .waiting: finish(false) // refused / no route: don't sit out the timeout
                    default: break
                    }
                }
                connection.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

/// A flag that can be set exactly once, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// Returns true for the first caller only.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
