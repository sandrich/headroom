import AppKit
import SwiftUI

final class HoverModel: ObservableObject {
    @Published var kind: SegmentKind = .cpu
    @Published var consumers: [Consumer] = []
}

/// Small floating panel under the menu bar showing top consumers (or plan limits) for the hovered item.
final class HoverController: NSResponder {
    private let store: Store
    private let sampler = ConsumerSampler()
    private let model = HoverModel()
    private weak var button: NSStatusBarButton?
    private var panel: NSPanel?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var current: SegmentKind?
    private var monitors: [Any] = []

    init(store: Store, button: NSStatusBarButton) {
        self.store = store
        self.button = button
        super.init()
        // Status items can be hosted outside the app on recent macOS, where tracking areas inside the
        // button never fire. Mouse-move monitors (no permission needed) plus a frame hit test work everywhere.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in self?.update() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in self?.update(); return e }) {
            monitors.append(m)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private static let debug = UserDefaults.standard.bool(forKey: "debugHover")
    private var lastLog = Date.distantPast

    private func log(_ msg: @autoclosure () -> String) {
        guard Self.debug else { return }
        lastLog = Date()
        let line = "\(Date()) \(msg())\n"
        let url = homeDir.appendingPathComponent("Library/Logs/Headroom-hover.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    private func update() {
        guard let button, let window = button.window, let image = button.image else { log("no button/window/image"); return }
        let mouse = NSEvent.mouseLocation
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        log("mouse \(mouse) in \(frame.contains(mouse)) current \(String(describing: current))")
        guard frame.contains(mouse) else {
            if current != nil { hide() }
            return
        }
        let x = mouse.x - frame.minX - (frame.width - image.size.width) / 2
        let kind = StatusRenderer.lastSegments.first { $0.range.contains(x) }?.kind
        guard kind != current else { return }
        current = kind
        pending?.cancel()
        guard let kind else { hidePanel(); return }
        let work = DispatchWorkItem { [weak self] in self?.show(kind) }
        pending = work
        // Short dwell so sweeping across the bar does not flash panels.
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel?.isVisible == true ? 0.05 : 0.35), execute: work)
    }

    func hide() {
        pending?.cancel()
        current = nil
        hidePanel()
    }

    private func hidePanel() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        // Drop the SwiftUI tree so a hidden panel does not keep re-rendering on every Store update.
        panel?.contentViewController = nil
    }

    private func show(_ kind: SegmentKind) {
        log("show \(kind)")
        model.kind = kind
        sampler.reset()
        model.consumers = sampler.top(kind)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.contentViewController == nil {
            panel.contentViewController = NSHostingController(rootView: HoverView(model: model, store: store))
        }
        position(panel, for: kind)
        timer?.invalidate()
        if [.cpu, .gpu, .battery, .memory, .network].contains(kind) {
            // First rate sample after 0.5s, then refresh while visible; the panel resizes as rows change.
            let refresh = { [weak self] in
                guard let self, self.current == kind, let panel = self.panel else { return }
                self.model.consumers = self.sampler.top(kind)
                self.position(panel, for: kind)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: refresh)
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in refresh() }
        }
        panel.orderFrontRegardless()
        log("panel frame \(panel.frame) visible \(panel.isVisible)")
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        return p
    }

    private func position(_ panel: NSPanel, for kind: SegmentKind) {
        guard let button, let window = button.window, let image = button.image,
              let range = StatusRenderer.lastSegments.first(where: { $0.kind == kind })?.range else { return }
        // Measure the SwiftUI content directly; a hosting view reports no fitting size before its first layout.
        guard let host = panel.contentViewController as? NSHostingController<HoverView> else { return }
        let size = host.sizeThatFits(in: NSSize(width: 240, height: 1000))
        let originX = (button.bounds.width - image.size.width) / 2 + range.lowerBound
        let inWindow = button.convert(NSPoint(x: originX, y: 0), to: nil)
        let screenPoint = window.convertPoint(toScreen: inWindow)
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x = min(max(screenPoint.x - 8, screen.minX + 6), screen.maxX - size.width - 6)
        panel.setFrame(NSRect(x: x, y: window.frame.minY - size.height - 6, width: size.width, height: size.height), display: true)
    }
}

struct HoverView: View {
    @ObservedObject var model: HoverModel
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
            switch model.kind {
            case .claude: limits(store.claudeLimits?.all ?? [], error: store.claudeError)
            case .grok:
                if let g = store.grokPlan {
                    limits([LimitEntry(id: "g", name: "Credits used", percent: g.percent, resetsAt: g.periodEnd)], error: nil)
                } else {
                    Text(store.grokError ?? "Loading").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .codex: limits(store.codexLimits?.all ?? [], error: store.codexError)
            case .awake:
                VStack(alignment: .leading, spacing: 3) {
                    Text(awakeStatus(store))
                    Text(Prefs.bool(Prefs.awakeDisplay) ? "Display stays on" : "Display can sleep")
                        .foregroundStyle(.secondary)
                    Text("Option-click to turn on or off").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            default: consumers
            }
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private var title: String {
        switch model.kind {
        case .cpu: return "TOP CPU"
        case .gpu: return "TOP GPU"
        case .memory: return "TOP MEMORY"
        case .battery: return "ENERGY SHARE"
        case .network: return "TOP NETWORK"
        case .claude: return "CLAUDE LIMITS"
        case .grok: return "GROK CREDITS"
        case .codex: return "CODEX LIMITS"
        case .awake: return "KEEP AWAKE"
        }
    }

    private var consumers: some View { ConsumerRows(consumers: model.consumers) }

    private func limits(_ entries: [LimitEntry], error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entries) { e in
                HStack {
                    Text(e.name)
                    Spacer()
                    Text(Fmt.pct(e.percent)).monospacedDigit().fontWeight(.semibold)
                    Text(Fmt.until(e.resetsAt)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: 11))
            }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }
}

/// Top-consumer rows with a relative bar under each, shared by the menu bar and dashboard hovers.
struct ConsumerRows: View {
    let consumers: [Consumer]

    var body: some View {
        if consumers.isEmpty {
            Text("Sampling...").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            let maxValue = consumers.map(\.value).max() ?? 1
            ForEach(consumers) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(c.label).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    GeometryReader { g in
                        Capsule().fill(Color.primary.opacity(0.35))
                            .frame(width: max(2, g.size.width * c.value / max(maxValue, 0.0001)))
                    }
                    .frame(height: 2)
                }
            }
        }
    }
}

/// Live top-consumer sampling for one metric while a dashboard card is hovered.
final class LiveConsumers: ObservableObject {
    @Published var consumers: [Consumer] = []
    private let sampler = ConsumerSampler()
    private var timer: Timer?

    func start(_ kind: SegmentKind) {
        stop()
        sampler.reset()
        consumers = sampler.top(kind)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.consumers = self.sampler.top(kind)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.consumers = self.sampler.top(kind)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

private struct TopConsumersOnHover: ViewModifier {
    let kind: SegmentKind
    let title: String
    @State private var hovering = false
    @State private var shown = false
    @StateObject private var live = LiveConsumers()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if hovering { shown = true } }
                } else {
                    shown = false
                }
            }
            .popover(isPresented: $shown, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                    ConsumerRows(consumers: live.consumers)
                }
                .padding(10)
                .frame(width: 240, alignment: .leading)
                .onAppear { live.start(kind) }
                .onDisappear { live.stop() }
            }
    }
}

extension View {
    /// Shows the top apps for `kind` in a small popover while the pointer rests on this view.
    func topConsumersOnHover(_ kind: SegmentKind, title: String) -> some View {
        modifier(TopConsumersOnHover(kind: kind, title: title))
    }
}
