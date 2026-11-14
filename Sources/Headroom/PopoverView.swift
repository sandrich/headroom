import SwiftUI
import Charts
import ServiceManagement

extension Color {
    static let cpu = Color(nsColor: Palette.cpu)
    static let gpu = Color(nsColor: Palette.gpu)
    static let mem = Color(nsColor: Palette.mem)
    static let battery = Color(nsColor: Palette.battery)
    static let claude = Color(nsColor: Palette.claude)
    static let grok = Color(nsColor: Palette.grok)
    static let bedrock = Color(nsColor: Palette.bedrock)
    static let opencode = Color(nsColor: Palette.opencode)
    static let codex = Color(nsColor: Palette.codex)

    static func severity(_ pct: Double, base: Color) -> Color {
        pct >= 90 ? .red : pct >= 75 ? .orange : base
    }
}

struct PopoverActions {
    var refresh: () -> Void
    var configureBedrock: () -> Void
    var quit: () -> Void
    var keepAwake: (AwakeSession) -> Void
    var checkForUpdates: () -> Void
}

/// One-line keep-awake state, shared by the footer and the menu bar hover.
func awakeStatus(_ store: Store) -> String {
    if let until = store.awakeUntil {
        if until == .distantFuture { return "Awake indefinitely" }
        return "Awake for \(Fmt.until(until)), until \(until.formatted(date: .omitted, time: .shortened))"
    }
    return store.awakeForAgents ? "Awake while Claude Code, Grok or Codex works" : "Sleep allowed"
}

struct PopoverView: View {
    @ObservedObject var store: Store
    let actions: PopoverActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    SystemGrid(store: store)
                    LimitsCard(store: store)
                }
                .frame(width: 330)
                UsageCard(store: store)
                    .frame(width: 330)
            }
            Footer(store: store, actions: actions)
        }
        .padding(14)
        .fixedSize()
    }
}

// MARK: - Building blocks

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct CardHeader: View {
    let title: String
    let icon: String
    let tint: Color
    var trailing: String?
    /// More tinted chips after `trailing`, one per extra account.
    var badges: [(text: String, tint: Color)] = []

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 11, weight: .semibold))
            // Never wrap the title; in the narrow metric cards the big number next to it gives way instead.
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.15)))
            }
            ForEach(badges.indices, id: \.self) { i in
                Text(badges[i].text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(badges[i].tint.opacity(0.15)))
            }
        }
    }
}

struct BigNumber: View {
    let text: String
    var color: Color = .primary
    var body: some View {
        // Laid out before the card title and scaled down only when "BATTERY 100%" would not fit.
        Text(text).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.75).layoutPriority(1)
            .foregroundStyle(color).contentTransition(.numericText())
    }
}

/// Live area chart with a fixed time window so it scrolls smoothly as samples arrive.
struct LiveChart: View {
    let points: [Point]
    let tint: Color
    var span: TimeInterval = 120

    var body: some View {
        let end = points.last?.t ?? Date()
        let start = end.addingTimeInterval(-span)
        Chart(points.filter { $0.t >= start }) { p in
            AreaMark(x: .value("t", p.t), y: .value("v", p.v))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.5), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", p.t), y: .value("v", p.v))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.primary.opacity(0.12))
            }
        }
        .animation(nil, value: points.count)
        .clipped()
    }
}

/// Capsule progress bar with an optional pace marker showing where usage would be if spread evenly.
struct UsageBar: View {
    let percent: Double
    let tint: Color
    var pace: Double?
    /// Thinner, with a shorter pace marker, when several bars stack in one row.
    var stacked = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, g.size.width * min(percent, 100) / 100))
                if let pace {
                    Rectangle().fill(Color.primary.opacity(0.65))
                        .frame(width: 1.5, height: g.size.height + (stacked ? 2 : 4))
                        .offset(x: g.size.width * min(max(pace, 0), 100) / 100 - 0.75)
                }
            }
        }
        .frame(height: stacked ? 4 : 6)
    }
}

struct LimitRow: View {
    /// One bar per account that has this limit; the first one names the row.
    let bars: [(entry: LimitEntry, tint: Color)]

    init(entry: LimitEntry, tint: Color) { bars = [(entry, tint)] }
    init(bars: [(entry: LimitEntry, tint: Color)]) { self.bars = bars }

    private func pace(_ entry: LimitEntry) -> Double? {
        guard let w = entry.window, let r = entry.resetsAt else { return nil }
        return (1 - r.timeIntervalSinceNow / w) * 100
    }

    /// With several accounts each reset time takes its account's color.
    private var resets: Text? {
        let dated = bars.compactMap { b in b.entry.resetsAt.map { (Fmt.until($0), b.tint) } }
        guard !dated.isEmpty else { return nil }
        if bars.count == 1 { return Text("resets in \(dated[0].0)") }
        return dated.enumerated().reduce(Text("resets in ")) { t, d in
            t + Text(d.offset > 0 ? " · " : "") + Text(d.element.0).foregroundColor(d.element.1)
        }
    }

    var body: some View {
        let entry = bars[0].entry
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.name).font(.system(size: 12, weight: .medium))
                Spacer()
                ForEach(bars.indices, id: \.self) { i in
                    Text(Fmt.pct(bars[i].entry.percent)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color.severity(bars[i].entry.percent, base: bars.count == 1 ? .primary : bars[i].tint))
                }
            }
            VStack(spacing: 5) {
                ForEach(bars.indices, id: \.self) { i in
                    UsageBar(percent: bars[i].entry.percent, tint: Color.severity(bars[i].entry.percent, base: bars[i].tint),
                             pace: pace(bars[i].entry), stacked: bars.count > 1)
                }
            }
            HStack {
                if let note = entry.note { Text(note) }
                Spacer()
                resets
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct StatTile: View {
    let title: String
    let totals: Totals?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(totals.map { Fmt.tokens($0.tokens) } ?? "--")
                .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(totals.map { Fmt.usd($0.cost) } ?? " ")
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

enum DailyMetric: String, CaseIterable, Identifiable {
    case cost = "Cost", tokens = "Tokens"
    var id: String { rawValue }
}

struct DailyChart: View {
    let summary: UsageSummary
    let metric: DailyMetric
    var height: CGFloat = 110

    private var families: [String] { Array(Set(summary.bars.map(\.family))).sorted() }

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        Chart(summary.bars) { b in
            BarMark(x: .value("Day", b.day, unit: .day),
                    y: .value(metric.rawValue, metric == .cost ? b.cost : Double(b.tokens) / 1e6))
                .foregroundStyle(by: .value("Model", b.family))
                .cornerRadius(1.5)
        }
        .chartForegroundStyleScale(domain: families, range: families.enumerated().map { Palette.familyColor($1, index: $0) })
        .chartXScale(domain: summary.monthStart...end)
        .chartXAxis {
            AxisMarks(values: (0..<4).compactMap { Calendar.current.date(byAdding: .day, value: $0 * 7, to: summary.monthStart) }) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(metric == .cost ? Fmt.usd(d) : "\(Fmt.tokens(Int(d * 1e6)))").font(.system(size: 9))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        .frame(height: height)
    }
}

// MARK: - System

struct SystemGrid: View {
    @ObservedObject var store: Store

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                MetricCard(title: "CPU", icon: "cpu", tint: .cpu, value: store.cpu?.total, history: store.cpuHistory,
                           subtitle: store.cpu.map { "usr \(Fmt.pct($0.user))  sys \(Fmt.pct($0.system))" } ?? " ") {
                    CoreBars(cores: store.cpu?.cores ?? [])
                }
                .topConsumersOnHover(.cpu, title: "TOP CPU")
                MetricCard(title: "GPU", icon: "cube.transparent", tint: .gpu, value: store.gpu, history: store.gpuHistory,
                           subtitle: gpuSubtitle) {
                    if let r = store.gpuSample?.renderer, let t = store.gpuSample?.tiler {
                        GPUBars(renderer: r, tiler: t)
                    }
                }
                .topConsumersOnHover(.gpu, title: "TOP GPU")
            }
            GridRow {
                MetricCard(title: "Memory", icon: "memorychip", tint: memTint, value: store.memory?.percent,
                           history: store.memHistory,
                           subtitle: store.memory.map { "\(Fmt.gb($0.used)) of \(Fmt.gb($0.total))" } ?? " ") {
                    if let m = store.memory {
                        HStack(spacing: 4) {
                            Text("Pressure \(m.pressureName)")
                            Spacer()
                            if m.swapUsed > 0 { Text("swap \(Fmt.gb(m.swapUsed))") }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .topConsumersOnHover(.memory, title: "TOP MEMORY")
                BatteryCard(battery: store.battery)
                    .topConsumersOnHover(.battery, title: "ENERGY SHARE")
            }
        }
    }

    private var gpuSubtitle: String {
        let g = store.gpuSample
        let parts = [g?.cores.map { "\($0) cores" }, g?.memoryInUse.map(Fmt.gb)].compactMap { $0 }
        return parts.isEmpty ? "Device utilization" : parts.joined(separator: " · ")
    }

    private var memTint: Color {
        let p = store.memory?.pressure ?? 1
        return p >= 4 ? .red : p >= 2 ? .orange : .mem
    }
}

struct MetricCard<Extra: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let value: Double?
    let history: [Point]
    let subtitle: String
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                CardHeader(title: title, icon: icon, tint: tint)
                BigNumber(text: Fmt.pct(value))
            }
            LiveChart(points: history, tint: tint).frame(height: 42)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            extra
        }
        .padding(10)
        .frame(width: 160, height: 150, alignment: .topLeading)
        .background(CardBackground())
    }
}

struct CoreBars: View {
    let cores: [Double]
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, c in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 1).fill(Color.severity(c, base: .cpu))
                        .frame(height: max(1, 14 * c / 100))
                }
                .frame(height: 14)
            }
        }
    }
}

/// Renderer and tiler utilization, the only breakdown the GPU driver publishes (there is no per-core load).
struct GPUBars: View {
    let renderer: Double
    let tiler: Double
    var body: some View {
        HStack(spacing: 8) {
            bar("Render", renderer)
            bar("Tiler", tiler)
        }
        .frame(height: 14)
    }

    private func bar(_ label: String, _ v: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 1).fill(Color.severity(v, base: .gpu))
                        .frame(width: max(1, g.size.width * min(v, 100) / 100))
                }
            }
            .frame(height: 4)
        }
    }
}

struct BatteryCard: View {
    let battery: BatterySample?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                CardHeader(title: "Battery", icon: icon, tint: .battery)
                BigNumber(text: Fmt.pct(battery?.percent), color: low ? .red : .primary)
            }
            if let b = battery {
                UsageBar(percent: b.percent, tint: low ? .red : b.charging ? .mem : .battery).padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status(b)).font(.system(size: 11, weight: .medium))
                    Text(power(b)).foregroundStyle(.secondary)
                    Text(health(b)).foregroundStyle(.secondary)
                }
                .font(.system(size: 10)).lineLimit(1)
            } else {
                Spacer()
                Text("No battery").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 160, height: 150, alignment: .topLeading)
        .background(CardBackground())
    }

    private var low: Bool { (battery.map { !$0.pluggedIn && $0.percent <= 15 }) ?? false }
    private var icon: String {
        guard let b = battery else { return "battery.0" }
        if b.charging { return "battery.100.bolt" }
        return b.percent > 60 ? "battery.75" : b.percent > 30 ? "battery.50" : "battery.25"
    }

    private func status(_ b: BatterySample) -> String {
        if b.charging { return b.minutesToFull.map { "Charging, full in \(Fmt.duration(minutes: $0))" } ?? "Charging" }
        if b.pluggedIn { return b.charged ? "Charged" : "On power adapter" }
        return b.minutesToEmpty.map { "\(Fmt.duration(minutes: $0)) remaining" } ?? "On battery"
    }

    private func power(_ b: BatterySample) -> String {
        var parts: [String] = []
        if let w = b.watts, abs(w) >= 0.1 { parts.append(String(format: "%@%.1f W", w > 0 ? "+" : "", w)) }
        if let a = b.adapterWatts, b.pluggedIn { parts.append("\(a) W adapter") }
        if let t = b.temperature { parts.append(String(format: "%.0f\u{00B0}C", t)) }
        return parts.isEmpty ? " " : parts.joined(separator: "  ")
    }

    private func health(_ b: BatterySample) -> String {
        var parts: [String] = []
        if let h = b.health { parts.append("Health \(Fmt.pct(h))") }
        if let c = b.cycles { parts.append("\(c) cycles") }
        return parts.isEmpty ? " " : parts.joined(separator: "  ")
    }
}

// MARK: - Limits

struct LimitsCard: View {
    @ObservedObject var store: Store

    /// Extra Claude accounts cycle through colors that stay apart from the Claude orange.
    private static let accountTints: [Color] = [.cpu, .gpu, .mem]
    private func tint(_ account: Int) -> Color { account == 0 ? .claude : Self.accountTints[(account - 1) % Self.accountTints.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.claudeAvailable {
                CardHeader(title: "Claude Code", icon: "sparkle", tint: .claude, trailing: store.claudeLimits?.plan,
                           badges: store.claudeExtra.enumerated().map { i, l in
                               ([l.account, l.plan].compactMap { $0 }.joined(separator: " · "), tint(i + 1))
                           })
                if let l = store.claudeLimits {
                    let rows = limitRows([l] + store.claudeExtra)
                    ForEach(rows.indices, id: \.self) { r in
                        LimitRow(bars: rows[r].map { ($0.entry, tint($0.account)) })
                    }
                } else {
                    Text(store.claudeError ?? "Loading limits...").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let err = store.claudeError, store.claudeLimits != nil {
                    Text("\(err), showing data from \(Fmt.ago(store.claudeLimits?.fetchedAt))").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            if store.claudeAvailable && store.grokAvailable {
                Divider().opacity(0.5)
            }
            if store.grokAvailable {
                CardHeader(title: "Grok", icon: "bolt.horizontal.circle", tint: .grok,
                           trailing: store.grokPlan.map { $0.periodName.capitalized + " credits" })
                if let p = store.grokPlan {
                    LimitRow(entry: LimitEntry(id: "grok", name: "Credits used", percent: p.percent, resetsAt: p.periodEnd,
                                               window: window(p),
                                               note: p.products.count > 1 ? p.products.map { "\($0.name) \(Fmt.pct($0.percent))" }.joined(separator: "  ") : nil),
                             tint: .grok)
                } else {
                    Text(store.grokError ?? "Loading plan...").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let err = store.grokError, store.grokPlan != nil {
                    Text("\(err), showing data from \(Fmt.ago(store.grokPlan?.fetchedAt))").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            if store.codexAvailable {
                if store.claudeAvailable || store.grokAvailable { Divider().opacity(0.5) }
                CardHeader(title: "Codex", icon: "chevron.left.forwardslash.chevron.right", tint: .codex, trailing: store.codexLimits?.plan)
                if let l = store.codexLimits {
                    ForEach(l.all) { LimitRow(entry: $0, tint: .codex) }
                } else {
                    Text(store.codexError ?? "Loading limits...").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let err = store.codexError, store.codexLimits != nil {
                    Text("\(err), showing data from \(Fmt.ago(store.codexLimits?.fetchedAt))").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            if store.bedrockAvailable {
                if store.claudeAvailable || store.grokAvailable || store.codexAvailable { Divider().opacity(0.5) }
                BedrockSection(store: store)
            }
            if !store.claudeAvailable && !store.grokAvailable && !store.codexAvailable && !store.bedrockAvailable {
                Text("No Claude Code, Grok, Codex or AWS Bedrock account found").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(CardBackground())
    }

    private func window(_ p: GrokPlan) -> TimeInterval? {
        guard let s = p.periodStart, let e = p.periodEnd else { return nil }
        return e.timeIntervalSince(s)
    }
}

/// Bedrock has no plan limits, so this shows where its numbers come from and the 30-day spend.
struct BedrockSection: View {
    @ObservedObject var store: Store

    var body: some View {
        let cloud = store.bedrockFromCloudWatch
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "AWS Bedrock", icon: "cloud", tint: .bedrock,
                       trailing: cloud ? store.bedrockCloud?.config.regions.joined(separator: ", ") : "Claude Code")
            if let u = store.bedrockUsage {
                HStack(alignment: .firstTextBaseline) {
                    Text("Claude, last 30 days").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Fmt.tokens(u.month.tokens))  \(Fmt.usd(u.month.cost))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            Group {
                if cloud, let c = store.bedrockCloud {
                    Text("Account-wide from CloudWatch (\(c.config.profile ?? "default profile")), updated \(Fmt.ago(c.fetchedAt))")
                } else if store.bedrockUsage != nil {
                    Text("Claude Code sessions only. Set an AWS profile and region under Settings to include every Bedrock caller.")
                } else {
                    Text("No Claude usage found in \(store.bedrockConfig?.label ?? "CloudWatch")")
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let err = store.bedrockError {
                Text(err).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Combined token usage

struct UsageCard: View {
    @ObservedObject var store: Store
    @AppStorage("usage.metric") private var metric: DailyMetric = .cost

    var body: some View {
        let grok = store.grokAvailable ? store.grokUsage : nil
        let bedrock = store.bedrockUsage
        // Setups without a Claude subscription (Bedrock, Codex or Grok only) would show an empty Claude row.
        let claude = (store.claudeUsage?.month.tokens ?? 0) > 0 || store.claudeAvailable ? store.claudeUsage : nil
        let opencode = (store.opencodeUsage?.month.tokens ?? 0) > 0 ? store.opencodeUsage : nil
        let codex = (store.codexUsage?.month.tokens ?? 0) > 0 ? store.codexUsage : nil
        let combined = [grok, bedrock, opencode, codex].reduce(claude, UsageSummary.combine)
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Token usage", icon: "chart.bar.xaxis", tint: .claude)
            HStack(spacing: 6) {
                StatTile(title: "Today", totals: combined?.today)
                StatTile(title: "7 days", totals: combined?.week)
                StatTile(title: "30 days", totals: combined?.month)
            }
            VStack(spacing: 4) {
                if claude != nil { ProviderRow(name: "Claude", color: .claude, summary: claude) }
                if grok != nil { ProviderRow(name: "Grok", color: .grok, summary: grok) }
                if bedrock != nil { ProviderRow(name: "Bedrock", color: .bedrock, summary: bedrock) }
                if opencode != nil { ProviderRow(name: "OpenCode", color: .opencode, summary: opencode) }
                if codex != nil { ProviderRow(name: "Codex", color: .codex, summary: codex) }
            }
            if let w = store.claudeUsage?.window {
                HStack {
                    Text("Claude 5h window").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Fmt.tokens(w.tokens)) tokens  \(Fmt.usd(w.cost))").monospacedDigit()
                }
                .font(.system(size: 11))
            }

            if let u = combined {
                HStack {
                    Text("LAST 30 DAYS").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $metric) {
                        ForEach(DailyMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 110)
                }
                DailyChart(summary: u, metric: metric, height: 190)
                ModelList(models: Array(u.models.prefix(8)), families: Array(Set(u.bars.map(\.family))).sorted())
            } else {
                Text(store.indexing ?? "Reading usage...").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CardBackground())
    }
}

/// One provider's cost across the three windows, aligned under the tiles.
struct ProviderRow: View {
    let name: String
    let color: Color
    let summary: UsageSummary?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).lineLimit(1).minimumScaleFactor(0.8).frame(width: 46, alignment: .leading)
            ForEach([summary?.today, summary?.week, summary?.month].indices, id: \.self) { i in
                let t = [summary?.today, summary?.week, summary?.month][i]
                Text(t.map { "\(Fmt.tokens($0.tokens)) \(Fmt.usd($0.cost))" } ?? "--")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.system(size: 10))
    }
}

struct ModelList: View {
    let models: [ModelRow]
    let families: [String]
    var body: some View {
        VStack(spacing: 3) {
            ForEach(models) { m in
                HStack(spacing: 6) {
                    Circle().fill(Palette.familyColor(modelFamily(m.model), index: families.firstIndex(of: modelFamily(m.model)) ?? 0))
                        .frame(width: 6, height: 6)
                    Text(m.model).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.tokens(m.tokens)).monospacedDigit().foregroundStyle(.secondary)
                    Text(Fmt.usd(m.cost)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: 10))
            }
        }
    }
}

// MARK: - Footer

struct Footer: View {
    @ObservedObject var store: Store
    let actions: PopoverActions
    @AppStorage(Prefs.showCPU) private var showCPU = true
    @AppStorage(Prefs.showGPU) private var showGPU = false
    @AppStorage(Prefs.showMem) private var showMem = true
    @AppStorage(Prefs.showBattery) private var showBattery = false
    @AppStorage(Prefs.showClaude) private var showClaude = true
    @AppStorage(Prefs.showGrok) private var showGrok = true
    @AppStorage(Prefs.showCodex) private var showCodex = true
    @AppStorage(Prefs.colorMenuBar) private var colorMenuBar = false
    @AppStorage(Prefs.interval) private var interval = 1.0
    @AppStorage(Prefs.awakeForAgents) private var awakeForAgents = false
    @AppStorage(Prefs.awakeDisplay) private var awakeDisplay = false
    @State private var launchAtLogin = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Show in menu bar") {
                    Toggle("CPU", isOn: $showCPU)
                    Toggle("GPU", isOn: $showGPU)
                    Toggle("Memory", isOn: $showMem)
                    Toggle("Battery", isOn: $showBattery)
                    if store.claudeAvailable { Toggle("Claude limits", isOn: $showClaude) }
                    if store.grokAvailable { Toggle("Grok credits", isOn: $showGrok) }
                    if store.codexAvailable { Toggle("Codex limits", isOn: $showCodex) }
                    Toggle("Colors", isOn: $colorMenuBar)
                }
                Picker("Update every", selection: $interval) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                }
                Button("AWS Bedrock...", action: actions.configureBedrock)
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Section(appVersion.map { "Headroom \($0)" } ?? "Headroom (development build)") {
                    Button("Check for Updates...", action: actions.checkForUpdates)
                    Link("Release notes", destination: URL(string: "https://github.com/sandrich/headroom/releases"
                                                           + (appVersion.map { "/tag/v\($0)" } ?? ""))!)
                }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .menuStyle(.borderlessButton).fixedSize()

            Menu {
                Section(awakeStatus(store)) {
                    Button("Off") { actions.keepAwake(.off) }.disabled(store.awakeUntil == nil)
                    Button("For 1 hour") { actions.keepAwake(.hours(1)) }
                    Button("For 2 hours") { actions.keepAwake(.hours(2)) }
                    Button("For 4 hours") { actions.keepAwake(.hours(4)) }
                    Button("For 8 hours") { actions.keepAwake(.hours(8)) }
                    Button("Indefinitely") { actions.keepAwake(.indefinitely) }
                }
                Toggle("While Claude Code, Grok or Codex works", isOn: $awakeForAgents)
                Toggle("Keep display on", isOn: $awakeDisplay)
            } label: {
                Label(awakeLabel, systemImage: store.awake ? "cup.and.saucer.fill" : "cup.and.saucer")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Keep awake (Option-click the menu bar item to toggle)")

            Spacer()
            if let v = store.update {
                Button("Update to \(v)", action: actions.checkForUpdates).buttonStyle(.link)
            }
            Text(store.indexing ?? "Usage updated \(Fmt.ago(store.usageUpdated))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Button(action: actions.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh limits and usage")
            Button("Quit", action: actions.quit).buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private var awakeLabel: String {
        if let until = store.awakeUntil { return until == .distantFuture ? "Awake" : "Awake \(Fmt.until(until))" }
        return store.awakeForAgents ? "Awake (agents)" : "Keep awake"
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Headroom: login item change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
