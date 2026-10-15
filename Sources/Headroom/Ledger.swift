import Foundation

// MARK: - Aggregates

struct Agg: Codable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var calls = 0
    /// Exact provider cost in 1e-10 USD ticks (Grok reports this; Claude cost comes from pricing).
    var costTicks: Int?

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    /// Field-wise growth from `old` to self (never negative); used when a streamed message is logged again.
    func growth(from old: Agg) -> Agg {
        Agg(input: max(input - old.input, 0), output: max(output - old.output, 0),
            cacheWrite5m: max(cacheWrite5m - old.cacheWrite5m, 0), cacheWrite1h: max(cacheWrite1h - old.cacheWrite1h, 0),
            cacheRead: max(cacheRead - old.cacheRead, 0), calls: 0)
    }

    func maxed(with o: Agg) -> Agg {
        Agg(input: max(input, o.input), output: max(output, o.output), cacheWrite5m: max(cacheWrite5m, o.cacheWrite5m),
            cacheWrite1h: max(cacheWrite1h, o.cacheWrite1h), cacheRead: max(cacheRead, o.cacheRead), calls: max(calls, o.calls))
    }

    mutating func add(_ o: Agg) {
        input += o.input; output += o.output
        cacheWrite5m += o.cacheWrite5m; cacheWrite1h += o.cacheWrite1h
        cacheRead += o.cacheRead; calls += o.calls
        if let t = o.costTicks { costTicks = (costTicks ?? 0) + t }
    }
}

struct Totals {
    var tokens = 0
    var cost = 0.0
}

struct DayBar: Identifiable {
    var id: String { "\(day.timeIntervalSince1970)-\(family)" }
    var day: Date
    var family: String
    var tokens: Int
    var cost: Double
}

struct ModelRow: Identifiable {
    var id: String { model }
    var model: String
    var tokens: Int
    var cost: Double?
}

struct UsageSummary {
    var today = Totals()
    var week = Totals()
    var month = Totals()
    var window: Totals?
    var bars: [DayBar] = []
    var models: [ModelRow] = []
    var monthStart = Date()
}

extension UsageSummary {
    /// Adds two providers' summaries; the 5h window is Claude-only and comes from `a`.
    /// Model ids must not overlap between the two (Bedrock rows are prefixed or region-qualified).
    static func combine(_ a: UsageSummary?, _ b: UsageSummary?) -> UsageSummary? {
        guard var r = a ?? b else { return nil }
        guard let a, let b else { return r }
        func add(_ x: Totals, _ y: Totals) -> Totals { Totals(tokens: x.tokens + y.tokens, cost: x.cost + y.cost) }
        r.today = add(a.today, b.today)
        r.week = add(a.week, b.week)
        r.month = add(a.month, b.month)
        r.bars = (a.bars + b.bars).sorted { ($0.day, $0.family) < ($1.day, $1.family) }
        r.models = (a.models + b.models).sorted { $0.tokens > $1.tokens }
        return r
    }
}

func modelFamily(_ model: String) -> String {
    let m = model.lowercased()
    for f in ["opus", "fable", "sonnet", "haiku", "mythos"] where m.contains(f) { return f.prefix(1).uppercased() + f.dropFirst() }
    if m.hasPrefix("grok") { return "Grok" }
    return model
}

// MARK: - Pricing (LiteLLM table, cached daily)

struct Price: Codable {
    var input: Double
    var output: Double
    var cacheWrite: Double
    var cacheWrite1h: Double
    var cacheRead: Double
}

final class Pricing {
    static let shared = Pricing()
    private let lock = NSLock()
    private var table: [String: Price] = [:]
    private let file = appSupportDir.appendingPathComponent("pricing.json")
    private let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    func load() {
        if let data = try? Data(contentsOf: file), let t = try? JSONDecoder().decode([String: Price].self, from: data) {
            lock.withLock { table = t }
        }
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { -$0.timeIntervalSinceNow } ?? .infinity
        if age > 86400 || table.isEmpty { Task.detached { await self.download() } }
    }

    private func download() async {
        guard let (data, _) = try? await URLSession.shared.data(from: source),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var t: [String: Price] = [:]
        // Bedrock ids (`anthropic.claude-...`, `au.anthropic.claude-...-v1:0`) carry regional prices.
        for (k, v) in json where k.hasPrefix("claude") || k.contains("anthropic.claude") {
            guard let v = v as? [String: Any], let input = v.double("input_cost_per_token"),
                  let output = v.double("output_cost_per_token") else { continue }
            let write = v.double("cache_creation_input_token_cost") ?? input * 1.25
            t[k] = Price(input: input, output: output, cacheWrite: write,
                         cacheWrite1h: v.double("cache_creation_input_token_cost_above_1hr") ?? input * 2,
                         cacheRead: v.double("cache_read_input_token_cost") ?? input * 0.1)
        }
        guard !t.isEmpty else { return }
        lock.withLock { table = t; resolved = [:] }
        if let data = try? JSONEncoder().encode(t) { try? data.write(to: file, options: .atomic) }
    }

    private var resolved: [String: Price?] = [:]

    func cost(model: String, _ a: Agg) -> Double? {
        if let ticks = a.costTicks { return Double(ticks) / 1e10 }
        let p: Price? = lock.withLock {
            if let hit = resolved[model] { return hit }
            var p = table[model]
            // bedrock/claude-sonnet-5, au.anthropic.claude-haiku-4-5-20251001-v1:0 -> claude-...
            var base = model.hasPrefix(Ledger.bedrockPrefix) ? String(model.dropFirst(Ledger.bedrockPrefix.count)) : model
            if let r = base.range(of: "anthropic.") { base = String(base[r.upperBound...]) }
            if let r = base.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { base = String(base[..<r.lowerBound]) }
            if p == nil { p = table[base] }
            // claude-haiku-4-5-20251001 -> claude-haiku-4-5
            if p == nil, let r = base.range(of: #"-\d{8}$"#, options: .regularExpression) { p = table[String(base[..<r.lowerBound])] }
            if !table.isEmpty { resolved[model] = p }
            return p
        }
        guard let p else { return nil }
        return Double(a.input) * p.input + Double(a.output) * p.output + Double(a.cacheWrite5m) * p.cacheWrite
            + Double(a.cacheWrite1h) * p.cacheWrite1h + Double(a.cacheRead) * p.cacheRead
    }
}

// MARK: - Ledger

/// Incremental token ledger over Claude Code transcripts and Grok session usage files.
/// Claude: tail-reads ~/.claude/projects/**/*.jsonl by byte offset, dedupes on message id + request id
/// (same rule as ccusage), and buckets per hour and model. State is cached on disk so relaunches are instant.
/// Turns Claude Code ran through AWS Bedrock (message ids `msg_bdrk_...`) are kept apart under `bedrock/<model>`.
final class Ledger {
    static let bedrockPrefix = "bedrock/"

    private struct FileMark: Codable { var offset: UInt64 }
    /// What has been counted for one message id + request id, per model.
    private struct Seen: Codable { var hour: Int; var parts: [String: Agg] }
    private struct State: Codable {
        var version = 5
        var files: [String: FileMark] = [:]
        var seen: [String: Seen] = [:]
        var hours: [Int: [String: Agg]] = [:]
    }
    private struct GrokTurn { var key: String; var hour: Int; var model: String; var agg: Agg }
    private struct GrokFile { var mtime: Date; var turns: [GrokTurn] }

    static let retentionDays = 32

    private let queue = DispatchQueue(label: "headroom.ledger", qos: .utility)
    private var state = State()
    private var loaded = false
    private var dirty = false
    private var lastSave = Date.distantPast
    private var grokFiles: [String: GrokFile] = [:]
    /// Transcripts modified in the last two hours; tailed on every refresh between full scans.
    private var hotFiles: Set<String> = []
    private var lastFullScan = Date.distantPast
    /// Newest transcript write seen (Claude or Grok), used to tell when an agent is working.
    private var lastActivity = Date.distantPast
    private var changeCounter = 0
    private var lastSummaryKey = ""
    private var cachedSummaries: (UsageSummary, UsageSummary, UsageSummary)?
    private let cacheFile = appSupportDir.appendingPathComponent("claude-ledger.json")
    private let usageNeedle = Array(#""usage":{"#.utf8)

    /// Cowork session transcript folders, found on each full scan.
    private var coworkRoots: [URL] = []

    private var claudeRoots: [URL] {
        [homeDir.appendingPathComponent(".claude/projects"), homeDir.appendingPathComponent(".config/claude/projects")] + coworkRoots
    }

    /// The desktop app runs each Cowork session with its own Claude Code config folder under
    /// local-agent-mode-sessions. Only its `.claude/projects` transcripts are read; the audit.jsonl next to them
    /// repeats the same messages.
    private static func findCoworkRoots() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            let projects = dir.appendingPathComponent(".claude/projects")
            if fm.fileExists(atPath: projects.path) { out.append(projects); return }
            guard depth < 4, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles]) else { return }
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                walk(item, depth: depth + 1)
            }
        }
        for app in ["Claude", "Claude-3p"] {
            walk(homeDir.appendingPathComponent("Library/Application Support/\(app)/local-agent-mode-sessions"), depth: 0)
        }
        return out
    }

    /// Scans for new data and returns summaries. `progress` reports indexing on first run.
    func refresh(windowStart: Date?, progress: @escaping (String?) -> Void,
                 completion: @escaping (_ claude: UsageSummary, _ grok: UsageSummary, _ bedrock: UsageSummary,
                                        _ lastActivity: Date) -> Void) {
        queue.async { [self] in
            if !loaded { loadCache(); loaded = true }
            let full = Date().timeIntervalSince(lastFullScan) >= 300
            if full {
                scanClaude(progress: progress)
                scanGrok()
                lastFullScan = Date()
            } else {
                discoverNewFiles()
                tailHotFiles()
                scanGrok()
            }
            // Encoding the cache is the most expensive step, so only persist occasionally (and on quit).
            if dirty, lastSave == .distantPast || Date().timeIntervalSince(lastSave) > 600 {
                saveCache()
            }
            progress(nil)
            // Summaries only change with new data, a new window, or a new day.
            let key = "\(changeCounter)|\(windowStart?.timeIntervalSince1970 ?? 0)|\(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)"
            if key != lastSummaryKey || cachedSummaries == nil {
                cachedSummaries = (Self.summarize(claudeHours(bedrock: false), windowStart: windowStart),
                                   Self.summarize(grokHours(), windowStart: nil),
                                   Self.summarize(claudeHours(bedrock: true), windowStart: nil))
                lastSummaryKey = key
            }
            completion(cachedSummaries!.0, cachedSummaries!.1, cachedSummaries!.2, lastActivity)
        }
    }

    func flush() {
        queue.sync { if dirty { saveCache() } }
    }

    // MARK: Claude

    private func scanClaude(progress: (String?) -> Void) {
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var candidates: [(String, UInt64)] = []
        var present = Set<String>()
        var hot = Set<String>()
        let hotCutoff = Date().addingTimeInterval(-2 * 3600)
        coworkRoots = Self.findCoworkRoots()

        for root in claudeRoots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let mtime = v.contentModificationDate, mtime >= cutoff else { continue }
                let path = url.path
                present.insert(path)
                if mtime >= hotCutoff { hot.insert(path); lastActivity = max(lastActivity, mtime) }
                let size = UInt64(v.fileSize ?? 0)
                if state.files[path]?.offset != size { candidates.append((path, size)) }
            }
        }

        hotFiles = hot
        let initial = state.files.isEmpty
        for (i, (path, size)) in candidates.enumerated() {
            if initial, i % 25 == 0 { progress("Indexing Claude logs \(i)/\(candidates.count)") }
            var offset = state.files[path]?.offset ?? 0
            if size < offset { offset = 0 } // rewritten file; dedupe keys prevent double counting
            offset = ingestClaudeFile(path, from: offset)
            state.files[path] = FileMark(offset: offset)
            dirty = true
        }

        // Forget files that aged out or were removed, and prune old buckets and dedupe keys.
        let stale = state.files.keys.filter { !present.contains($0) }
        if !stale.isEmpty { stale.forEach { state.files.removeValue(forKey: $0) }; dirty = true }
        let minHour = Int(cutoff.timeIntervalSince1970 / 3600)
        if state.hours.keys.contains(where: { $0 < minHour }) {
            state.hours = state.hours.filter { $0.key >= minHour }
            state.seen = state.seen.filter { $0.value.hour >= minHour }
            dirty = true
        }
    }

    /// Cheap new-file check between full scans: only lists project folders touched in the last two hours.
    private func discoverNewFiles() {
        let hotCutoff = Date().addingTimeInterval(-2 * 3600)
        let fm = FileManager.default
        func recent(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >= hotCutoff
        }
        for root in claudeRoots {
            guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for dir in projects where recent(dir) {
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for f in items where f.pathExtension == "jsonl" && !hotFiles.contains(f.path) && recent(f) {
                    hotFiles.insert(f.path)
                }
            }
        }
        // Subagent transcripts live next to their parent session.
        for path in hotFiles where path.hasSuffix(".jsonl") && !path.contains("/subagents/") {
            let sub = URL(fileURLWithPath: String(path.dropLast(6))).appendingPathComponent("subagents")
            guard recent(sub), let items = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) else { continue }
            for f in items where f.pathExtension == "jsonl" { hotFiles.insert(f.path) }
        }
    }

    private func tailHotFiles() {
        for path in hotFiles {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            if let m = attrs[.modificationDate] as? Date { lastActivity = max(lastActivity, m) }
            var offset = state.files[path]?.offset ?? 0
            if size == offset { continue }
            if size < offset { offset = 0 }
            state.files[path] = FileMark(offset: ingestClaudeFile(path, from: offset))
            dirty = true
        }
    }

    /// Reads complete lines from `offset` and returns the new offset (just past the last newline).
    /// The file is memory-mapped, so even multi-hundred-megabyte transcripts are not copied into memory.
    private func ingestClaudeFile(_ path: String, from offset: UInt64) -> UInt64 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
              UInt64(data.count) > offset else { return offset }
        let consumed = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return Int(offset) }
            let n = raw.count
            var start = Int(offset)
            while start < n, let nl = memchr(base + start, 0x0A, n - start) {
                let end = base.distance(to: UnsafeRawPointer(nl))
                if end > start, memmem(base + start, end - start, usageNeedle, usageNeedle.count) != nil {
                    autoreleasepool {
                        ingestClaudeLine(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                              count: end - start, deallocator: .none))
                    }
                }
                start = end + 1
            }
            return start
        }
        return UInt64(consumed)
    }

    private func ingestClaudeLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj.string("type") == "assistant",
              let msg = obj.dict("message"), let usage = msg.dict("usage"),
              let date = ISO.parse(obj.string("timestamp")) else { return }
        let model = msg.string("model") ?? "unknown"
        if model == "<synthetic>" { return }
        let hour = Int(date.timeIntervalSince1970 / 3600)

        var parts: [String: Agg] = [model: Self.agg(usage)]
        // Sub-calls made inside a turn (e.g. the advisor) are listed as extra iterations with their own
        // model; the top-level usage only covers the main model's iterations.
        for it in usage["iterations"] as? [[String: Any]] ?? [] {
            guard let sub = it.string("model"), sub != model, it.string("type") != "message" else { continue }
            parts[sub, default: Agg(calls: 0)].add(Self.agg(it))
        }
        if msg.string("id")?.hasPrefix("msg_bdrk_") == true {
            parts = Dictionary(uniqueKeysWithValues: parts.map { (Self.bedrockPrefix + $0.key, $0.value) })
        }

        guard let id = msg.string("id") else {
            for (m, a) in parts { state.hours[hour, default: [:]][m, default: Agg()].add(a) }
            changeCounter += 1
            return
        }
        // Bedrock and Cowork transcripts often omit the request id; the message id alone is still unique.
        let key = id + ":" + (obj.string("requestId") ?? "")
        if var old = state.seen[key] {
            // Streaming logs the same message several times with growing counts; count only the growth.
            for (m, a) in parts {
                let prev = old.parts[m] ?? Agg(calls: 0)
                let delta = a.growth(from: prev)
                guard delta.total > 0 else { continue }
                state.hours[old.hour, default: [:]][m, default: Agg()].add(delta)
                old.parts[m] = a.maxed(with: prev)
                changeCounter += 1
            }
            state.seen[key] = old
        } else {
            for (m, a) in parts { state.hours[hour, default: [:]][m, default: Agg()].add(a) }
            state.seen[key] = Seen(hour: hour, parts: parts)
            changeCounter += 1
        }
    }

    private static func agg(_ usage: [String: Any]) -> Agg {
        var a = Agg(input: usage.int("input_tokens"), output: usage.int("output_tokens"),
                    cacheRead: usage.int("cache_read_input_tokens"), calls: 1)
        let created = usage.int("cache_creation_input_tokens")
        if let cc = usage.dict("cache_creation") {
            a.cacheWrite1h = cc.int("ephemeral_1h_input_tokens")
            a.cacheWrite5m = cc.int("ephemeral_5m_input_tokens")
            // Fall back to the flat total when the breakdown does not add up.
            if a.cacheWrite1h + a.cacheWrite5m != created { a.cacheWrite5m = created; a.cacheWrite1h = 0 }
        } else {
            a.cacheWrite5m = created
        }
        return a
    }

    /// Claude subscription/API turns, or only the ones Claude Code sent through Bedrock.
    private func claudeHours(bedrock: Bool) -> [Int: [String: Agg]] {
        var out: [Int: [String: Agg]] = [:]
        for (h, byModel) in state.hours {
            let picked = byModel.filter { $0.key.hasPrefix(Self.bedrockPrefix) == bedrock }
            if !picked.isEmpty { out[h] = picked }
        }
        return out
    }

    // MARK: Grok

    private func scanGrok() {
        let root = homeDir.appendingPathComponent(".grok/sessions")
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        var present = Set<String>()
        for p in projects {
            let dir = root.appendingPathComponent(p)
            guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for s in sessions {
                let url = dir.appendingPathComponent(s).appendingPathComponent("usage.json")
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                present.insert(url.path)
                lastActivity = max(lastActivity, mtime)
                if grokFiles[url.path]?.mtime == mtime { continue }
                grokFiles[url.path] = GrokFile(mtime: mtime, turns: parseGrokUsage(url))
                changeCounter += 1
            }
        }
        grokFiles = grokFiles.filter { present.contains($0.key) }
    }

    private func parseGrokUsage(_ url: URL) -> [GrokTurn] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let turns = json["turns"] as? [[String: Any]] else { return [] }
        return turns.compactMap { t in
            guard let ended = t.string("endedAt"), let date = ISO.parse(ended) else { return nil }
            let cached = t.int("cachedReadTokens")
            let agg = Agg(input: max(t.int("inputTokens") - cached, 0), output: t.int("outputTokens"),
                          cacheWrite5m: t.int("cacheCreationTokens"), cacheRead: cached,
                          calls: t.int("modelCalls"), costTicks: t.int("costUsdTicks"))
            // Resumed and forked sessions repeat inherited turns, so dedupe on content.
            let key = "\(ended)|\(t.int("totalTokens"))|\(t.int("costUsdTicks"))"
            return GrokTurn(key: key, hour: Int(date.timeIntervalSince1970 / 3600),
                            model: t.string("primaryModelId") ?? "grok", agg: agg)
        }
    }

    private func grokHours() -> [Int: [String: Agg]] {
        var seen = Set<String>()
        var hours: [Int: [String: Agg]] = [:]
        for f in grokFiles.values {
            for t in f.turns where seen.insert(t.key).inserted {
                hours[t.hour, default: [:]][t.model, default: Agg()].add(t.agg)
            }
        }
        return hours
    }

    // MARK: Summaries

    /// Calendar-day windows like ccusage: today, the last 7 days and the last 30 days, all including today.
    static func summarize(_ hours: [Int: [String: Agg]], windowStart: Date?) -> UsageSummary {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        let monthStart = cal.date(byAdding: .day, value: -29, to: today)!
        let windowHour = windowStart.map { Int($0.timeIntervalSince1970 / 3600) }

        var s = UsageSummary(monthStart: monthStart)
        if windowHour != nil { s.window = Totals() }
        var bars: [String: DayBar] = [:]
        var models: [String: (Int, Double?)] = [:]

        for (hour, byModel) in hours {
            let date = Date(timeIntervalSince1970: Double(hour) * 3600)
            guard date >= monthStart else { continue }
            let day = cal.startOfDay(for: date)
            for (model, a) in byModel {
                let cost = Pricing.shared.cost(model: model, a)
                let c = cost ?? 0
                let t = a.total
                s.month.tokens += t; s.month.cost += c
                if date >= weekStart { s.week.tokens += t; s.week.cost += c }
                if date >= today { s.today.tokens += t; s.today.cost += c }
                if let wh = windowHour, hour >= wh { s.window!.tokens += t; s.window!.cost += c }

                let family = modelFamily(model)
                let key = "\(day.timeIntervalSince1970)-\(family)"
                var bar = bars[key] ?? DayBar(day: day, family: family, tokens: 0, cost: 0)
                bar.tokens += t; bar.cost += c
                bars[key] = bar

                var m = models[model] ?? (0, 0)
                m.0 += t
                m.1 = (m.1 != nil && cost != nil) ? m.1! + cost! : nil
                models[model] = m
            }
        }
        s.bars = bars.values.sorted { ($0.day, $0.family) < ($1.day, $1.family) }
        s.models = models.map { ModelRow(model: $0.key, tokens: $0.value.0, cost: $0.value.1) }
            .sorted { $0.tokens > $1.tokens }
        return s
    }

    // MARK: Cache

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFile),
              let s = try? JSONDecoder().decode(State.self, from: data), s.version == State().version else { return }
        state = s
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: cacheFile, options: .atomic)
        dirty = false
        lastSave = Date()
    }
}
