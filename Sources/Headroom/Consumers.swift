import Foundation
import Darwin
import IOKit

enum SegmentKind {
    case cpu, gpu, memory, battery, network, claude, grok, codex, awake
}

struct Consumer: Identifiable {
    var id: String { name }
    var name: String
    var value: Double
    var label: String
}

/// Per-app resource use straight from the kernel (libproc rusage) and the GPU driver's per-client
/// accounting in the IORegistry. Only runs while a hover panel is visible.
/// Helper processes are folded into their owning .app; root-owned daemons are not readable without sudo.
/// Network has no per-process kernel counter outside a private framework, so it comes from nettop.
final class ConsumerSampler {
    private struct Snapshot {
        var time: UInt64 = 0
        var cpu: [pid_t: UInt64] = [:]
        var energy: [pid_t: UInt64] = [:]
        var gpu: [pid_t: UInt64] = [:]
    }

    private var previous: Snapshot?
    private var names: [pid_t: String] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(tb.denom))
    }()

    // nettop runs on a background queue; everything below is only touched on the main thread.
    private var netPrev: (time: UInt64, bytes: [pid_t: UInt64])?
    private var netTop: [Consumer] = []
    private var netBusy = false
    private var netGeneration = 0

    func reset() {
        previous = nil
        names = [:]
        netPrev = nil
        netTop = []
        netGeneration += 1
    }

    /// Top consumers for `kind`. Rates need two samples, so the first call for CPU/GPU/battery returns [].
    func top(_ kind: SegmentKind, limit: Int = 6) -> [Consumer] {
        if kind == .network {
            sampleNetwork(limit: limit)
            return netTop
        }
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var snap = Snapshot(time: mach_absolute_time())
        var footprint: [pid_t: UInt64] = [:]

        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var ri = rusage_info_v6()
            let r = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard r == 0 else { continue }
            snap.cpu[pid] = ri.ri_user_time &+ ri.ri_system_time
            snap.energy[pid] = ri.ri_energy_nj
            footprint[pid] = ri.ri_phys_footprint
        }
        if kind == .gpu { snap.gpu = gpuTimes() }
        defer { previous = snap }

        var totals: [String: Double] = [:]
        switch kind {
        case .memory:
            for (pid, bytes) in footprint { totals[name(pid), default: 0] += Double(bytes) }
        case .cpu, .gpu, .battery:
            guard let prev = previous, snap.time > prev.time else { return [] }
            let wallNs = nanoseconds(snap.time - prev.time)
            let (now, before) = kind == .cpu ? (snap.cpu, prev.cpu) : kind == .gpu ? (snap.gpu, prev.gpu) : (snap.energy, prev.energy)
            for (pid, v) in now {
                guard let old = before[pid], v > old else { continue }
                let delta = Double(v - old)
                switch kind {
                case .cpu: totals[name(pid), default: 0] += delta * Double(timebase.numer) / Double(timebase.denom) / wallNs * 100
                case .gpu: totals[name(pid), default: 0] += delta / wallNs * 100
                default: totals[name(pid), default: 0] += delta
                }
            }
        default:
            return []
        }

        if kind == .battery {
            // Energy counters have no documented unit, so show each app's share of energy used (like Energy Impact).
            let sum = totals.values.reduce(0, +)
            guard sum > 0 else { return [] }
            totals = totals.mapValues { $0 / sum * 100 }
        }
        return ranked(totals, limit) { v in
            switch kind {
            case .memory: return Fmt.gb(UInt64(v))
            case .battery: return String(format: "%.0f%%", v)
            default: return String(format: "%.1f%%", v)
            }
        }
    }

    private func nanoseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    }

    private func ranked(_ totals: [String: Double], _ limit: Int, label: (Double) -> String) -> [Consumer] {
        totals.sorted { $0.value > $1.value }.prefix(limit).map { Consumer(name: $0.key, value: $0.value, label: label($0.value)) }
    }

    /// Starts a nettop run unless one is in flight; its rates show up on the next call.
    private func sampleNetwork(limit: Int) {
        guard !netBusy else { return }
        netBusy = true
        let generation = netGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // -t external leaves out loopback, so local dev servers and proxies do not count.
            let out = runProcess("/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-t", "external", "-J", "bytes_in,bytes_out"],
                                 timeout: 5)
            // A run killed by the timeout can end mid-line, and a cut count would read as a burst on the next run.
            let bytes = out.flatMap { $0.status == 0 ? Self.parseNettop(String(decoding: $0.output, as: UTF8.self)) : nil } ?? [:]
            let time = mach_absolute_time()
            DispatchQueue.main.async {
                guard let self else { return }
                self.netBusy = false
                guard generation == self.netGeneration, !bytes.isEmpty else { return }
                defer { self.netPrev = (time, bytes) }
                guard let prev = self.netPrev, time > prev.time else { return }
                let secs = self.nanoseconds(time - prev.time) / 1e9
                var totals: [String: Double] = [:]
                for (pid, b) in bytes {
                    // Totals drop when sockets close, so only growth counts.
                    guard let old = prev.bytes[pid], b > old else { continue }
                    totals[self.name(pid), default: 0] += Double(b - old) / secs
                }
                // An idle network has no rows; say so instead of leaving "Sampling..." up.
                self.netTop = totals.isEmpty ? [Consumer(name: "No traffic", value: 0, label: "")]
                    : self.ranked(totals, limit, label: Fmt.rate)
            }
        }
    }

    /// Bytes in plus out per pid from `nettop -P -L 1 -x -J bytes_in,bytes_out` lines like "Safari.812,1234,567,".
    /// Process names can hold dots and commas, so fields are taken from the right.
    static func parseNettop(_ csv: String) -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        for line in csv.split(whereSeparator: \.isNewline) {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false)
            if fields.last?.isEmpty == true { fields.removeLast() }
            guard fields.count >= 3, let bytesOut = UInt64(fields[fields.count - 1]),
                  let bytesIn = UInt64(fields[fields.count - 2]) else { continue }
            let id = fields[..<(fields.count - 2)].joined(separator: ",")
            guard let dot = id.lastIndex(of: "."), let pid = pid_t(id[id.index(after: dot)...]), pid > 0 else { continue }
            result[pid, default: 0] &+= bytesIn &+ bytesOut
        }
        return result
    }

    /// Accumulated GPU nanoseconds per pid from the AGX driver's user clients.
    private func gpuTimes() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        // User clients are children of the accelerator entry; they are not reachable by global matching.
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS
        else { return result }
        defer { IOObjectRelease(accelerators) }
        var clients: [io_registry_entry_t] = []
        while true {
            let acc = IOIteratorNext(accelerators)
            if acc == 0 { break }
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(acc, kIOServicePlane, &children) == KERN_SUCCESS {
                while true {
                    let c = IOIteratorNext(children)
                    if c == 0 { break }
                    clients.append(c)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(acc)
        }
        for entry in clients {
            defer { IOObjectRelease(entry) }
            guard let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let pidText = creator.split(separator: ",").first?.split(separator: " ").last,
                  let pid = pid_t(pidText),
                  let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]] else { continue }
            let ns = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
            result[pid, default: 0] += ns
        }
        return result
    }

    /// App name for a pid: the outermost .app bundle in its path, else the process name.
    private func name(_ pid: pid_t) -> String {
        if let n = names[pid] { return n }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var result = ""
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if let r = path.range(of: ".app/") {
                result = String(path[..<r.lowerBound].split(separator: "/").last ?? "")
            } else {
                // Versioned binaries (e.g. ~/.local/share/claude/versions/2.1.296) are named by their tool folder.
                let parts = path.split(separator: "/").map(String.init)
                result = parts.reversed().first { p in
                    !(p.first?.isNumber ?? false) && !["versions", "bin", "libexec", "current"].contains(p)
                } ?? parts.last ?? ""
            }
        }
        if result.isEmpty {
            var nb = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nb, UInt32(nb.count))
            result = String(cString: nb)
        }
        if result.isEmpty { result = "pid \(pid)" }
        names[pid] = result
        return result
    }
}
