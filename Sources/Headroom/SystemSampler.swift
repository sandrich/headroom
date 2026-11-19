import Foundation
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

struct CPUSample {
    var total: Double
    var user: Double
    var system: Double
    var cores: [Double]
}

/// macOS publishes no per-core GPU load, only the driver's device, renderer and tiler utilization.
struct GPUSample {
    var device: Double
    var renderer: Double?
    var tiler: Double?
    var memoryInUse: UInt64?
    var cores: Int?
}

struct MemSample {
    var used: UInt64
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical
    var pressure: Int

    var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
    var pressureName: String { pressure >= 4 ? "Critical" : pressure >= 2 ? "Warning" : "Normal" }
}

struct BatterySample {
    var percent: Double
    var charging: Bool
    var pluggedIn: Bool
    var charged: Bool
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    /// Positive while charging, negative while discharging.
    var watts: Double?
    var adapterWatts: Int?
    var cycles: Int?
    var health: Double?
    var temperature: Double?
}

/// Download and upload rates in bytes per second, and bytes moved since `since` (midnight, or launch on the first day).
struct NetSample {
    var down: Double
    var up: Double
    var totalDown: UInt64
    var totalUp: UInt64
    var since: Date
}

/// The interface macOS routes traffic through, e.g. en0 "Wi-Fi" 192.168.1.20.
struct NetInterface: Equatable {
    var name: String
    var displayName: String?
    var address: String?
}

struct NetCounter: Equatable {
    var rx: UInt64
    var tx: UInt64
}

/// Sudo-free sampling of CPU, GPU, memory, network and battery via Mach, sysctl and IOKit.
final class SystemSampler {
    private var prevTicks: [[UInt32]] = []
    private var gpuEntry: io_registry_entry_t = 0
    private var gpuCores: Int?
    private var prevNet: (time: TimeInterval, counters: [String: NetCounter])?
    private var netTotal = NetCounter(rx: 0, tx: 0)
    private var netSince = Date()
    /// Localized interface names by BSD name; listing every interface is the costly part of networkInterface().
    private var netDisplayNames: [String: String] = [:]

    deinit {
        if gpuEntry != 0 { IOObjectRelease(gpuEntry) }
    }

    // MARK: CPU

    func cpu() -> CPUSample? {
        var numCPU: natural_t = 0
        var info: processor_info_array_t?
        var numInfo: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &numInfo) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(numInfo) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        current.reserveCapacity(Int(numCPU))
        for i in 0..<Int(numCPU) {
            current.append((0..<states).map { UInt32(bitPattern: info[i * states + $0]) })
        }
        defer { prevTicks = current }
        guard prevTicks.count == current.count else { return nil }

        let iUser = Int(CPU_STATE_USER), iSys = Int(CPU_STATE_SYSTEM)
        let iIdle = Int(CPU_STATE_IDLE), iNice = Int(CPU_STATE_NICE)
        var cores: [Double] = []
        var tUser = 0.0, tSys = 0.0, tAll = 0.0
        for (c, p) in zip(current, prevTicks) {
            let user = Double(c[iUser] &- p[iUser]) + Double(c[iNice] &- p[iNice])
            let sys = Double(c[iSys] &- p[iSys])
            let idle = Double(c[iIdle] &- p[iIdle])
            let all = user + sys + idle
            cores.append(all > 0 ? (user + sys) / all * 100 : 0)
            tUser += user; tSys += sys; tAll += all
        }
        guard tAll > 0 else { return nil }
        return CPUSample(total: (tUser + tSys) / tAll * 100, user: tUser / tAll * 100,
                         system: tSys / tAll * 100, cores: cores)
    }

    // MARK: Memory

    func memory() -> MemSample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count &- stats.purgeable_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = UInt64(stats.external_page_count &+ stats.purgeable_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        // Matches Activity Monitor's "Memory Used": app + wired + compressed.
        return MemSample(used: app + wired + compressed, total: ProcessInfo.processInfo.physicalMemory,
                         app: app, wired: wired, compressed: compressed, cached: cached,
                         swapUsed: swap.xsu_used, pressure: Int(level))
    }

    // MARK: GPU

    func gpu() -> GPUSample? {
        if gpuEntry == 0 {
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
            defer { IOObjectRelease(iter) }
            while true {
                let entry = IOIteratorNext(iter)
                if entry == 0 { break }
                if gpuEntry == 0, gpuSample(entry) != nil {
                    gpuEntry = entry
                    gpuCores = (IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? NSNumber)?.intValue
                } else {
                    IOObjectRelease(entry)
                }
            }
        }
        guard gpuEntry != 0 else { return nil }
        return gpuSample(gpuEntry)
    }

    private func gpuSample(_ entry: io_registry_entry_t) -> GPUSample? {
        guard let raw = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(), let stats = raw as? [String: Any],
              let device = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return nil }
        return GPUSample(device: device,
                         renderer: (stats["Renderer Utilization %"] as? NSNumber)?.doubleValue,
                         tiler: (stats["Tiler Utilization %"] as? NSNumber)?.doubleValue,
                         memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value,
                         cores: gpuCores)
    }

    // MARK: Network

    func network() -> NetSample? {
        guard let counters = Self.interfaceCounters() else { return nil }
        // A clock that keeps running during sleep, so bytes moved in dark wakes spread over the whole sleep, not one tick.
        let now = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
        defer { prevNet = (now, counters) }
        guard let prev = prevNet, now > prev.time else { return nil }
        let d = Self.netDelta(from: prev.counters, to: counters)
        // Any change of calendar day resets, also backwards after a time zone change.
        if !Calendar.current.isDate(netSince, inSameDayAs: Date()) {
            netTotal = NetCounter(rx: 0, tx: 0)
            netSince = Calendar.current.startOfDay(for: Date())
        }
        netTotal.rx &+= d.rx
        netTotal.tx &+= d.tx
        let secs = now - prev.time
        return NetSample(down: Double(d.rx) / secs, up: Double(d.tx) / secs, totalDown: netTotal.rx, totalUp: netTotal.tx,
                         since: netSince)
    }

    /// Bytes moved per interface between two readings. A counter that went down (interface reset, wake) counts as 0.
    static func netDelta(from prev: [String: NetCounter], to cur: [String: NetCounter]) -> NetCounter {
        var d = NetCounter(rx: 0, tx: 0)
        for (name, c) in cur {
            guard let p = prev[name] else { continue }
            if c.rx >= p.rx { d.rx += c.rx - p.rx }
            if c.tx >= p.tx { d.tx += c.tx - p.tx }
        }
        return d
    }

    /// 64-bit byte counters of the en* interfaces that are up (Wi-Fi, Ethernet, USB and Thunderbolt adapters).
    /// VPN tunnels, loopback, AWDL and bridges are left out: their traffic also passes an en* interface or never leaves the Mac.
    /// getifaddrs only has 32-bit counters, which wrap at 4 GB, so this reads the routing socket's if_msghdr2 records.
    static func interfaceCounters() -> [String: NetCounter]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else { return nil }

        var result: [String: NetCounter] = [:]
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if m.ifm_flags & IFF_UP != 0, if_indextoname(UInt32(m.ifm_index), &name) != nil {
                        let n = String(cString: name)
                        if n.hasPrefix("en") { result[n] = NetCounter(rx: m.ifm_data.ifi_ibytes, tx: m.ifm_data.ifi_obytes) }
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return result
    }

    /// The primary interface with its localized name and IPv4 address (IPv6-only networks have a name but no address).
    func networkInterface() -> NetInterface? {
        let primary = ["IPv4", "IPv6"].lazy.compactMap {
            (SCDynamicStoreCopyValue(nil, "State:/Network/Global/\($0)" as CFString) as? [String: Any])?.string("PrimaryInterface")
        }.first
        guard let name = primary else { return nil }
        if netDisplayNames[name] == nil {
            let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
            netDisplayNames[name] = all.first { SCNetworkInterfaceGetBSDName($0) as String? == name }
                .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? name
        }
        let display = netDisplayNames[name]

        var address: String?
        var addrs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrs) == 0 {
            defer { freeifaddrs(addrs) }
            var p = addrs
            while let a = p {
                defer { p = a.pointee.ifa_next }
                guard String(cString: a.pointee.ifa_name) == name, let sa = a.pointee.ifa_addr,
                      sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                    break
                }
            }
        }
        return NetInterface(name: name, displayName: display, address: address)
    }

    // MARK: Battery

    func battery() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  d.string("Type") == "InternalBattery" else { continue }

            let cur = d.double("Current Capacity") ?? 0
            let max = d.double("Max Capacity") ?? 100
            let toEmpty = d.int("Time to Empty")
            let toFull = d.int("Time to Full Charge")
            var sample = BatterySample(
                percent: max > 0 ? cur / max * 100 : cur,
                charging: (d["Is Charging"] as? Bool) ?? false,
                pluggedIn: d.string("Power Source State") == "AC Power",
                charged: (d["Is Charged"] as? Bool) ?? false,
                minutesToEmpty: toEmpty > 0 ? toEmpty : nil,
                minutesToFull: toFull > 0 ? toFull : nil)
            fillSmartBattery(&sample)
            return sample
        }
        return nil
    }

    private func fillSmartBattery(_ s: inout BatterySample) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = props?.takeRetainedValue() as? [String: Any] else { return }

        // Amperage is a signed value stored as an unsigned 64-bit number.
        if let mv = (p["Voltage"] as? NSNumber)?.int64Value, let ma = (p["Amperage"] as? NSNumber)?.int64Value, mv > 0 {
            s.watts = Double(mv) * Double(ma) / 1_000_000
        }
        let cycles = p.int("CycleCount")
        s.cycles = cycles > 0 ? cycles : nil
        if let t = p.double("Temperature"), t > 0 { s.temperature = t / 100 }

        let data = p.dict("BatteryData") ?? [:]
        let design = data.double("DesignCapacity") ?? p.double("DesignCapacity")
        let nominal = data.double("NominalChargeCapacity") ?? p.double("NominalChargeCapacity") ?? p.double("AppleRawMaxCapacity")
        if let design, let nominal, design > 0 { s.health = min(nominal / design * 100, 100) }

        if let adapter = p.dict("AdapterDetails"), let w = adapter.double("Watts"), w > 0 { s.adapterWatts = Int(w) }
    }
}
