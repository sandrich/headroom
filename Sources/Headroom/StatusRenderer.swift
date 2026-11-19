import AppKit

/// Draws the menu bar strip as one template image: SF Symbol, value, and (for CPU/GPU) a tiny live graph,
/// all on a single line. Being a template, macOS tints it exactly like the other menu bar items.
/// With colors on, it is a plain image instead: icons and graphs take each item's dashboard color, values stay
/// black or white for the menu bar's appearance and turn orange or red as they near their limit.
enum StatusRenderer {
    static let height: CGFloat = 22
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    private static let gap: CGFloat = 8
    private static let graphSize = NSSize(width: 18, height: 13)
    /// Horizontal points per sample in the sparkline (0.5pt is one pixel on Retina).
    private static let step: CGFloat = 0.5

    private typealias Segment = (width: CGFloat, draw: (CGFloat) -> Void)

    static func render(_ store: Store, dark: Bool) -> NSImage {
        colored = Prefs.bool(Prefs.colorMenuBar)
        ink = colored && dark ? .white : .black
        var segments: [Segment] = []
        var kinds: [SegmentKind] = []
        func add(_ k: SegmentKind, _ seg: Segment) { kinds.append(k); segments.append(seg) }

        if Prefs.bool(Prefs.showCPU) {
            add(.cpu, metric(symbol: "cpu", fallback: "CPU", tint: Palette.cpu, value: store.cpu?.total,
                                   history: store.cpuHistory.map(\.v)))
        }
        if Prefs.bool(Prefs.showGPU) {
            add(.gpu, metric(symbol: "cube", fallback: "GPU", tint: Palette.gpu, value: store.gpu,
                                   history: store.gpuHistory.map(\.v)))
        }
        if Prefs.bool(Prefs.showMem) {
            add(.memory, metric(symbol: "memorychip", fallback: "MEM", tint: Palette.mem, value: store.memory?.percent, history: nil))
        }
        if Prefs.bool(Prefs.showNet) {
            add(.network, network(store.net))
        }
        if Prefs.bool(Prefs.showBattery), let b = store.battery {
            add(.battery, battery(b))
        }
        if Prefs.bool(Prefs.showClaude), store.claudeAvailable {
            let l = store.claudeLimits
            add(.claude, gauges(symbol: "sparkle", fallback: "CC", tint: Palette.claude,
                                   values: [l?.session?.percent, l?.weekly?.percent, l?.model?.percent]))
        }
        if Prefs.bool(Prefs.showGrok), store.grokAvailable {
            add(.grok, gauges(symbol: "bolt.horizontal.circle", fallback: "GK", tint: Palette.grok, values: [store.grokPlan?.percent]))
        }
        if Prefs.bool(Prefs.showCodex), store.codexAvailable {
            add(.codex, gauges(symbol: "chevron.left.forwardslash.chevron.right", fallback: "CX", tint: Palette.codex,
                               values: store.codexLimits?.all.map(\.percent) ?? [nil]))
        }
        if store.awake {
            add(.awake, icon("cup.and.saucer.fill", "AW"))
        }

        let width = max(segments.reduce(0) { $0 + $1.width } + gap * CGFloat(max(segments.count - 1, 0)), 14)
        // Rasterize once per tick; a drawing-handler image would be re-drawn on every display pass.
        let size = NSSize(width: ceil(width), height: height)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        var x: CGFloat = 0
        for s in segments {
            s.draw(x)
            x += s.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = !colored
        lastSegments = segmentRanges(segments, kinds: kinds)
        return image
    }

    /// Horizontal extent of each item in the last rendered strip, for hover hit testing.
    private(set) static var lastSegments: [(kind: SegmentKind, range: ClosedRange<CGFloat>)] = []

    private static func segmentRanges(_ segs: [Segment], kinds: [SegmentKind]) -> [(kind: SegmentKind, range: ClosedRange<CGFloat>)] {
        var x: CGFloat = 0
        return zip(segs, kinds).map { seg, kind in
            defer { x += seg.width + gap }
            return (kind, (x - gap / 2)...(x + seg.width + gap / 2))
        }
    }

    // MARK: Pieces

    private static var colored = false
    /// Black for template drawing; with colors on, whatever reads on the menu bar's appearance.
    private static var ink = NSColor.black

    /// An item's color when colors are on, otherwise the template ink.
    private static func tint(_ c: NSColor?) -> NSColor { colored ? c ?? ink : ink }

    private static var symbolCache: [String: NSImage] = [:]

    private static func symbol(_ name: String, color: NSColor? = nil) -> NSImage? {
        let key = color.map { "\(name)|\($0)" } ?? name
        if let img = symbolCache[key] { return img }
        let config = color.map { symbolConfig.applying(.init(paletteColors: [$0])) } ?? symbolConfig
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        symbolCache[key] = img
        return img
    }

    /// Symbol (or a short text fallback) vertically centered. Returns width and drawer.
    private static func icon(_ name: String, _ fallback: String, tint t: NSColor? = nil) -> Segment {
        if let img = symbol(name, color: colored ? tint(t) : nil) {
            let s = img.size
            return (s.width, { x in img.draw(in: NSRect(x: x, y: (height - s.height) / 2, width: s.width, height: s.height)) })
        }
        let t = text(fallback, NSFont.systemFont(ofSize: 9, weight: .bold))
        let w = ceil(t.size().width)
        return (w, { x in t.draw(at: NSPoint(x: x, y: (height - t.size().height) / 2)) })
    }

    private static func text(_ s: String, _ f: NSFont = font, color: NSColor? = nil) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color ?? ink])
    }

    /// Value sized for two digits so the strip only grows at 100%. `warn` colors it as it nears 100%.
    private static func value(_ v: Double?, warn: Bool = true) -> Segment {
        let t = text(v.map { "\(Int($0.rounded()))%" } ?? "--", color: warn ? tint(Palette.severity(v, base: ink)) : nil)
        let w = max(ceil(t.size().width), ceil(text("88%").size().width))
        return (w, { x in t.draw(at: NSPoint(x: x, y: (height - t.size().height) / 2)) })
    }

    private static func row(_ parts: [Segment], spacing: CGFloat = 2) -> Segment {
        let w = parts.reduce(0) { $0 + $1.width } + spacing * CGFloat(parts.count - 1)
        return (w, { x in
            var cx = x
            for p in parts { p.draw(cx); cx += p.width + spacing }
        })
    }

    private static func metric(symbol: String, fallback: String, tint t: NSColor, value v: Double?, history: [Double]?) -> Segment {
        var parts = [icon(symbol, fallback, tint: t), value(v)]
        if let history {
            parts.append((graphSize.width, { x in
                sparkline(NSRect(x: x, y: (height - graphSize.height) / 2, width: graphSize.width, height: graphSize.height),
                          history, color: tint(t))
            }))
        }
        return row(parts, spacing: 2)
    }

    private static func battery(_ b: BatterySample) -> Segment {
        let body = NSSize(width: 20, height: 10)
        let glyph: Segment = (body.width + 2, { x in
            let r = NSRect(x: x + 0.5, y: (height - body.height) / 2, width: body.width - 1, height: body.height)
            let outline = NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5)
            ink.withAlphaComponent(0.45).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            let nub = NSRect(x: r.maxX + 1, y: r.midY - 2, width: 1.5, height: 4)
            ink.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: nub, xRadius: 0.75, yRadius: 0.75).fill()
            let inner = r.insetBy(dx: 1.75, dy: 1.75)
            let fill = NSRect(x: inner.minX, y: inner.minY, width: max(1, inner.width * min(b.percent, 100) / 100), height: inner.height)
            // Like the system battery: neutral fill, green while charging, red when low.
            tint(b.percent <= 20 && !b.charging ? .systemRed : b.charging ? .systemGreen : nil).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
            if b.charging, let bolt = symbol("bolt.fill")?.withSymbolConfiguration(.init(pointSize: 8, weight: .black)) {
                // Knock the bolt out of the fill so it reads on any tint.
                let s = bolt.size
                bolt.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                          from: .zero, operation: .destinationOut, fraction: 1)
            }
        })
        return row([glyph, value(b.percent, warn: false)], spacing: 3)
    }

    private static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let netArrowWidth = ceil(["\u{2191}", "\u{2193}"].map { text($0, smallFont).size().width }.max() ?? 0) + 2
    private static let netValueWidth = ["888 KB/s", "888 MB/s", "888 GB/s"].map { ceil(text($0, smallFont).size().width) }.max() ?? 0

    /// Symbol plus upload over download in two small lines. Arrows stay at the left edge and values are right-aligned
    /// in a column sized for the widest value, so neither moves as the numbers change.
    private static func network(_ n: NetSample?) -> Segment {
        let arrows = [text("\u{2191}", smallFont, color: tint(Palette.netUp)), text("\u{2193}", smallFont, color: tint(Palette.netDown))]
        let values = [text(n.map { Fmt.rate($0.up) } ?? "--", smallFont), text(n.map { Fmt.rate($0.down) } ?? "--", smallFont)]
        let w = netArrowWidth + netValueWidth
        let lines: Segment = (w, { x in
            let h = values[0].size().height
            for (i, y) in [height / 2 - 1.5, height / 2 - h + 1.5].enumerated() {
                arrows[i].draw(at: NSPoint(x: x, y: y))
                values[i].draw(at: NSPoint(x: x + w - values[i].size().width, y: y))
            }
        })
        return row([icon("network", "NET", tint: Palette.netDown), lines], spacing: 3)
    }

    /// Symbol plus one slim vertical gauge per value (Claude: 5h, week, model; Grok: credits).
    private static func gauges(symbol name: String, fallback: String, tint t: NSColor, values: [Double?]) -> Segment {
        let barW: CGFloat = 3, barH: CGFloat = 14, spacing: CGFloat = 1.5
        let w = CGFloat(values.count) * barW + CGFloat(values.count - 1) * spacing
        let bars: Segment = (w, { x in
            for (i, v) in values.enumerated() {
                let r = NSRect(x: x + CGFloat(i) * (barW + spacing), y: (height - barH) / 2, width: barW, height: barH)
                ink.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
                guard let v else { continue }
                let f = NSRect(x: r.minX, y: r.minY, width: barW, height: max(1.5, barH * min(max(v, 0), 100) / 100))
                tint(Palette.severity(v, base: t)).setFill()
                NSBezierPath(roundedRect: f, xRadius: 1, yRadius: 1).fill()
            }
        })
        return row([icon(name, fallback, tint: t), bars], spacing: 3)
    }

    private static func sparkline(_ r: NSRect, _ values: [Double], color: NSColor) {
        let frame = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
        ink.withAlphaComponent(0.12).setFill()
        frame.fill()
        let n = Int(r.width / step) + 1
        let vals = Array(values.suffix(n))
        guard vals.count > 1 else { return }

        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        let x0 = r.maxX - CGFloat(vals.count - 1) * step
        let points = vals.enumerated().map { i, v in
            NSPoint(x: x0 + CGFloat(i) * step, y: r.minY + 0.5 + CGFloat(min(max(v, 0), 100)) / 100 * (r.height - 1))
        }
        let area = NSBezierPath()
        area.move(to: NSPoint(x: points[0].x, y: r.minY))
        points.forEach { area.line(to: $0) }
        area.line(to: NSPoint(x: points[points.count - 1].x, y: r.minY))
        area.close()
        color.withAlphaComponent(0.55).setFill()
        area.fill()

        let line = NSBezierPath()
        line.move(to: points[0])
        points.dropFirst().forEach { line.line(to: $0) }
        line.lineWidth = 1
        line.lineJoinStyle = .round
        color.setStroke()
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
