import Foundation
import Darwin
import IOKit
import IOKit.ps

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

/// Sudo-free sampling of CPU, GPU, memory and battery via Mach and IOKit.
final class SystemSampler {
    private var prevTicks: [[UInt32]] = []
    private var gpuEntry: io_registry_entry_t = 0
    private var gpuCores: Int?

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
