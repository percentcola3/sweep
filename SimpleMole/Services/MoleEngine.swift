import Darwin
import Foundation
import Security
import os

/// 特色能力桥接层：负责以子进程方式运行打包在 App 内的 shell 脚本，
/// 并把输出逐行流式回调（供日志抽屉实时显示）。核心清理不经过此层。
final class MoleEngine {
    static let shared = MoleEngine()

    private final class RunningProcess: Equatable {
        let pid: pid_t
        let processGroup: pid_t

        let inputWriter: InputWriter?
        let cancellation: (() -> Void)?

        init(pid: pid_t, processGroup: pid_t, inputWriter: InputWriter?, cancellation: (() -> Void)?) {
            self.pid = pid
            self.processGroup = processGroup
            self.inputWriter = inputWriter
            self.cancellation = cancellation
        }

        static func == (lhs: RunningProcess, rhs: RunningProcess) -> Bool {
            lhs.pid == rhs.pid && lhs.processGroup == rhs.processGroup
        }
    }

    private struct EngineState {
        var tracked: [RunningProcess] = []
    }

    private struct ExecutionState {
        var finished = false
        var timedOut = false
    }

    let resourcesURL: URL
    private let appBundleURL: URL
    private let runningCodeDirectoryHash: String?
    private let state = OSAllocatedUnfairLock(uncheckedState: EngineState())
    private static let logger = Logger(subsystem: "com.forgesweep.app", category: "process")

    init() {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        appBundleURL = bundle
        resourcesURL = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/")
        // 信任锚来自当前已加载进程，而不是运行期可被替换的 Bundle 路径。
        // 提权时 staged Bundle 必须与这份运行代码的 CDHash 完全一致。
        runningCodeDirectoryHash = Self.currentProcessCodeDirectoryHash()
    }

    func resourceURL(_ relativePath: String) -> URL? {
        let url = resourcesURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 只传递桥接脚本实际需要的用户环境，不继承 BASH_ENV / ENV 等 shell 注入入口。
    func standardEnvironment(_ extra: [String: String] = [:], includeHomebrew: Bool = true) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let allowedKeys = [
            "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
            "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"
        ]
        var environment: [String: String] = [:]
        for key in allowedKeys {
            if let value = inherited[key], !value.isEmpty { environment[key] = value }
        }
        environment["PATH"] = includeHomebrew
            ? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            : "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// 终止所有被追踪的子进程组（应用退出或用户取消时调用）。
    func cancelAll() {
        let processes = state.withLock { current -> [RunningProcess] in
            let all = current.tracked
            current.tracked.removeAll()
            return all
        }
        for process in processes { Self.terminate(process) }
    }

    /// 运行 `bridge/` 下的扫描类桥接脚本（TSV 输出）。
    @discardableResult
    func runBridge(_ relativePath: String, arguments: [String] = [],
                   extraEnvironment: [String: String] = [:],
                   timeout: TimeInterval = 120, onLine: ((String) -> Void)? = nil) async -> RunResult {
        guard let script = resourceURL(relativePath) else {
            return RunResult(output: "App 资源缺失（\(relativePath)），请重新构建。", exitCode: 127, timedOut: false)
        }
        return await run(executable: URL(fileURLWithPath: "/bin/bash"),
                         arguments: [script.path] + arguments,
                         environment: standardEnvironment(extraEnvironment),
                         currentDirectory: resourcesURL,
                         timeout: timeout, onLine: onLine)
    }

    /// 运行 apply 类桥接脚本：选中项以 NUL 分隔写入 stdin。
    @discardableResult
    func runBridgeWithStdin(_ relativePath: String, stdinData: Data,
                            extraEnvironment: [String: String] = [:],
                            timeout: TimeInterval = 600) async -> RunResult {
        guard let script = resourceURL(relativePath) else {
            return RunResult(output: "App 资源缺失（\(relativePath)），请重新构建。", exitCode: 127, timedOut: false)
        }
        return await run(executable: URL(fileURLWithPath: "/bin/bash"),
                         arguments: [script.path],
                         environment: standardEnvironment(extraEnvironment),
                         currentDirectory: resourcesURL,
                         stdinData: stdinData,
                         timeout: timeout)
    }

    /// 通过 osascript 提权运行桥接脚本（系统级扫描与清理）。
    ///
    /// root 不直接执行用户可写 Bundle：先把整个 App 复制到 root-only 目录，
    /// 完整验签并比对启动时 CDHash，最后在空环境中执行暂存脚本。
    @discardableResult
    func runPrivilegedBridge(_ relativePath: String, arguments: [String],
                             timeout: TimeInterval = 600) async -> RunResult {
        guard let expectedHash = runningCodeDirectoryHash else {
            return RunResult(output: "App 签名无法验证，已拒绝管理员操作。",
                             exitCode: 78, timedOut: false)
        }
        guard Self.isSafeRelativeResourcePath(relativePath),
              let script = resourceURL(relativePath),
              Self.isRegularResource(script, inside: resourcesURL) else {
            return RunResult(output: "提权脚本路径无效，已拒绝管理员操作。",
                             exitCode: 78, timedOut: false)
        }
        guard let cancellationToken = PrivilegedCancellationToken() else {
            return RunResult(output: "无法创建安全的提权取消标记。",
                             exitCode: 78, timedOut: false)
        }
        defer { cancellationToken.cancel() }

        let stagedResources = "$staged_app/Contents/Resources"
        let stagedScript = "$staged_resources/\(relativePath)"
        let commandArguments = arguments.map { argument -> String in
            // 系统清理桥接原本会收到 Bundle 资源目录；提权后必须改用已验签副本。
            argument == resourcesURL.path ? "\"\(stagedResources)\"" : shellQuote(argument)
        }.joined(separator: " ")
        let invocation = commandArguments.isEmpty
            ? "/bin/bash \"\(stagedScript)\""
            : "/bin/bash \"\(stagedScript)\" \(commandArguments)"

        let command = [
            "set -eu",
            "umask 077",
            "[ \"$(/usr/bin/id -u)\" -eq 0 ] || exit 77",
            "stage_root=''",
            "worker_pid=''",
            "terminate_tree() { tree_pid=$1; tree_signal=$2; for tree_child in $(/bin/ps -axo pid=,ppid= | /usr/bin/awk -v parent=\"$tree_pid\" '$2 == parent {print $1}'); do terminate_tree \"$tree_child\" \"$tree_signal\"; done; /bin/kill -\"$tree_signal\" \"$tree_pid\" 2>/dev/null || true; }",
            "cleanup() { if [ -n \"$worker_pid\" ] && /bin/kill -0 \"$worker_pid\" 2>/dev/null; then terminate_tree \"$worker_pid\" TERM; /bin/sleep 1; terminate_tree \"$worker_pid\" KILL; fi; case \"$stage_root\" in /private/var/tmp/com.forgesweep.privileged.*) /bin/rm -rf -- \"$stage_root\" ;; esac; }",
            "trap cleanup 0",
            "trap 'exit 129' HUP",
            "trap 'exit 130' INT",
            "trap 'exit 143' TERM",
            "stage_root=$(/usr/bin/mktemp -d /private/var/tmp/com.forgesweep.privileged.XXXXXXXX)",
            "case \"$stage_root\" in /private/var/tmp/com.forgesweep.privileged.*) ;; *) exit 77 ;; esac",
            "[ -f \(shellQuote(cancellationToken.url.path)) ] || exit 143",
            "/bin/chmod 700 \"$stage_root\"",
            "staged_app=\"$stage_root/ForgeSweep.app\"",
            "staged_resources=\"$staged_app/Contents/Resources\"",
            "/usr/bin/ditto --noqtn \(shellQuote(appBundleURL.path)) \"$staged_app\"",
            "/usr/bin/codesign --verify --deep --strict \"$staged_app\"",
            "/usr/bin/codesign -d --verbose=4 \"$staged_app\" >\"$stage_root/codesign.txt\" 2>&1",
            "actual_hash=$(/usr/bin/awk -F= '/^CDHash=/{print $2; exit}' \"$stage_root/codesign.txt\")",
            "[ \"$actual_hash\" = \(shellQuote(expectedHash)) ] || exit 78",
            "[ -f \"\(stagedScript)\" ] && [ ! -L \"\(stagedScript)\" ] || exit 78",
            "[ -f \(shellQuote(cancellationToken.url.path)) ] || exit 143",
            "/usr/bin/env -i HOME=/var/root USER=root LOGNAME=root PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/private/var/tmp TERM=dumb NO_COLOR=1 \(invocation) & worker_pid=$!",
            "while /bin/kill -0 \"$worker_pid\" 2>/dev/null; do if [ ! -f \(shellQuote(cancellationToken.url.path)) ]; then terminate_tree \"$worker_pid\" TERM; /bin/sleep 2; terminate_tree \"$worker_pid\" KILL; wait \"$worker_pid\" 2>/dev/null || true; worker_pid=''; exit 143; fi; /bin/sleep 0.2; done",
            "worker_status=0",
            "wait \"$worker_pid\" || worker_status=$?",
            "worker_pid=''",
            "exit \"$worker_status\""
        ].joined(separator: "; ")

        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        return await run(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                         arguments: ["-e", source],
                         environment: standardEnvironment(includeHomebrew: false),
                         timeout: timeout, cancellation: cancellationToken.cancel)
    }

    /// 进程 / 端口桥接（只读观察 + 明确选中后的终止信号）。
    @discardableResult
    func runRuntime(_ mode: String, _ pid: String? = nil,
                    timeout: TimeInterval = 15) async -> RunResult {
        guard let script = resourceURL("bin/app_runtime.sh") else {
            return RunResult(output: "App 资源缺失（app_runtime.sh），请重新构建。", exitCode: 127, timedOut: false)
        }
        var arguments = [script.path, mode]
        if let pid { arguments.append(pid) }
        return await run(executable: URL(fileURLWithPath: "/bin/bash"),
                         arguments: arguments,
                         environment: standardEnvironment(includeHomebrew: false),
                         currentDirectory: resourcesURL,
                         timeout: timeout)
    }

    // MARK: - 核心执行器

    @discardableResult
    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL? = nil, stdinData: Data? = nil,
             timeout: TimeInterval? = nil, onLine: ((String) -> Void)? = nil,
             cancellation: (() -> Void)? = nil) async -> RunResult {
        var stdoutFDs = [Int32](repeating: -1, count: 2)
        var stderrFDs = [Int32](repeating: -1, count: 2)
        var stdinFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutFDs) == 0, pipe(&stderrFDs) == 0,
              stdinData == nil || pipe(&stdinFDs) == 0 else {
            Self.closeDescriptors(stdoutFDs + stderrFDs + stdinFDs)
            return RunResult(output: "无法创建子进程通道。", exitCode: 127, timedOut: false)
        }
        Self.markCloseOnExec(stdoutFDs + stderrFDs + stdinFDs)

        let drains = DispatchGroup()
        let stdoutCollector = StreamCollector(prefix: nil, capturesOutput: true, onLine: onLine)
        let stderrCollector = StreamCollector(prefix: "[stderr] ", capturesOutput: true, onLine: onLine)
        let stdoutReader = PipeReader(fileDescriptor: stdoutFDs[0], collector: stdoutCollector, group: drains)
        let stderrReader = PipeReader(fileDescriptor: stderrFDs[0], collector: stderrCollector, group: drains)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            stdoutReader.cancel()
            stderrReader.cancel()
            Self.closeDescriptors([stdoutFDs[1], stderrFDs[1]] + stdinFDs)
            return RunResult(output: "无法初始化子进程。", exitCode: 127, timedOut: false)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var setupError: Int32 = 0
        func record(_ result: Int32) {
            if setupError == 0, result != 0 { setupError = result }
        }
        record(posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO))
        record(posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], STDERR_FILENO))
        record(posix_spawn_file_actions_addclose(&actions, stdoutFDs[0]))
        record(posix_spawn_file_actions_addclose(&actions, stderrFDs[0]))
        record(posix_spawn_file_actions_addclose(&actions, stdoutFDs[1]))
        record(posix_spawn_file_actions_addclose(&actions, stderrFDs[1]))
        if stdinData != nil {
            record(posix_spawn_file_actions_adddup2(&actions, stdinFDs[0], STDIN_FILENO))
            record(posix_spawn_file_actions_addclose(&actions, stdinFDs[0]))
            record(posix_spawn_file_actions_addclose(&actions, stdinFDs[1]))
        } else {
            record("/dev/null".withCString {
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, $0, O_RDONLY, 0)
            })
        }
        if let currentDirectory {
            record(currentDirectory.path.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            })
        }

        // 关闭其他并发任务的 pipe，避免它们被新子进程继承导致 EOF 永不到达。
        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        record(posix_spawnattr_setflags(&attributes, spawnFlags))
        record(posix_spawnattr_setpgroup(&attributes, 0))
        guard setupError == 0 else {
            stdoutReader.cancel()
            stderrReader.cancel()
            Self.closeDescriptors([stdoutFDs[1], stderrFDs[1]] + stdinFDs)
            return RunResult(output: "无法配置子进程：\(String(cString: strerror(setupError)))",
                             exitCode: 127, timedOut: false)
        }

        var pid: pid_t = 0
        let argv = [executable.path] + arguments
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let spawnError = Self.withCStringArray(argv) { argvPointers in
            Self.withCStringArray(env) { envPointers in
                executable.path.withCString { executablePath in
                    posix_spawn(&pid, executablePath, &actions, &attributes,
                                argvPointers.baseAddress!, envPointers.baseAddress!)
                }
            }
        }

        // 只有父进程保留读端和 stdin 写端。
        Self.closeDescriptors([stdoutFDs[1], stderrFDs[1]])
        if stdinData != nil { Self.closeDescriptor(stdinFDs[0]) }

        guard spawnError == 0 else {
            if stdinData != nil { Self.closeDescriptor(stdinFDs[1]) }
            stdoutReader.cancel()
            stderrReader.cancel()
            return RunResult(output: "无法启动 \(executable.lastPathComponent)：\(String(cString: strerror(spawnError)))",
                             exitCode: 127, timedOut: false)
        }

        let inputWriter = stdinData == nil ? nil : InputWriter(fileDescriptor: stdinFDs[1])
        let running = RunningProcess(pid: pid, processGroup: pid,
                                     inputWriter: inputWriter, cancellation: cancellation)
        state.withLock { current in
            current.tracked.append(running)
        }

        // 必须在 spawn 成功后再写 stdin；否则大于 pipe 缓冲区的路径集会永久阻塞。
        if let stdinData { inputWriter?.start(stdinData) }

        let execution = OSAllocatedUnfairLock(uncheckedState: ExecutionState())
        var timeoutWork: DispatchWorkItem?
        if let timeout {
            let work = DispatchWorkItem {
                let shouldTerminate = execution.withLock { current -> Bool in
                    guard !current.finished else { return false }
                    current.timedOut = true
                    return true
                }
                if shouldTerminate { Self.terminate(running) }
            }
            timeoutWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
        }

        let waitStatus: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                var result: pid_t
                repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
                execution.withLock { $0.finished = true }
                continuation.resume(returning: result == pid ? status : -1)
            }
        }
        timeoutWork?.cancel()

        // 主进程已退出后不再允许 stdin writer 被不读数据的后代进程占住。
        inputWriter?.cancel()
        if let inputWriter {
            _ = await Self.wait(for: inputWriter.completion, timeout: 1)
        }

        // waitpid 只说明主进程结束；等两路 pipe EOF 后才解析，避免丢失尾部输出。
        // 如果后代进程异常持有 pipe，先回收整个进程组，再有界地关闭读端。
        if !(await Self.wait(for: drains, timeout: 1)) {
            Self.terminate(running)
            if !(await Self.wait(for: drains, timeout: 3)) {
                stdoutReader.cancel()
                stderrReader.cancel()
                _ = await Self.wait(for: drains, timeout: 1)
            }
        }
        forget(running)

        let exitCode = Self.exitCode(from: waitStatus)
        let timedOut = execution.withLock { $0.timedOut }
        let stderrOutput = stderrCollector.finish()
        if !stderrOutput.isEmpty {
            Self.logger.error("subprocess stderr: \(stderrOutput, privacy: .private)")
        }
        return RunResult(output: stdoutCollector.finish(), errorOutput: stderrOutput,
                         exitCode: exitCode, timedOut: timedOut)
    }

    private func forget(_ process: RunningProcess) {
        state.withLock { current in
            current.tracked.removeAll { $0 == process }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    // MARK: - 进程与签名工具

    private static func terminate(_ process: RunningProcess) {
        guard process.processGroup > 1 else { return }
        process.inputWriter?.cancel()
        process.cancellation?()
        _ = kill(-process.processGroup, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            // 组内仍有进程才升级为 KILL；负 PID 作用于整个独立进程组。
            if kill(-process.processGroup, 0) == 0 || errno == EPERM {
                _ = kill(-process.processGroup, SIGKILL)
            }
        }
    }

    private static func wait(for group: DispatchGroup, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: group.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        guard waitStatus >= 0 else { return 127 }
        let signal = waitStatus & 0x7F
        return signal == 0 ? (waitStatus >> 8) & 0xFF : 128 + signal
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors { closeDescriptor(descriptor) }
    }

    fileprivate static func closeDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        _ = close(descriptor)
    }

    private static func markCloseOnExec(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            let flags = fcntl(descriptor, F_GETFD)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
        }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in body(buffer) }
    }

    private static func isSafeRelativeResourcePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isRegularResource(_ resource: URL, inside resources: URL) -> Bool {
        let base = resources.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = resource.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/") else { return false }
        guard let values = try? resource.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func currentProcessCodeDirectoryHash() -> String? {
        var runningCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess,
              let runningCode else { return nil }

        // 如果磁盘上的 Bundle 已与当前运行代码不一致，直接禁用提权。
        guard SecCodeCheckValidity(
            runningCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess else { return nil }

        var information: CFDictionary?
        // Security.framework 的 C API 明确允许向该函数传 SecCodeRef；
        // Swift 将 SecCodeRef / SecStaticCodeRef 导入为两个不同的不透明类型。
        let signingInfoCode = unsafeBitCast(runningCode, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(
            signingInfoCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [CFString: Any],
        let unique = dictionary[kSecCodeInfoUnique] as? Data,
        !unique.isEmpty else { return nil }

        return unique.map { String(format: "%02x", $0) }.joined()
    }
}

/// 用户进程可删除、root 进程只观察的取消标记。被删除只会中止操作，不会扩大权限。
private final class PrivilegedCancellationToken {
    let url: URL

    private let lock = NSLock()
    private var cancelled = false

    init?() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = directory.appendingPathComponent("forgesweep-privileged-\(UUID().uuidString).token")
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else { return nil }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }
}

/// 非阻塞写入 stdin，取消时不会留下卡在 pipe.write 的工作线程。
private final class InputWriter {
    let completion = DispatchGroup()

    private let lock = NSLock()
    private let fileDescriptor: Int32
    private var cancelled = false
    private var started = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
        _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func start(_ data: Data) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        completion.enter()
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                MoleEngine.closeDescriptor(fileDescriptor)
                completion.leave()
            }
            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    lock.lock()
                    let shouldStop = cancelled
                    lock.unlock()
                    if shouldStop { return }

                    let written = Darwin.write(
                        fileDescriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written == -1 && errno == EINTR {
                        continue
                    } else if written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        usleep(10_000)
                    } else {
                        return
                    }
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let needsClose = !started
        if needsClose { started = true }
        lock.unlock()
        if needsClose { MoleEngine.closeDescriptor(fileDescriptor) }
    }
}

/// 分流聚合子进程输出：stdout 供结构化解析，stderr 只进入带标记的日志回调。
private final class StreamCollector {
    private let lock = NSLock()
    private var captured = Data()
    private var pendingLine = Data()
    private var didFinish = false
    private let prefix: String?
    private let capturesOutput: Bool
    private let onLine: ((String) -> Void)?

    init(prefix: String?, capturesOutput: Bool, onLine: ((String) -> Void)?) {
        self.prefix = prefix
        self.capturesOutput = capturesOutput
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        guard !didFinish else { lock.unlock(); return }
        if capturesOutput { captured.append(chunk) }
        pendingLine.append(chunk)
        while let newline = pendingLine.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pendingLine[..<newline], as: UTF8.self))
            pendingLine.removeSubrange(...newline)
        }
        lock.unlock()
        emit(lines)
    }

    func finishLines() {
        var remainder: String?
        lock.lock()
        if !didFinish {
            didFinish = true
            if !pendingLine.isEmpty {
                remainder = String(decoding: pendingLine, as: UTF8.self)
                pendingLine.removeAll()
            }
        }
        lock.unlock()
        if let remainder { emit([remainder]) }
    }

    func finish() -> String {
        finishLines()
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: captured, as: UTF8.self)
    }

    private func emit(_ lines: [String]) {
        guard let onLine else { return }
        for line in lines { onLine(prefix.map { $0 + line } ?? line) }
    }
}

/// 持续排空一路非阻塞 pipe，EOF 时只完成一次 DispatchGroup。
private final class PipeReader {
    private let lock = NSLock()
    private let fileDescriptor: Int32
    private let collector: StreamCollector
    private let group: DispatchGroup
    private var cancelled = false

    init(fileDescriptor: Int32, collector: StreamCollector, group: DispatchGroup) {
        self.fileDescriptor = fileDescriptor
        self.collector = collector
        self.group = group
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                MoleEngine.closeDescriptor(fileDescriptor)
                collector.finishLines()
                group.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
            while true {
                lock.lock()
                let shouldStop = cancelled
                lock.unlock()
                if shouldStop { return }

                let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    collector.append(Data(buffer[..<count]))
                } else if count == 0 {
                    return
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(10_000)
                } else {
                    return
                }
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
