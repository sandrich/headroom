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
        if let d = frac.date(from: s) ?? plain.date(from: s) { return d }
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let rest = s[s.index(after: dot)...]
        let end = rest.firstIndex(where: { !$0.isNumber }) ?? s.endIndex
        return plain.date(from: String(s[..<dot]) + String(s[end...]))
    }
}

let appSupportDir: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Headroom", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

let homeDir = FileManager.default.homeDirectoryForCurrentUser

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
