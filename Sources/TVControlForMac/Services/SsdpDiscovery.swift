// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// A TV found on the LAN via SSDP, ready to be added by one click.
struct DiscoveredTv: Identifiable, Hashable {
    let name: String
    let host: String
    let model: String
    var kind: TvKind = .webOs
    var id: String { host }
}

/// Finds controllable TVs on the local network via SSDP (UPnP discovery). Two searches go out:
/// LG's "webos-second-screen" service, which only webOS TVs answer, and DIAL, which every
/// Android TV / Google TV answers (as do other cast-capable devices, so each DIAL responder
/// is kept only if its Android TV Remote port is open). Each responder's device-description
/// XML supplies the friendly name and model.
enum SsdpDiscovery {
    private static let multicastAddress = "239.255.255.250"
    private static let multicastPort: UInt16 = 1900
    private static let webOsTarget = "urn:lge-com:service:webos-second-screen:1"
    private static let dialTarget = "urn:dial-multiscreen-org:service:dial:1"

    /// How long a responder's description may take; one that's slower isn't worth listing.
    private static let describeTimeout: TimeInterval = 3

    private static func mSearch(_ target: String) -> String {
        "M-SEARCH * HTTP/1.1\r\n" +
        "HOST: \(multicastAddress):\(multicastPort)\r\n" +
        "MAN: \"ssdp:discover\"\r\n" +
        "MX: 2\r\n" +
        "ST: \(target)\r\n" +
        "\r\n"
    }

    /// One SSDP answer worth looking up.
    private struct Response: Sendable {
        let location: String
        let isWebOs: Bool
    }

    /// Scans for TVs for roughly `timeout` seconds (default 4), reporting each unique TV
    /// through `onFound` (on the main thread) as it answers, and returns the complete list.
    /// Never throws; an interface that can't be bound is simply skipped.
    static func findTvs(timeout: TimeInterval = 4,
                        onFound: (@MainActor (DiscoveredTv) -> Void)? = nil) async -> [DiscoveredTv] {
        let sockets = createSockets()
        guard !sockets.isEmpty else { return [] }
        // Closed only once every listener has returned (the stream below finishes then).
        defer { for fd in sockets { close(fd) } }

        // Fire the searches a few times per socket — SSDP is UDP, replies can be lost.
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = multicastPort.bigEndian
        inet_pton(AF_INET, multicastAddress, &target.sin_addr)
        let searches = [webOsTarget, dialTarget].map { Array(mSearch($0).utf8) }

        let sendTask = Task.detached {
            for _ in 0..<3 {
                for fd in sockets {
                    for search in searches {
                        search.withUnsafeBufferPointer { buf in
                            withUnsafePointer(to: target) { addr in
                                addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                    _ = sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        // The receive loops block in recv(), so they get threads of their own rather than
        // tying up the shared async pool the lookups below need. Each answer is handed on
        // as it arrives.
        let deadline = Date().addingTimeInterval(timeout)
        let responses = AsyncStream<Response>.makeStream()
        let listeners = DispatchGroup()
        for fd in sockets {
            listeners.enter()
            DispatchQueue.global(qos: .utility).async {
                listen(on: fd, until: deadline) { responses.continuation.yield($0) }
                listeners.leave()
            }
        }
        listeners.notify(queue: .global()) { responses.continuation.finish() }

        // Looking a responder up takes network round-trips (and, for DIAL, a port check), so
        // each runs alongside the listening rather than holding up other replies, and is
        // allowed to finish after the window closes.
        let found = FoundTvs()
        let session = describeSession()
        await withTaskGroup(of: Void.self) { group in
            var seenLocations = Set<String>()
            for await response in responses.stream
            where seenLocations.insert(response.location.lowercased()).inserted {
                group.addTask {
                    let tv = response.isWebOs
                        ? await describeWebOs(location: response.location, session: session)
                        : await describeAndroidTv(location: response.location, session: session)
                    guard let tv, found.add(tv) else { return }
                    if let onFound { await MainActor.run { onFound(tv) } }
                }
            }
        }
        session.invalidateAndCancel()

        sendTask.cancel()
        return found.all
    }

    /// Results so far, one per host, from lookups finishing in any order.
    private final class FoundTvs: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts = Set<String>()
        private var list: [DiscoveredTv] = []

        /// False when a TV at that host is already in.
        func add(_ tv: DiscoveredTv) -> Bool {
            lock.withLock {
                guard hosts.insert(tv.host.lowercased()).inserted else { return false }
                list.append(tv)
                return true
            }
        }

        var all: [DiscoveredTv] { lock.withLock { list } }
    }

    // Blocking receive loop on one socket until the scan window closes (SO_RCVTIMEO-paced),
    // handing each responder on as it answers.
    private static func listen(on fd: Int32, until deadline: Date, found: (Response) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue } // timeout tick or transient error — keep waiting
            let response = String(decoding: buffer[0..<n], as: UTF8.self)
            guard let location = parseLocation(response) else { continue }

            // LG TVs answer DIAL too; they're picked up by the webOS search instead.
            let isWebOs = header("ST", in: response)?.caseInsensitiveCompare(webOsTarget) == .orderedSame
            if !isWebOs, header("SERVER", in: response)?.range(of: "webOS", options: .caseInsensitive) != nil {
                continue
            }
            found(Response(location: location, isWebOs: isWebOs))
        }
    }

    // One socket per IPv4 interface address (so multi-NIC machines search every subnet),
    // plus a wildcard socket as a catch-all. Each has a short receive timeout so the
    // listen loop can observe the deadline.
    private static func createSockets() -> [Int32] {
        var sockets: [Int32] = []

        func tryAdd(bindAddress: in_addr?) {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }

            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var bufSize: Int32 = 64 * 1024
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr = bindAddress ?? in_addr(s_addr: INADDR_ANY)
            let bound = withUnsafePointer(to: addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { close(fd); return }

            // Route the multicast M-SEARCH out this specific interface.
            if var iface = bindAddress {
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &iface, socklen_t(MemoryLayout<in_addr>.size))
            }
            sockets.append(fd)
        }

        for address in NetworkInterfaces.ipv4Addresses() {
            tryAdd(bindAddress: address)
        }
        tryAdd(bindAddress: nil)
        return sockets
    }

    private static func parseLocation(_ response: String) -> String? {
        guard let value = header("LOCATION", in: response),
              let url = URL(string: value), url.scheme != nil, url.host != nil else { return nil }
        return value
    }

    private static func header(_ name: String, in response: String) -> String? {
        let prefix = name.uppercased() + ":"
        for line in response.components(separatedBy: "\r\n") where line.uppercased().hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func describeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = describeTimeout
        config.timeoutIntervalForResource = describeTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    // Fetches the UPnP device description: friendly name, manufacturer and model. Empty
    // strings when the description is unreachable or unreadable.
    private static func readDescription(_ url: URL, session: URLSession) async -> DeviceDescription {
        guard let (data, _) = try? await session.data(from: url) else { return DeviceDescription() }
        return DeviceDescription.parse(data)
    }

    private static func describeWebOs(location: String, session: URLSession) async -> DiscoveredTv? {
        guard let url = URL(string: location), let host = url.host else { return nil }
        let description = await readDescription(url, session: session)
        let model = description.modelName

        // friendlyName is usually "[LG] webOS TV OLED55C34LA" — trim the boilerplate.
        var name = description.friendlyName
            .replacingOccurrences(of: "[LG]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "webOS TV", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = model.isEmpty ? "LG TV" : model }

        return DiscoveredTv(name: name, host: host, model: model, kind: .webOs)
    }

    // A DIAL responder is only a TV we can control if it also runs the Android TV Remote
    // service; speakers, streaming sticks of other makes and the like don't.
    private static func describeAndroidTv(location: String, session: URLSession) async -> DiscoveredTv? {
        guard let url = URL(string: location), let host = url.host else { return nil }
        guard await TvControllerFactory.isPortOpen(host: host, port: TvControllerFactory.androidTvRemotePort) else {
            return nil
        }

        let description = await readDescription(url, session: session)
        var model = description.modelName
        let manufacturer = description.manufacturer

        // e.g. manufacturer "TCL", model "Smart TV Pro" → "TCL Smart TV Pro".
        if !manufacturer.isEmpty, !model.lowercased().hasPrefix(manufacturer.lowercased()) {
            model = "\(manufacturer) \(model)".trimmingCharacters(in: .whitespaces)
        }
        var name = description.friendlyName
        if name.isEmpty { name = model.isEmpty ? TvKind.androidTv.defaultName : model }

        return DiscoveredTv(name: name, host: host, model: model, kind: .androidTv)
    }
}

/// The parts of a UPnP device description we show: the root device's friendly name,
/// manufacturer and model. Read with a real XML parser, so entities (&amp;) and CDATA come
/// out right and an embedded device's fields can't be mistaken for the root's.
private struct DeviceDescription {
    var friendlyName = ""
    var manufacturer = ""
    var modelName = ""

    static func parse(_ data: Data) -> DeviceDescription {
        let delegate = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var result = DeviceDescription()
        private var stack: [String] = []
        private var rootDeviceDepth: Int?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(elementName)
            if elementName == "device", rootDeviceDepth == nil { rootDeviceDepth = stack.count }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            // Only direct children of the first <device>.
            if let depth = rootDeviceDepth, stack.count == depth + 1 {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch elementName {
                case "friendlyName" where result.friendlyName.isEmpty: result.friendlyName = value
                case "manufacturer" where result.manufacturer.isEmpty: result.manufacturer = value
                case "modelName" where result.modelName.isEmpty: result.modelName = value
                default: break
                }
            }
            if elementName == "device", stack.count == rootDeviceDepth { rootDeviceDepth = -1 } // done with it
            stack.removeLast()
            text = ""
        }
    }
}

/// Shared interface enumeration helpers (SSDP + Wake-on-LAN).
enum NetworkInterfaces {
    /// IPv4 addresses of every up, non-loopback interface.
    static func ipv4Addresses() -> [in_addr] {
        addresses(keyPath: \.ifa_addr)
    }

    /// IPv4 broadcast addresses of every up, non-loopback interface.
    static func broadcastAddresses() -> [in_addr] {
        addresses(keyPath: \.ifa_dstaddr)
    }

    private static func addresses(keyPath: KeyPath<ifaddrs, UnsafeMutablePointer<sockaddr>?>) -> [in_addr] {
        var result: [in_addr] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = entry.pointee[keyPath: keyPath], sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if !result.contains(where: { $0.s_addr == addr.s_addr }) {
                result.append(addr)
            }
        }
        return result
    }
}
