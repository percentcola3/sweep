import Foundation
import Darwin
import IOKit
import IOKit.storage
import IOKit.ps

/// 原生系统指标采集：CPU / 内存 / 网络速率 / 磁盘。
/// 周期指标走系统调用；进程排行按需调用一次 `/bin/ps`。速率类指标基于
/// 相邻两次采样的差值。
enum SystemMetrics {
    private static var previousCPUTicks: [natural_t] = [0, 0, 0, 0]
    private static var previousNetworkRx: UInt64 = 0
    private static var previousNetworkTx: UInt64 = 0
    private static var previousNetworkSample: Double = 0
    private static var previousDiskRead: UInt64 = 0
    private static var previousDiskWrite: UInt64 = 0
    private static var previousDiskSample: Double = 0

    static func sample() -> MetricsSnapshot {
        var snapshot = MetricsSnapshot()
        snapshot.collectedAt = Date()
        snapshot.cpuPercent = cpuUsage()
        let memory = memoryStats()
        snapshot.memoryPercent = memory.percent
        snapshot.memoryUsedBytes = memory.usedBytes
        snapshot.memoryTotalBytes = memory.totalBytes
        snapshot.memoryAvailableBytes = memory.availableBytes
        snapshot.memoryPressure = memory.pressure
        let cores = cpuCounts()
        snapshot.logicalCPUCount = cores.logical
        snapshot.physicalCPUCount = cores.physical
        snapshot.loadAverage = loadAverage()
        let swap = swapUsage()
        snapshot.swapUsedBytes = swap.used
        snapshot.swapTotalBytes = swap.total
        let disk = diskUsage()
        snapshot.diskFreeBytes = disk.freeBytes
        snapshot.diskUsedPercent = disk.usedPercent
        let diskIO = diskRates()
        snapshot.diskReadMBps = diskIO.read
        snapshot.diskWriteMBps = diskIO.write
        let battery = batteryStats()
        snapshot.batteryPercent = battery.percent
        snapshot.batteryHealthPercent = battery.health
        snapshot.batteryCycleCount = battery.cycles
        snapshot.batteryCharging = battery.charging
        let network = networkRates()
        snapshot.networkRxMBps = network.rx
        snapshot.networkTxMBps = network.tx
        snapshot.uptimeSeconds = uptimeSeconds()
        snapshot.healthScore = healthScore(cpu: snapshot.cpuPercent,
                                           memory: snapshot.memoryPercent,
                                           disk: snapshot.diskUsedPercent,
                                           pressure: snapshot.memoryPressure,
                                           batteryHealth: snapshot.batteryHealthPercent)
        return snapshot
    }

    private static func batteryStats() -> (percent: Double, health: Double,
                                            cycles: Int, charging: Bool) {
        let sourceInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(sourceInfo).takeRetainedValue() as Array
        for source in sources {
            guard let unmanaged = IOPSGetPowerSourceDescription(sourceInfo, source),
                  let description = unmanaged.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey as String] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? NSNumber,
                  maximum.doubleValue > 0 else { continue }
            let condition = (description[kIOPSBatteryHealthConditionKey as String] as? String)?.lowercased()
            let health: Double
            switch condition {
            case "poor": health = 60
            case "fair": health = 80
            case "good": health = 100
            default: health = 0
            }
            let charging = (description[kIOPSIsChargingKey as String] as? NSNumber)?.boolValue ?? false
            let cycles = (description["Cycle Count"] as? NSNumber)?.intValue ?? 0
            return (min(100, max(0, 100 * current.doubleValue / maximum.doubleValue)),
                    health, max(0, cycles), charging)
        }
        return (0, 0, 0, false)
    }

    /// Read cumulative block-storage counters from IOKit. This is the same
    /// kernel source used by Activity Monitor and avoids starting `iostat` on
    /// every two-second status refresh.
    private static func diskCounters() -> (read: UInt64, write: UInt64)? {
        let matching = IOServiceMatching("IOBlockStorageDriver")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var found = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties,
                                                 kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let root = properties?.takeRetainedValue() as? [String: Any],
               let statistics = root[kIOBlockStorageDriverStatisticsKey as String] as? [String: Any] {
                let read = (statistics[kIOBlockStorageDriverStatisticsBytesReadKey as String] as? NSNumber)
                    .map { UInt64(max(0, $0.int64Value)) } ?? 0
                let write = (statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey as String] as? NSNumber)
                    .map { UInt64(max(0, $0.int64Value)) } ?? 0
                totalRead &+= read
                totalWrite &+= write
                found = true
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
        return found ? (totalRead, totalWrite) : nil
    }

    private static func diskRates() -> (read: Double, write: Double) {
        guard let counters = diskCounters() else { return (0, 0) }
        let now = CFAbsoluteTimeGetCurrent()
        defer {
            previousDiskRead = counters.read
            previousDiskWrite = counters.write
            previousDiskSample = now
        }
        guard previousDiskSample > 0 else { return (0, 0) }
        let interval = now - previousDiskSample
        guard interval > 0 else { return (0, 0) }
        let readDelta = counters.read >= previousDiskRead ? counters.read - previousDiskRead : 0
        let writeDelta = counters.write >= previousDiskWrite ? counters.write - previousDiskWrite : 0
        return (Double(readDelta) / interval / 1024 / 1024,
                Double(writeDelta) / interval / 1024 / 1024)
    }

    /// Produce the stable tabular process contract consumed by RuntimeStore's
    /// safety parser. This keeps cleanup/runtime guards in the native core;
    /// destructive process controls remain a separate productivity feature.
    static func processSnapshotText() -> String? {
        guard let output = commandOutput("/bin/ps", arguments: [
            "-axo", "pid=,ppid=,uid=,lstart=,state=,etime=,%cpu=,%mem=,comm=,args="
        ]) else { return nil }
        var records: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 13, omittingEmptySubsequences: true) {
                $0 == " " || $0 == "\t"
            }
            // pid ppid uid weekday month day time year state etime cpu mem comm args
            guard fields.count >= 14,
                  Int32(fields[0]) != nil,
                  Int32(fields[1]) != nil,
                  UInt32(fields[2]) != nil else { continue }
            let identity = "\(fields[3])_\(fields[4])_\(fields[5])_\(fields[6])_\(fields[7])"
            var columns: [String] = [String(fields[0]), String(fields[1]), String(fields[2]), identity,
                                     String(fields[8]), String(fields[9]), String(fields[10]),
                                     String(fields[11]), String(fields[12])]
            columns.append(fields.dropFirst(13).map { String($0) }.joined(separator: " "))
            let record = columns.joined(separator: "\t")
            records.append(record)
        }
        return records.joined(separator: "\n")
    }

    static func commandOutput(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
        defer { timeout.cancel() }
        // Drain while the child is running. Waiting first deadlocks when a
        // large process table fills the pipe and ps cannot finish writing.
        let data = try? pipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func cpuUsage() -> Double {
        var info = host_cpu_load_info_data_t()
        // HOST_CPU_LOAD_INFO_COUNT 是 sizeof 宏，Swift 无法导入，手工等价计算。
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, host_info_t($0), &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let ticks: [natural_t] = withUnsafeBytes(of: info.cpu_ticks) { raw -> [natural_t] in
            stride(from: 0, to: raw.count, by: MemoryLayout<natural_t>.size).map {
                raw.load(fromByteOffset: $0, as: natural_t.self)
            }
        }
        var totalDelta: natural_t = 0
        var busyDelta: natural_t = 0
        for state in 0..<min(ticks.count, previousCPUTicks.count) {
            let delta = ticks[state] &- previousCPUTicks[state]
            totalDelta += delta
            // CPU_STATE_IDLE == 2（user / system / idle / nice）。
            if state != 2 { busyDelta += delta }
            previousCPUTicks[state] = ticks[state]
        }
        guard totalDelta > 0 else { return 0 }
        return min(100.0, 100.0 * Double(busyDelta) / Double(totalDelta))
    }

    private static func memoryStats() -> (percent: Double, usedBytes: UInt64,
                                           totalBytes: UInt64, availableBytes: UInt64,
                                           pressure: String) {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, host_info64_t($0), &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0, 0, "unknown") }
        var totalMemory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &totalMemory, &size, nil, 0) == 0, totalMemory > 0 else {
            return (0, 0, 0, 0, "unknown")
        }
        var pageSize = vm_size_t(0)
        host_page_size(mach_host_self(), &pageSize)
        let usage = normalizedMemoryUsage(
            totalBytes: totalMemory,
            pageSize: UInt64(pageSize),
            internalPages: UInt64(info.internal_page_count),
            purgeablePages: UInt64(info.purgeable_count),
            wiredPages: UInt64(info.wire_count),
            compressedPages: UInt64(info.compressor_page_count))
        let available = totalMemory > usage.usedBytes ? totalMemory - usage.usedBytes : 0
        let pressure: String
        switch usage.percent {
        case 85...: pressure = "critical"
        case 70..<85: pressure = "warning"
        default: pressure = "normal"
        }
        return (usage.percent, usage.usedBytes, totalMemory, available, pressure)
    }

    /// 与“应用内存 + 联动内存 + 压缩内存”的系统口径保持一致：排除
    /// file-backed/inactive 缓存，并扣除可立即回收的 purgeable 页面。
    /// 作为纯计算函数保留 internal 可见性，便于对边界值做回归测试。
    static func normalizedMemoryUsage(totalBytes: UInt64,
                                      pageSize: UInt64,
                                      internalPages: UInt64,
                                      purgeablePages: UInt64,
                                      wiredPages: UInt64,
                                      compressedPages: UInt64)
        -> (percent: Double, usedBytes: UInt64) {
        guard totalBytes > 0, pageSize > 0 else { return (0, 0) }
        let nonPurgeableInternal = internalPages > purgeablePages
            ? internalPages - purgeablePages : 0
        let (firstSum, firstOverflow) = nonPurgeableInternal.addingReportingOverflow(wiredPages)
        let (pageCount, secondOverflow) = firstSum.addingReportingOverflow(compressedPages)
        let (rawBytes, multiplyOverflow) = pageCount.multipliedReportingOverflow(by: pageSize)
        let usedBytes = (firstOverflow || secondOverflow || multiplyOverflow)
            ? totalBytes : min(rawBytes, totalBytes)
        let percent = min(100.0, 100.0 * Double(usedBytes) / Double(totalBytes))
        return (percent, usedBytes)
    }

    private static func diskUsage() -> (freeBytes: UInt64, usedPercent: Double) {
        var volume = statfs()
        let home = NSHomeDirectory() as NSString
        guard statfs(home.fileSystemRepresentation, &volume) == 0, volume.f_blocks > 0 else {
            return (0, 0)
        }
        let freeBytes = UInt64(volume.f_bavail) * UInt64(volume.f_bsize)
        let usedPercent = 100.0 * Double(volume.f_blocks - volume.f_bavail) / Double(volume.f_blocks)
        return (freeBytes, usedPercent)
    }

    private static func networkRates() -> (rx: Double, tx: Double) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var interfaces: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&interfaces) == 0 {
            var cursor = interfaces
            while let current = cursor {
                defer { cursor = current.pointee.ifa_next }
                guard current.pointee.ifa_addr != nil,
                      (current.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                      (current.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                      let data = current.pointee.ifa_data else { continue }
                let interfaceData = data.assumingMemoryBound(to: if_data.self)
                received += UInt64(interfaceData.pointee.ifi_ibytes)
                sent += UInt64(interfaceData.pointee.ifi_obytes)
            }
            freeifaddrs(interfaces)
        }
        let now = CFAbsoluteTimeGetCurrent()
        var rx: Double = 0
        var tx: Double = 0
        if previousNetworkSample > 0 {
            let interval = now - previousNetworkSample
            if interval > 0 {
                // if_data exposes 32-bit counters on some macOS versions and
                // interfaces may disappear between samples. Treat a decrease
                // as a counter reset instead of wrapping UInt64 into an
                // impossible exabytes-per-second spike.
                let receivedDelta = received >= previousNetworkRx ? received - previousNetworkRx : 0
                let sentDelta = sent >= previousNetworkTx ? sent - previousNetworkTx : 0
                rx = Double(receivedDelta) / interval / 1024 / 1024
                tx = Double(sentDelta) / interval / 1024 / 1024
            }
        }
        previousNetworkRx = received
        previousNetworkTx = sent
        previousNetworkSample = now
        return (rx, tx)
    }

    private static func cpuCounts() -> (logical: Int, physical: Int) {
        (sysctlInt("hw.logicalcpu"), sysctlInt("hw.physicalcpu"))
    }

    private static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = values.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return getloadavg(base, 3)
        }
        return count == 3 ? values : []
    }

    private struct SwapUsage {
        var total: UInt64 = 0
        var used: UInt64 = 0
    }

    /// `vm.swapusage` is a stable, read-only kernel interface.  Keep the
    /// layout local so this service does not depend on a shell or `sysctl`
    /// subprocess.
    private struct NativeSwapUsage {
        var total: UInt64 = 0
        var avail: UInt64 = 0
        var used: UInt64 = 0
        var pagesize: UInt64 = 0
    }

    private static func swapUsage() -> SwapUsage {
        var value = NativeSwapUsage()
        var size = MemoryLayout<NativeSwapUsage>.size
        guard sysctlbyname("vm.swapusage", &value, &size, nil, 0) == 0 else { return SwapUsage() }
        return SwapUsage(total: value.total, used: value.used)
    }

    private static func uptimeSeconds() -> UInt64 {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        let bootTime = Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        let now = Date().timeIntervalSince1970
        return now > bootTime ? UInt64(now - bootTime) : 0
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return Int(value)
    }

    private static func healthScore(cpu: Double, memory: Double, disk: Double,
                                    pressure: String, batteryHealth: Double = 0) -> Int {
        var score = 100
        if cpu > 80 { score -= min(20, Int((cpu - 80) / 2)) }
        if memory > 80 { score -= min(25, Int((memory - 80) / 2)) }
        if disk > 90 { score -= min(20, Int((disk - 90) * 2)) }
        if pressure == "warning" { score -= 8 }
        if pressure == "critical" { score -= 18 }
        if batteryHealth > 0 && batteryHealth < 60 { score -= 20 }
        else if batteryHealth > 0 && batteryHealth < 80 { score -= 10 }
        return max(0, min(100, score))
    }
}
