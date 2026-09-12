import Foundation

/// Shared socket and application identities for process snapshots and Clash metadata.
enum TrafficAttribution {
    static func applicationURL(in path: String) -> URL? {
        let path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard path.hasPrefix("/"), let range = path.range(of: ".app"),
              range.upperBound == path.endIndex || path[range.upperBound] == "/" else { return nil }
        // Browser/Electron helpers nested in Foo.app belong to Foo, not Helper.app.
        return URL(fileURLWithPath: String(path[...path.index(before: range.upperBound)]))
            .standardizedFileURL
    }

    static func remoteHost(_ endpoint: String) -> String {
        if endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") {
            return normalizedHost(String(endpoint[endpoint.index(after: endpoint.startIndex)..<close]))
        }
        guard let colon = endpoint.lastIndex(of: ":") else { return normalizedHost(endpoint) }
        return normalizedHost(String(endpoint[..<colon]))
    }

    static func remotePort(_ endpoint: String) -> String {
        guard let colon = endpoint.lastIndex(of: ":"), colon < endpoint.index(before: endpoint.endIndex)
        else { return "" }
        return String(endpoint[endpoint.index(after: colon)...])
    }

    static func normalizedHost(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = normalizedHost(host)
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    static func isRoutableAddress(_ host: String) -> Bool {
        !host.isEmpty && host.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
    }

    static func socketKey(proto: String, host: String, port: String) -> String {
        "\(proto.lowercased())|\(normalizedHost(host))|\(port)"
    }

    static func flowKey(proto: String, local: String, remote: String) -> String {
        socketKey(proto: proto, host: remoteHost(local), port: remotePort(local))
            + "|\(remoteHost(remote))|\(remotePort(remote))"
    }

    static func exitKind(remote: String, proxyPorts: Set<Int>, interface: String?) -> TrafficExitKind {
        let host = remoteHost(remote)
        if isLoopback(host) {
            if let port = Int(remotePort(remote)), proxyPorts.contains(port) { return .proxy }
            return .loopback
        }
        guard let interface, !interface.isEmpty, interface != "unknown" else { return .unknown }
        if interface.hasPrefix("utun") { return .tunnel }
        if interface.hasPrefix("en") || interface.hasPrefix("bridge") { return .direct }
        return .unknown
    }
}
