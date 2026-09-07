import Darwin
import Foundation

enum CleanupScanMode: String, Codable, Sendable {
    case quick, deep

    var titleKey: String { "cleanup.scan.\(rawValue)" }
    var hintKey: String { "cleanup.scan.\(rawValue).hint" }
}

/// A single cancellation/deadline shared by discovery and all sizing workers.
/// Deep scans have no per-directory cutoff; they remain user-cancellable.
final class CleanupScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let startedAt = ProcessInfo.processInfo.systemUptime
    let totalBudget: TimeInterval
    let directoryBudget: TimeInterval

    init(mode: CleanupScanMode, totalBudget: TimeInterval? = nil,
         directoryBudget: TimeInterval? = nil) {
        self.totalBudget = totalBudget ?? (mode == .quick ? 45 : .infinity)
        self.directoryBudget = directoryBudget ?? (mode == .quick ? 8 : .infinity)
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - startedAt }
    var shouldStop: Bool { isCancelled || elapsed >= totalBudget }
}

/// Size-only traversal. FTS supplies type, inode and allocated blocks together;
/// the cleanup path does not build the analyzer's large-file report per file.
enum CleanupScanWorker {
    struct Measurement: Sendable {
        var bytes: UInt64 = 0
        var files: Int = 0
        var complete = true
    }

    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    static func measure(_ path: String, control: CleanupScanControl) -> Measurement {
        let began = ProcessInfo.processInfo.systemUptime
        guard !control.shouldStop, let name = strdup(path) else {
            return Measurement(complete: false)
        }
        defer { free(name) }
        var paths: [UnsafeMutablePointer<CChar>?] = [name, nil]
        guard let tree = paths.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress!, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { return Measurement(complete: false) }
        defer { fts_close(tree) }
        var result = Measurement()
        var seen = Set<Identity>()
        while true {
            if control.shouldStop || ProcessInfo.processInfo.systemUptime - began >= control.directoryBudget {
                result.complete = false
                break
            }
            errno = 0
            guard let entry = fts_read(tree) else {
                if errno != 0 { result.complete = false }
                break
            }
            switch Int32(entry.pointee.fts_info) {
            case FTS_ERR, FTS_DNR, FTS_NS:
                result.complete = false
            case FTS_F, FTS_D:
                guard let metadata = entry.pointee.fts_statp?.pointee else {
                    result.complete = false
                    continue
                }
                // Only multiply-linked files require identity bookkeeping.
                if metadata.st_nlink > 1 && Int32(entry.pointee.fts_info) == FTS_F {
                    guard seen.insert(Identity(device: metadata.st_dev, inode: metadata.st_ino)).inserted else {
                        continue
                    }
                }
                result.bytes &+= UInt64(max(0, metadata.st_blocks)) * 512
                if Int32(entry.pointee.fts_info) == FTS_F { result.files += 1 }
            default:
                break // Never follow symlinks or count directory postorder twice.
            }
        }
        return result
    }

    /// Workers draw from one queue across all roots, keeping total I/O bounded.
    static func measure(_ paths: [String], control: CleanupScanControl,
                        progress: @escaping (Int, String) -> Void) -> [Measurement] {
        guard !paths.isEmpty else { return [] }
        let lock = NSLock()
        var next = 0
        var completed = 0
        var result = Array(repeating: Measurement(complete: false), count: paths.count)
        DispatchQueue.concurrentPerform(iterations: min(8, paths.count)) { _ in
            while true {
                lock.lock()
                guard next < paths.count, !control.shouldStop else { lock.unlock(); break }
                let index = next
                next += 1
                let before = completed
                lock.unlock()
                progress(before, paths[index])
                let measurement = measure(paths[index], control: control)
                lock.lock()
                result[index] = measurement
                completed += 1
                let after = completed
                lock.unlock()
                progress(after, paths[index])
            }
        }
        return result
    }
}
