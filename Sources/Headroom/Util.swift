import Foundation

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
        return "\(n)"
    }

    static func usd(_ v: Double?) -> String {
        guard let v else { return "n/a" }
        if v >= 1000 { return String(format: "$%.1fk", v / 1000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }

    static func gb(_ b: UInt64) -> String {
        String(format: "%.1f GB", Double(b) / 1_073_741_824)
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "--" }
        return "\(Int(v.rounded()))%"
    }

    static func until(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Int(-date.timeIntervalSinceNow)
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    static func duration(minutes m: Int) -> String {
        "\(m / 60):" + String(format: "%02d", m % 60)
    }
}

enum ISO {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses ISO 8601 timestamps with any number of fractional digits and either Z or +hh:mm.
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = fast(s) ?? frac.date(from: s) ?? plain.date(from: s) { return d }
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let rest = s[s.index(after: dot)...]
        let end = rest.firstIndex(where: { !$0.isNumber }) ?? s.endIndex
        return plain.date(from: String(s[..<dot]) + String(s[end...]))
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fff]Z`, the form every transcript writes; the formatter was 40% of a cold index.
    static func fast(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u[19] == (u.count == 20 ? 90 : 46),
              u.last == 90 else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for c in u[r] { guard c >= 48, c <= 57 else { return nil }; v = v * 10 + Int(c - 48) }
            return v
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10), let h = num(11..<13), let mi = num(14..<16),
              let sec = num(17..<19), (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 60 else { return nil }
        var fraction = 0.0, scale = 0.1
        for c in u[min(20, u.count - 1)..<(u.count - 1)] {
            guard c >= 48, c <= 57 else { return nil }
            fraction += Double(c - 48) * scale
            scale /= 10
        }
        // Days since 1970-01-01 from the proleptic Gregorian calendar (Howard Hinnant's days_from_civil).
        let yy = mo <= 2 ? y - 1 : y
        let era = yy / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
        return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + sec) + fraction)
    }
}

let appSupportDir: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Headroom", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

let homeDir = FileManager.default.homeDirectoryForCurrentUser
/// nil for `swift build` debug builds, which have no Info.plist.
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

/// Runs a binary and returns its exit status, stdout and (if asked for) stderr. Kills it after `timeout` seconds.
@discardableResult
func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 10, captureOutput: Bool = true,
                captureErrors: Bool = false) -> (status: Int32, output: Data, errors: Data)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe(), errPipe = Pipe()
    p.standardOutput = captureOutput ? pipe : FileHandle.nullDevice
    p.standardError = captureErrors ? errPipe : FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if p.isRunning { p.terminate() }
    }
    // Drain stderr concurrently so a chatty process cannot block on a full pipe.
    var errors = Data()
    let group = DispatchGroup()
    if captureErrors {
        DispatchQueue.global().async(group: group) { errors = errPipe.fileHandleForReading.readDataToEndOfFile() }
    }
    let data = captureOutput ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    p.waitUntilExit()
    group.wait()
    return (p.terminationStatus, data, errors)
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
    func double(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func string(_ k: String) -> String? { self[k] as? String }
}
