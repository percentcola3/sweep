import Foundation

@main
struct TrafficAttributionTests {
    static func main() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "TrafficAttributionTests", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let chrome = "/Applications/Google Chrome.app"
        try expect(TrafficAttribution.applicationURL(in: chrome + "/Contents/MacOS/Google Chrome")?.path == chrome,
                   "Main executable did not map to app")
        try expect(TrafficAttribution.applicationURL(in: chrome + "/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")?.path == chrome,
                   "Browser helper was split into another app")
        try expect(TrafficAttribution.applicationURL(in: "/usr/bin/python3") == nil,
                   "CLI process invented an app")
        try expect(TrafficAttribution.applicationURL(in: "/Applications/Foo.application/bin") == nil,
                   "Non-app extension was accepted")

        let ports: Set<Int> = [7890, 7891, 7897]
        for port in ports {
            try expect(TrafficAttribution.exitKind(remote: "127.0.0.1:\(port)", proxyPorts: ports, interface: nil) == .proxy,
                       "A proxy listener was missed")
        }
        try expect(TrafficAttribution.exitKind(remote: "[::ffff:127.0.0.1]:7891", proxyPorts: ports, interface: nil) == .proxy,
                   "Mapped IPv4 proxy endpoint was missed")
        try expect(TrafficAttribution.exitKind(remote: "[::1]:5432", proxyPorts: ports, interface: nil) == .loopback,
                   "Local socket was labeled proxy")
        try expect(TrafficAttribution.exitKind(remote: "1.1.1.1:443", proxyPorts: ports, interface: nil) == .unknown,
                   "Missing route was mislabeled direct")
        try expect(TrafficAttribution.exitKind(remote: "1.1.1.1:443", proxyPorts: ports, interface: "unknown") == .unknown,
                   "Failed route was mislabeled direct")
        try expect(TrafficAttribution.exitKind(remote: "1.1.1.1:443", proxyPorts: ports, interface: "utun4") == .tunnel,
                   "TUN was mislabeled as a proxy node")
        try expect(TrafficAttribution.exitKind(remote: "1.1.1.1:443", proxyPorts: ports, interface: "en0") == .direct,
                   "Physical route was missed")

        let tcp = TrafficAttribution.flowKey(proto: "TCP", local: "192.0.2.1:1234", remote: "1.1.1.1:443")
        try expect(tcp != TrafficAttribution.flowKey(proto: "UDP", local: "192.0.2.1:1234", remote: "1.1.1.1:443"),
                   "TCP and UDP sources collided")
        try expect(tcp != TrafficAttribution.flowKey(proto: "TCP", local: "192.0.2.1:1234", remote: "2.2.2.2:443"),
                   "Different TUN destinations collided")
        try expect(tcp == TrafficAttribution.socketKey(proto: "tcp", host: "::ffff:192.0.2.1", port: "1234") + "|1.1.1.1|443",
                   "Clash metadata did not join the original socket tuple")
        print("Traffic attribution: app helpers, proxy ports, TUN tuples and unknown routes passed")
    }
}
