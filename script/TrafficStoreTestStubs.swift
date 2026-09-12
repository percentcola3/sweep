import Foundation

/// Store restoration tests must fail before touching the OS or a proxy controller.
struct MoleEngine: Sendable {
    static let shared = MoleEngine()

    struct Result: Sendable {
        let succeeded: Bool
        let output: String
    }

    func runRuntime(_ command: String, timeout: TimeInterval) async -> Result {
        fatalError("offline store test unexpectedly requested runtime sampling: \(command)")
    }

    func runBridge(_ path: String, arguments: [String] = [],
                   extraEnvironment: [String: String] = [:],
                   timeout: TimeInterval = 15) async -> Result {
        fatalError("offline store test unexpectedly requested a bridge: \(path)")
    }

    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?, stdinData: Data?, timeout: TimeInterval) async -> Result {
        fatalError("offline store test unexpectedly requested a subprocess")
    }

    func resourceURL(_ path: String) -> URL? {
        fatalError("offline store test unexpectedly requested a bridge resource")
    }

    func standardEnvironment() -> [String: String] {
        fatalError("offline store test unexpectedly requested a subprocess environment")
    }

    var resourcesURL: URL {
        fatalError("offline store test unexpectedly requested the runtime directory")
    }
}

enum SystemMetrics {
    static func interfaceCounters() -> [String: (inbound: UInt64, outbound: UInt64)] {
        fatalError("offline store test unexpectedly requested interface counters")
    }
}
