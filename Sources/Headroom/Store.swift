import Foundation
import AppKit
import SwiftUI

struct Point: Identifiable {
    let id: Int
    let t: Date
    let v: Double
}

enum Prefs {
    static let showCPU = "show.cpu"
    static let showGPU = "show.gpu"
    static let showMem = "show.mem"
    static let showBattery = "show.battery"
    static let showNet = "show.net"
    static let showClaude = "show.claude"
    static let showGrok = "show.grok"
    static let showCodex = "show.codex"
    static let interval = "interval"
    /// Draw the menu bar strip in color instead of as a monochrome template.
    static let colorMenuBar = "menubar.color"
    static let awakeForAgents = "awake.agents"
    static let awakeDisplay = "awake.display"
    /// AWS profile and comma-separated regions for Bedrock CloudWatch metrics; empty means auto-detect.
    static let bedrockProfile = "bedrock.profile"
    static let bedrockRegions = "bedrock.regions"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showCPU: true, showGPU: false, showMem: true, showBattery: false, showNet: false,
            showClaude: true, showGrok: true, showCodex: true, colorMenuBar: false, interval: 1.0,
            awakeForAgents: false, awakeDisplay: false,
        ])
    }

    static func bool(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static var sampleInterval: Double { max(0.5, UserDefaults.standard.double(forKey: interval)) }
}

enum Palette {
    static let cpu = NSColor(srgbRed: 0.33, green: 0.74, blue: 0.98, alpha: 1)
    static let gpu = NSColor(srgbRed: 0.69, green: 0.52, blue: 1.00, alpha: 1)
    static let mem = NSColor(srgbRed: 0.36, green: 0.85, blue: 0.60, alpha: 1)
    static let battery = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.30, alpha: 1)
    static let netDown = NSColor(srgbRed: 0.40, green: 0.58, blue: 1.00, alpha: 1)
    static let netUp = NSColor(srgbRed: 0.96, green: 0.45, blue: 0.55, alpha: 1)
    static let claude = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    static let grok = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.74, alpha: 1)
    static let bedrock = NSColor(srgbRed: 1.00, green: 0.60, blue: 0.00, alpha: 1)
    static let opencode = NSColor(srgbRed: 0.95, green: 0.45, blue: 0.70, alpha: 1)
    static let codex = NSColor(srgbRed: 0.40, green: 0.80, blue: 0.75, alpha: 1)

    static func severity(_ pct: Double?, base: NSColor) -> NSColor {
        guard let pct else { return base }
        return pct >= 90 ? .systemRed : pct >= 75 ? .systemOrange : base
    }

    static func familyColor(_ family: String, index: Int) -> Color {
        switch family {
        case "Opus": return Color(nsColor: claude)
        case "Fable": return Color(nsColor: gpu)
        case "Sonnet": return Color(nsColor: cpu)
        case "Haiku": return Color(nsColor: mem)
        case "Mythos": return Color(nsColor: battery)
        case "Grok": return Color(nsColor: grok)
        case "GLM": return Color(nsColor: opencode)
        case "GPT": return Color(nsColor: codex)
        default:
            // Anything else (Grok models, older ids) gets a distinct color by position.
            let others: [NSColor] = [.systemTeal, .systemPink, .systemYellow, .systemIndigo]
            return Color(nsColor: others[index % others.count])
        }
    }
}

final class Store: ObservableObject {
    static let historyLength = 150

    @Published var cpu: CPUSample?
    @Published var cpuHistory: [Point] = []
    @Published var gpu: Double?
    @Published var gpuSample: GPUSample?
    @Published var gpuHistory: [Point] = []
    @Published var memory: MemSample?
    @Published var memHistory: [Point] = []
    @Published var battery: BatterySample?
    @Published var net: NetSample?
    @Published var netDownHistory: [Point] = []
    @Published var netUpHistory: [Point] = []
    @Published var netInterface: NetInterface?

    @Published var claudeLimits: ClaudeLimits?
    @Published var claudeError: String?
    /// Limits of extra Claude Code logins (CLAUDE_CONFIG_DIR), drawn as more bars in the Claude card.
    @Published var claudeExtra: [ClaudeLimits] = []
    @Published var claudeUsage: UsageSummary?
    /// Providers start hidden and appear once their account answers; they hide again if not set up.
    @Published var claudeAvailable = false
    @Published var grokAvailable = false
    @Published var grokPlan: GrokPlan?
    @Published var grokError: String?
    @Published var grokUsage: UsageSummary?
    @Published var codexAvailable = false
    @Published var codexLimits: CodexLimits?
    @Published var codexError: String?
    @Published var codexUsage: UsageSummary?
    /// Account-wide Bedrock usage from CloudWatch, and the subset Claude Code logged locally.
    @Published var bedrockCloud: BedrockUsage?
    @Published var bedrockCloudUsage: UsageSummary?
    @Published var bedrockLocalUsage: UsageSummary?
    @Published var bedrockError: String?
    @Published var bedrockConfig: BedrockConfig?
    /// Local OpenCode turns (any provider it runs, e.g. a GLM coding plan).
    @Published var opencodeUsage: UsageSummary?
    @Published var indexing: String?
    @Published var usageUpdated: Date?
    /// Version of an update Sparkle found in the background, shown as a badge until its dialog is opened.
    @Published var update: String?
    /// Keep awake: end of the manual session (.distantFuture = indefinitely), and whether working agents hold it.
    @Published var awakeUntil: Date?
    @Published var awakeForAgents = false
    var awake: Bool { awakeUntil != nil || awakeForAgents }

    private var seq = 0

    /// CloudWatch covers every Bedrock caller in the account, so it replaces the local logs whenever it has data.
    var bedrockFromCloudWatch: Bool { (bedrockCloudUsage?.month.tokens ?? 0) > 0 }
    var bedrockUsage: UsageSummary? {
        if bedrockFromCloudWatch { return bedrockCloudUsage }
        return (bedrockLocalUsage?.month.tokens ?? 0) > 0 ? bedrockLocalUsage : nil
    }
    var bedrockAvailable: Bool { bedrockUsage != nil || bedrockConfig?.explicit == true }

    func record(cpu c: CPUSample?, gpu g: GPUSample?, memory m: MemSample?, network n: NetSample?) {
        let now = Date()
        seq += 1
        if let c { cpu = c; append(&cpuHistory, Point(id: seq, t: now, v: c.total)) }
        if let g { gpu = g.device; gpuSample = g; append(&gpuHistory, Point(id: seq, t: now, v: g.device)) }
        if let m { memory = m; append(&memHistory, Point(id: seq, t: now, v: m.percent)) }
        if let n {
            net = n
            append(&netDownHistory, Point(id: seq, t: now, v: n.down))
            append(&netUpHistory, Point(id: seq, t: now, v: n.up))
        }
    }

    private func append(_ arr: inout [Point], _ p: Point) {
        arr.append(p)
        if arr.count > Self.historyLength { arr.removeFirst(arr.count - Self.historyLength) }
    }
}
