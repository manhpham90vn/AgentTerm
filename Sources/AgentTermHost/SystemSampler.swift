#if os(macOS)
import AgentTermProtocol
import Darwin
import Foundation
import IOKit
import IOKit.hid
import IOKit.ps

/// Measures how the Mac itself is doing: processor, memory, network
/// speed, heat, battery and uptime.
///
/// Not thread safe: use it from one queue.
final class SystemSampler {
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var previousNetwork: (received: UInt64, sent: UInt64, at: UInt64)?
    private let sensors = TemperatureSensors()

    func sample() -> SystemStats {
        var stats = SystemStats()
        stats.cpuPercent = cpu()
        (stats.memoryUsed, stats.memoryTotal) = Self.memory()
        (stats.downBytesPerSecond, stats.upBytesPerSecond) = network()
        stats.temperature = sensors.hottest().map { ($0 * 10).rounded() / 10 }
        stats.thermalState = Self.thermalState()
        let battery = Self.battery()
        stats.batteryPercent = battery.percent
        stats.isCharging = battery.charging
        stats.isOnPower = PowerSource.isOnPower
        stats.bootedAt = Self.bootedAt()
        return stats
    }

    /// Share of all cores that was busy since the last call. Zero the first time.
    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // user, system, idle, nice
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3].map(UInt64.init)
        let total = ticks.reduce(0, +)
        let busy = total - ticks[2]
        defer { previousTicks = (busy, total) }
        guard let previousTicks, total > previousTicks.total, busy >= previousTicks.busy else { return 0 }
        return (Double(busy - previousTicks.busy) / Double(total - previousTicks.total) * 100).rounded()
    }

    /// Memory in use the way Activity Monitor counts it (app memory, wired
    /// and compressed), and what is installed.
    static func memory() -> (used: UInt64, total: UInt64) {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pages = UInt64(info.internal_page_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        let purgeable = UInt64(info.purgeable_count)
        let used = (pages > purgeable ? pages - purgeable : pages) * UInt64(pageSize)
        // To a tenth of a gigabyte, so a Mac at rest reports the same twice.
        let step: UInt64 = 107_374_182
        return (min(total, used / step * step), total)
    }

    /// Bytes a second in and out since the last call, over every interface
    /// but the loopback. Zero the first time.
    private func network() -> (down: UInt64, up: UInt64) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return (0, 0) }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let data = current.pointee.ifa_data
            else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(counters.ifi_ibytes)
            sent += UInt64(counters.ifi_obytes)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        defer { previousNetwork = (received, sent, now) }
        // The counters are 32 bits wide and start over; an interface can
        // also go away. Either way a smaller total means no figure this time.
        guard let previousNetwork, now > previousNetwork.at, received >= previousNetwork.received, sent >= previousNetwork.sent else { return (0, 0) }
        let seconds = Double(now - previousNetwork.at) / 1_000_000_000
        func rate(_ bytes: UInt64) -> UInt64 {
            // To a kilobyte, so an idle network reports the same twice.
            UInt64((Double(bytes) / seconds / 1024).rounded()) * 1024
        }
        return (rate(received - previousNetwork.received), rate(sent - previousNetwork.sent))
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        default: return "nominal"
        }
    }

    /// Charge of the internal battery, if the Mac has one.
    static func battery() -> (percent: Int?, charging: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, false) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int, let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0
            else { continue }
            return (min(100, current * 100 / capacity), description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return (nil, false)
    }

    static func bootedAt() -> Date {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else {
            return Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }
}

// The Mac's temperature sensors are read through IOKit's HID event system,
// which Apple silicon exposes them on. These calls are part of IOKit but
// are not in its headers, so they are declared here; where they find
// nothing, on an Intel Mac for one, no temperature is reported and the
// apps fall back on what macOS says about the Mac's heat.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClient?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClient, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClient, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

private final class TemperatureSensors {
    private static let temperatureEvent: Int64 = 15
    private let client: IOHIDEventSystemClient?
    private var services: [IOHIDServiceClient] = []
    private var lookedUp = Date.distantPast

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        // Apple's vendor page, usage "temperature sensor".
        if let client { _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary) }
    }

    /// The hottest of the processor's sensors, in degrees Celsius.
    func hottest() -> Double? {
        guard let client else { return nil }
        // The list of sensors does not change; it is read again now and
        // then in case it was not there yet.
        if services.isEmpty, Date().timeIntervalSince(lookedUp) > 60 {
            lookedUp = Date()
            let all = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
            // The sensors on the processor itself ("PMU tdie1", …), or
            // every sensor where none is named that way.
            let onDie = all.filter { (IOHIDServiceClientCopyProperty($0, "Product" as CFString) as? String)?.lowercased().contains("tdie") == true }
            services = onDie.isEmpty ? all : onDie
        }
        var hottest: Double?
        for service in services {
            guard let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(Self.temperatureEvent << 16))
            // A sensor that is not there reads as nonsense.
            guard value > 0, value < 130 else { continue }
            hottest = max(hottest ?? value, value)
        }
        return hottest
    }
}
#endif
