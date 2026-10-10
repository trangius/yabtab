// yabtab: window picker with thumbnails for every window on every space.
// Window list comes from yabai, thumbnails from ScreenCaptureKit.
import AppKit
import Carbon
import ScreenCaptureKit

let yabaiPath = "/opt/homebrew/bin/yabai"

// Private API (same as AltTab uses): turn off the system Cmd+Tab switcher so our hotkey gets it.
// Symbolic hotkey ids: 1 = Cmd+Tab, 2 = Cmd+Shift+Tab.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> CGError

func setSystemCmdTab(_ enabled: Bool) {
    _ = CGSSetSymbolicHotKeyEnabled(1, enabled)
    _ = CGSSetSymbolicHotKeyEnabled(2, enabled)
}

struct YabaiWindow: Decodable {
    let id: Int
    let pid: Int32
    let app: String
    let title: String
    let space: Int
    let role: String
    let isMinimized: Bool
    let hasFocus: Bool

    enum CodingKeys: String, CodingKey {
        case id, pid, app, title, space, role
        case isMinimized = "is-minimized"
        case hasFocus = "has-focus"
    }
}

// nil if yabai isn't installed, isn't running, or the command failed
func runYabai(_ args: [String]) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: yabaiPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

// yabai appends every focused window id here (signal added below and in yabairc)
let mruPath = "/tmp/yabtab-mru"
let mruSignal = ["-m", "signal", "--add", "label=yabtab_mru", "event=window_focused",
                 "action=echo $YABAI_WINDOW_ID >> \(mruPath)"]

// Window ids, most recently focused first; trims the log when it grows
func loadMRU() -> [Int] {
    let lines = ((try? String(contentsOfFile: mruPath, encoding: .utf8)) ?? "").split(separator: "\n")
    if lines.count > 500 { try? (lines.suffix(100).joined(separator: "\n") + "\n").write(toFile: mruPath, atomically: true, encoding: .utf8) }
    var seen = Set<Int>(), out: [Int] = []
    for l in lines.reversed() { if let id = Int(l), seen.insert(id).inserted { out.append(id) } }
    return out
}

// nil when yabai can't be reached
func loadWindows() -> [YabaiWindow]? {
    guard let data = runYabai(["-m", "query", "--windows"]) else { return nil }
    let all = (try? JSONDecoder().decode([YabaiWindow].self, from: data)) ?? []
    return all.filter { $0.role == "AXWindow" }
        .sorted { ($0.space, $0.app, $0.title) < ($1.space, $1.app, $1.title) }
}

// Colors: brown/amber accent, no cyan.
let accent = NSColor(srgbRed: 0.80, green: 0.55, blue: 0.30, alpha: 1)
let tileW: CGFloat = 260, tileH: CGFloat = 190, thumbH: CGFloat = 150, gap: CGFloat = 16

final class Tile: NSView {
    let win: YabaiWindow
    let imageView = NSImageView()
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    var selected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(_ w: YabaiWindow) {
        win = w
        super.init(frame: NSRect(x: 0, y: 0, width: tileW, height: tileH))
        wantsLayer = true

        imageView.frame = NSRect(x: 8, y: tileH - thumbH - 8, width: tileW - 16, height: thumbH - 8)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let appIcon = NSRunningApplication(processIdentifier: w.pid)?.icon
        imageView.image = appIcon
        addSubview(imageView)

        icon.frame = NSRect(x: 8, y: 8, width: 20, height: 20)
        icon.image = appIcon
        addSubview(icon)

        let title = w.title.isEmpty ? w.app : "\(w.app) — \(w.title)"
        // Space number in the accent color, then the title
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString(string: "\(w.space)  ", attributes: [.font: font, .foregroundColor: accent])
        text.append(NSAttributedString(string: title + (w.isMinimized ? "  (min)" : ""),
                                       attributes: [.font: font, .foregroundColor: NSColor.white]))
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 32, y: 8, width: tileW - 40, height: 18)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        (selected ? accent.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.06)).setFill()
        path.fill()
        if selected {
            accent.setStroke()
            path.lineWidth = 3
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Alt-tab style, resident: Cmd+Tab shows the picker (or cycles if shown), releasing Cmd focuses
// the selection. Thumbnails are cached so the picker appears instantly and refreshes in the background.
final class Picker: NSObject, NSApplicationDelegate {
    var panel: Panel!
    let bg = NSVisualEffectView()
    let scroll = NSScrollView()
    let grid = NSView()
    let message = NSTextField(labelWithString: "")
    var tiles: [Tile] = []
    var sel = 0
    var cols = 1
    var shown = false
    var releaseTimer: Timer?
    var thumbs: [Int: NSImage] = [:]
    var capturing = false

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = Panel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        bg.material = .hudWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        bg.addSubview(scroll)

        message.font = .systemFont(ofSize: 18, weight: .regular)
        message.textColor = accent
        message.alignment = .center
        message.isHidden = true
        bg.addSubview(message)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.keyDown(e) ?? e
        }
        setSystemCmdTab(false)
        registerHotKeys()
        _ = runYabai(mruSignal)
        refreshThumbnails(for: loadWindows() ?? [])
    }

    func hotKey(back: Bool) {
        if shown { move(back ? -1 : 1) } else { show(back: back) }
    }

    func show(back: Bool) {
        guard let all = loadWindows() else { showMessage("yabai isn't running"); return }
        guard let windows = prepare(back: back, all: all) else { return }
        message.isHidden = true
        scroll.isHidden = false
        shown = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        // Poll the hardware modifier state so release is caught even if we never became active
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            guard let self, !NSEvent.modifierFlags.contains(.command) else { return }
            self.pick(self.tiles[self.sel])
        }
        refreshThumbnails(for: windows)
    }

    // Build tiles and size/lay out the panel for the current windows.
    func prepare(back: Bool, all: [YabaiWindow]) -> [YabaiWindow]? {
        // Most-recently-used order (focused window first, never-seen ones last, in space order),
        // so a quick Cmd+Tab flips between the last two windows
        let rank = Dictionary(loadMRU().enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let windows = all.enumerated().sorted {
            if $0.element.hasFocus != $1.element.hasFocus { return $0.element.hasFocus }
            return (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
        guard !windows.isEmpty else { return nil }
        tiles = windows.map { w in
            let t = Tile(w)
            if let img = thumbs[w.id] { t.imageView.image = img }
            t.onClick = { [weak self] in self?.pick(t) }
            return t
        }
        sel = tiles.count > 1 ? (back ? tiles.count - 1 : 1) : 0
        tiles[0].alphaValue = 0.55   // the window you're in

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        cols = max(1, min(tiles.count, Int((screen.width * 0.9 + gap) / (tileW + gap))))
        let w = CGFloat(cols) * (tileW + gap) + gap
        computeSlots()
        let h = min(screen.height * 0.9, contentHeight())
        panel.setFrame(NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h), display: false)
        bg.frame = NSRect(x: 0, y: 0, width: w, height: h)
        scroll.frame = bg.bounds
        layoutTiles()
        return windows
    }

    // Shown instead of the grid while Cmd is held; disappears on release
    func showMessage(_ text: String) {
        tiles = []
        message.stringValue = text
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let w: CGFloat = 420, h: CGFloat = 80
        panel.setFrame(NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h), display: false)
        bg.frame = NSRect(x: 0, y: 0, width: w, height: h)
        message.frame = NSRect(x: 0, y: (h - 24) / 2, width: w, height: 24)
        message.isHidden = false
        scroll.isHidden = true
        shown = true
        panel.orderFrontRegardless()
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            guard let self, !NSEvent.modifierFlags.contains(.command) else { return }
            self.hide()
        }
    }

    func hide() {
        shown = false
        releaseTimer?.invalidate()
        releaseTimer = nil
        panel.orderOut(nil)
        grid.subviews.forEach { $0.removeFromSuperview() }
    }

    var rowH: CGFloat { tileH + gap }
    var slots: [(row: Int, col: Int)] = []

    func computeSlots() { slots = tiles.indices.map { ($0 / cols, $0 % cols) } }

    func contentHeight() -> CGFloat { CGFloat((slots.last?.row ?? 0) + 1) * rowH + gap }

    func layoutTiles() {
        grid.subviews.forEach { $0.removeFromSuperview() }
        let gw = CGFloat(cols) * (tileW + gap) + gap
        let gh = max(contentHeight(), scroll.frame.height)
        grid.frame = NSRect(x: 0, y: 0, width: gw, height: gh)
        for (i, t) in tiles.enumerated() {
            let (r, c) = slots[i]
            t.frame.origin = NSPoint(x: gap + CGFloat(c) * (tileW + gap), y: gh - CGFloat(r + 1) * rowH)
            grid.addSubview(t)
        }
        updateSelection()
    }

    // Up/down: nearest tile in the row above/below.
    func moveRow(_ d: Int) {
        let rows = (slots.last?.row ?? 0) + 1
        let target = (slots[sel].row + d + rows) % rows
        let col = slots[sel].col
        sel = tiles.indices.filter { slots[$0].row == target }.min { abs(slots[$0].col - col) < abs(slots[$1].col - col) } ?? sel
        updateSelection()
    }


    func updateSelection() {
        guard tiles.indices.contains(sel) else { return }
        for (i, t) in tiles.enumerated() { t.selected = (i == sel) }
        tiles[sel].scrollToVisible(tiles[sel].bounds)
    }

    func move(_ d: Int) {
        guard !tiles.isEmpty else { return }
        sel = (sel + d + tiles.count) % tiles.count
        updateSelection()
    }

    func pick(_ t: Tile) {
        guard shown else { return }
        hide()
        _ = runYabai(["-m", "window", "--focus", String(t.win.id)])
        // Re-snapshot shortly after, so the window we left is fresh next time
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshThumbnails(for: loadWindows() ?? [])
        }
    }

    // Tab / shift-tab and arrows move, enter picks, esc cancels. Cmd+Tab itself arrives as a hotkey.
    func keyDown(_ e: NSEvent) -> NSEvent? {
        guard shown, !tiles.isEmpty else { return e }
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 48, 13: move(shift ? -1 : 1)   // tab, w
        case 123: move(-1)                  // left
        case 124: move(1)                   // right
        case 126: moveRow(-1)               // up
        case 125: moveRow(1)                // down
        case 36: pick(tiles[sel])           // return
        case 53: hide()                     // esc
        default: return e
        }
        return nil
    }

    func refreshThumbnails(for windows: [YabaiWindow]) {
        guard !capturing else { return }
        // Without permission, ask once, then just show app icons (no prompt on every press)
        guard CGPreflightScreenCaptureAccess() else {
            if !UserDefaults.standard.bool(forKey: "askedCapture") {
                UserDefaults.standard.set(true, forKey: "askedCapture")
                CGRequestScreenCaptureAccess()
            }
            return
        }
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            let byID = Dictionary(content.windows.map { (Int($0.windowID), $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: (Int, CGImage?).self) { group in
                for w in windows where !w.isMinimized {
                    guard let scw = byID[w.id] else { continue }
                    group.addTask {
                        let cfg = SCStreamConfiguration()
                        let scale = min(1, 600 / max(scw.frame.width, 1))
                        cfg.width = Int(scw.frame.width * scale * 2)
                        cfg.height = Int(scw.frame.height * scale * 2)
                        cfg.showsCursor = false
                        let filter = SCContentFilter(desktopIndependentWindow: scw)
                        return (w.id, try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg))
                    }
                }
                for await (id, img) in group {
                    guard let img else { continue }
                    let image = NSImage(cgImage: img, size: .zero)
                    thumbs[id] = image
                    tiles.first { $0.win.id == id }?.imageView.image = image
                }
            }
            // Forget windows that are gone
            let alive = Set(windows.map(\.id))
            thumbs = thumbs.filter { alive.contains($0.key) }
        }
    }

    func applicationWillTerminate(_ n: Notification) { setSystemCmdTab(true) }

    func applicationDidResignActive(_ n: Notification) { if shown { hide() } }

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            picker.hotKey(back: id.id == 2)
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey), EventHotKeyID(signature: 0x57504b31, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x57504b31, id: 2),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

signal(SIGTERM) { _ in setSystemCmdTab(true); exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let picker = Picker()
app.delegate = picker
app.run()
