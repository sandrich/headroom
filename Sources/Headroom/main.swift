import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = Store()
    private let sampler = SystemSampler()
    private let claudeClient = ClaudeLimitsClient()
    private let grokClient = GrokClient()
    private let bedrockClient = BedrockClient()
    private let ledger = Ledger()
    private let keepAwake = KeepAwake()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var sampleTimer: Timer?
    private var timers: [Timer] = []
    private var tick = 0
    private var ledgerBusy = false
    private var claudeBackoffUntil = Date.distantPast
    private var bedrockBusy = false
    private var currentInterval = 0.0
    private var snapshotDir: URL?
    private var hover: HoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        Pricing.shared.load()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            hover = HoverController(store: store, button: button)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if !UserDefaults.standard.bool(forKey: "didRegisterLoginItem") {
            UserDefaults.standard.set(true, forKey: "didRegisterLoginItem")
            try? SMAppService.mainApp.register()
        }

        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshotDir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }

        startSampling()
        sample()
        refreshLimits()
        refreshUsage()
        refreshBedrock()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshLimits() },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshUsage() },
            // CloudWatch bills per metric requested, so poll gently (about $0.30 a month per region).
            Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.refreshBedrock() },
        ]
        timers.forEach { $0.tolerance = 2 }
        if snapshotDir != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.writeSnapshots() }
        }

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if Prefs.sampleInterval != currentInterval { startSampling() }
            syncAwake()
            redraw()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLimits()
            self?.refreshUsage()
            self?.refreshBedrock()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ledger.flush()
        keepAwake.release()
    }

    // MARK: Sampling

    private func startSampling() {
        sampleTimer?.invalidate()
        currentInterval = Prefs.sampleInterval
        let t = Timer(timeInterval: currentInterval, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = currentInterval * 0.1
        RunLoop.main.add(t, forMode: .common)
        sampleTimer = t
    }

    private func sample() {
        store.record(cpu: sampler.cpu(), gpu: sampler.gpu(), memory: sampler.memory())
        // Battery changes slowly and reading the smart battery registry is the costliest probe.
        if tick % max(1, Int(5 / currentInterval)) == 0 { store.battery = sampler.battery() }
        tick += 1
        syncAwake()
        redraw()
    }

    private func redraw() {
        statusItem.button?.image = StatusRenderer.render(store)

    }

    // MARK: Limits and usage

    private func refreshLimits(force: Bool = false) {
        if force || Date() >= claudeBackoffUntil {
            Task { @MainActor in
                do {
                    store.claudeLimits = try await claudeClient.fetch()
                    store.claudeError = nil
                    store.claudeAvailable = true
                } catch ClientError.notConfigured {
                    store.claudeAvailable = false
                    store.claudeLimits = nil
                } catch {
                    store.claudeAvailable = true
                    store.claudeError = error.localizedDescription
                    if case ClientError.http(429) = error { claudeBackoffUntil = Date().addingTimeInterval(300) }
                }
                redraw()
            }
        }
        Task { @MainActor in
            do {
                store.grokPlan = try await grokClient.fetch()
                store.grokError = nil
                store.grokAvailable = true
            } catch ClientError.notConfigured {
                store.grokAvailable = false
                store.grokPlan = nil
            } catch {
                store.grokError = error.localizedDescription
            }
            redraw()
        }
    }

    private func refreshUsage() {
        guard !ledgerBusy else { return }
        ledgerBusy = true
        let windowStart = store.claudeLimits?.session?.resetsAt.map { $0.addingTimeInterval(-5 * 3600) }
        ledger.refresh(windowStart: windowStart, progress: { [weak self] msg in
            DispatchQueue.main.async { self?.store.indexing = msg }
        }, completion: { [weak self] claude, grok, bedrock, lastActivity in
            DispatchQueue.main.async {
                guard let self else { return }
                self.store.claudeUsage = claude
                self.store.grokUsage = grok
                self.store.bedrockLocalUsage = bedrock
                self.store.usageUpdated = Date()
                self.ledgerBusy = false
                self.keepAwake.agentActivity = lastActivity
                self.syncAwake()
            }
        })
    }

    private func refreshBedrock() {
        guard !bedrockBusy else { return }
        bedrockBusy = true
        store.bedrockConfig = BedrockClient.config()
        Task { @MainActor in
            defer { bedrockBusy = false }
            do {
                let u = try await bedrockClient.fetch()
                store.bedrockCloud = u
                store.bedrockCloudUsage = Ledger.summarize(u.hours, windowStart: nil)
                store.bedrockError = nil
            } catch ClientError.notConfigured {
                store.bedrockCloud = nil
                store.bedrockCloudUsage = nil
                store.bedrockError = nil
            } catch {
                store.bedrockError = error.localizedDescription
            }
        }
    }

    /// Asks for the AWS profile and regions to read Bedrock metrics from.
    private func configureBedrock() {
        popover.performClose(nil)
        let current = BedrockClient.config()
        let alert = NSAlert()
        alert.messageText = "AWS Bedrock"
        alert.informativeText = "Headroom reads Claude token counts from CloudWatch in these regions with the AWS CLI. "
            + "The profile needs cloudwatch:GetMetricData. Leave a field empty to use the AWS defaults."
        let profile = NSTextField(string: UserDefaults.standard.string(forKey: Prefs.bedrockProfile) ?? "")
        profile.placeholderString = current?.profile ?? "default"
        let regions = NSTextField(string: UserDefaults.standard.string(forKey: Prefs.bedrockRegions) ?? "")
        regions.placeholderString = current?.regions.joined(separator: ", ").nilIfEmpty ?? "us-east-1, us-west-2"
        let stack = NSStackView(views: [NSTextField(labelWithString: "Profile"), profile,
                                        NSTextField(labelWithString: "Regions (comma-separated)"), regions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 96)
        [profile, regions].forEach { $0.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(profile.stringValue.trimmingCharacters(in: .whitespaces), forKey: Prefs.bedrockProfile)
        UserDefaults.standard.set(regions.stringValue.trimmingCharacters(in: .whitespaces), forKey: Prefs.bedrockRegions)
        refreshBedrock()
    }

    // MARK: Keep awake

    private func setAwake(_ session: AwakeSession) {
        keepAwake.set(session)
        syncAwake()
        redraw()
    }

    /// Mirrors the assertion state into the store, publishing only on change so the popover is not re-rendered.
    private func syncAwake() {
        keepAwake.update()
        let until = keepAwake.manual ? keepAwake.until : nil
        if store.awakeUntil != until { store.awakeUntil = until }
        if store.awakeForAgents != keepAwake.agentsWorking { store.awakeForAgents = keepAwake.agentsWorking }
    }

    // MARK: Popover

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        // Option-click toggles keep awake without opening the dashboard.
        // Read the live key state: the status item may be hosted outside the app, so the current event can lack modifiers.
        if NSEvent.modifierFlags.contains(.option) {
            setAwake(keepAwake.manual ? .off : .indefinitely)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        hover?.hide()
        let view = PopoverView(store: store, actions: PopoverActions(
            refresh: { [weak self] in
                self?.refreshLimits(force: true)
                self?.refreshUsage()
                self?.refreshBedrock()
            },
            configureBedrock: { [weak self] in self?.configureBedrock() },
            quit: { NSApp.terminate(nil) },
            keepAwake: { [weak self] in self?.setAwake($0) }))
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the SwiftUI tree so nothing renders while the popover is hidden.
        popover.contentViewController = nil
    }
}

// MARK: - Snapshot mode (`Headroom --snapshot <dir>`): renders the strip and popover to PNGs, then exits.

extension AppDelegate {
    @MainActor fileprivate func writeSnapshots() {
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let strip = StatusRenderer.render(store)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let scale: CGFloat = 4
            let size = NSSize(width: strip.size.width * scale, height: strip.size.height * scale)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                (appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(origin: .zero, size: size).fill()
                strip.draw(in: NSRect(origin: .zero, size: size))
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("strip-\(name).png"))
        }
        print("strip width pt:", strip.size.width)

        let view = PopoverView(store: store, actions: PopoverActions(refresh: {}, configureBedrock: {}, quit: {}, keepAwake: { _ in }))
            .background(Color(nsColor: NSColor(white: 0.13, alpha: 1)))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let cg = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("popover.png"))
        }
        ledger.flush()
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
