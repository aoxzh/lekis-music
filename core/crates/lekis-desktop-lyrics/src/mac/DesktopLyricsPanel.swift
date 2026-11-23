import AppKit

private typealias LyricsCallback = @convention(c) (UnsafeRawPointer?, UnsafePointer<CChar>?) -> Void

private func lyricsLabel(_ chinese: String, _ english: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}

// Swift copies a frame before returning to Rust; only this immutable delivery crosses queues.
private final class FrameDelivery: @unchecked Sendable {
    let data: Data
    let context: UnsafeRawPointer?
    let callback: LyricsCallback?
    init(_ bytes: UnsafePointer<UInt8>, _ length: Int, _ context: UnsafeRawPointer?, _ callback: LyricsCallback?) {
        self.data = Data(bytes: bytes, count: length)
        self.context = context
        self.callback = callback
    }
}

// The Flutter main queue can be busy. Keep only the newest frame instead of replaying stale
// karaoke frames after it unblocks; AppKit still receives every final visibility/state change.
private final class FrameMailbox: @unchecked Sendable {
    static let shared = FrameMailbox()
    private let lock = NSLock()
    private var pending: FrameDelivery?
    private var scheduled = false

    func enqueue(_ delivery: FrameDelivery) {
        lock.lock()
        pending = delivery
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { DispatchQueue.main.async { self.deliver() } }
    }

    @MainActor private func deliver() {
        lock.lock()
        let delivery = pending
        pending = nil
        scheduled = false
        lock.unlock()
        if let delivery { LyricsPanelController.shared.apply(delivery) }
    }
}

@_cdecl("lekis_lyrics_macos_frame")
public func receiveLyricsFrame(_ bytes: UnsafePointer<UInt8>?, _ length: Int,
                               _ context: UnsafeRawPointer?, _ callback: (@convention(c) (UnsafeRawPointer?, UnsafePointer<CChar>?) -> Void)?) {
    guard let bytes, length >= 0 else { return }
    let delivery = FrameDelivery(bytes, length, context, callback)
    FrameMailbox.shared.enqueue(delivery)
}

private final class LyricsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class LyricsPanelController: NSObject, NSWindowDelegate {
    static let shared = LyricsPanelController()
    private(set) var panel: LyricsPanel?
    private var lyricView: LyricsView?
    private var callback: LyricsCallback?
    private var context: UnsafeRawPointer?
    private var frame: [String: Any] = [:]
    private var placements: [String: Any] = [:]
    private var restored = false
    private var hoverTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var statusText = ""
    private var statusMenu: NSMenu?
    private var statusPlayItem: NSMenuItem?
    private var statusDesktopItem: NSMenuItem?
    private var statusLockItem: NSMenuItem?
    private(set) var visible = false
    private(set) var locked = false
    private(set) var menuBarVisible = false

    func apply(_ delivery: FrameDelivery) {
        precondition(Thread.isMainThread)
        guard let next = try? JSONSerialization.jsonObject(with: delivery.data) as? [String: Any] else { return }
        callback = delivery.callback
        context = delivery.context
        frame = next
        visible = next["visible"] as? Bool ?? false
        menuBarVisible = next["menuBarVisible"] as? Bool ?? false
        locked = next["locked"] as? Bool ?? false
        // Keep the last placement locally as well: a drag callback precedes the next Rust frame.
        placements = next["placements"] as? [String: Any] ?? [:]
        updateMenuBar()
        guard visible || panel != nil else { return }
        if panel == nil { createPanel() }
        guard let panel, let lyricView else { return }
        let style = next["style"] as? [String: Any] ?? [:]
        panel.alphaValue = max(0.2, min(1, (style["opacity"] as? NSNumber)?.doubleValue ?? 1))
        lyricView.frameData = next
        let size = lyricView.desiredHeight
        if !restored {
            panel.setFrame(restoredFrame(height: size), display: false)
            restored = true
        } else if abs(panel.frame.height - size) > 0.5 {
            var rect = panel.frame
            rect.size.height = size
            panel.setFrame(clamped(rect, to: panel.screen ?? preferredScreen()), display: false)
        }
        lyricView.needsLayout = true
        lyricView.needsDisplay = true
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        configureHoverTimer()
        refreshInteraction()
    }

    private func createPanel() {
        let panel = LyricsPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 140),
                                styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.minSize = NSSize(width: 320, height: 70)
        panel.delegate = self
        panel.title = "Lekis Desktop Lyrics"
        let view = LyricsView(controller: self)
        panel.contentView = view
        self.panel = panel
        self.lyricView = view
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let panel = self.panel else { return }
                panel.setFrame(self.clamped(panel.frame, to: panel.screen ?? self.preferredScreen()), display: true)
                self.recordPlacement()
            }
        }
    }

    private func configureHoverTimer() {
        if visible && locked {
            guard hoverTimer == nil else { return }
            // A locked NSPanel receives no mouse events. Poll only its tiny unlock hotspot,
            // so the rest of the lyrics remain click-through and the lock is always recoverable.
            let timer = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshInteraction() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hoverTimer = timer
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    func refreshInteraction() {
        guard let panel, let lyricView else { return }
        let unlock = locked && visible && lyricView.unlockScreenRect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = locked && !unlock
        lyricView.showControls(all: visible && !locked && lyricView.hovering, lockOnly: unlock)
        let height = lyricView.desiredHeight
        if abs(panel.frame.height - height) > 0.5 {
            var rect = panel.frame
            rect.size.height = height
            panel.setFrame(clamped(rect, to: panel.screen ?? preferredScreen()), display: true)
        }
    }

    private func updateMenuBar() {
        guard menuBarVisible else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            statusMenu = nil
            statusText = ""
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: 220)
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, _ action: Selector) -> NSMenuItem {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
                return entry
            }
            statusPlayItem = add(lyricsLabel("播放 / 暂停", "Play / Pause"), #selector(menuPlayPause))
            _ = add(lyricsLabel("上一首", "Previous"), #selector(menuPrevious))
            _ = add(lyricsLabel("下一首", "Next"), #selector(menuNext))
            menu.addItem(.separator())
            statusDesktopItem = add(lyricsLabel("桌面歌词", "Desktop Lyrics"), #selector(menuToggleDesktop))
            statusLockItem = add(lyricsLabel("锁定桌面歌词", "Lock Desktop Lyrics"), #selector(menuToggleLock))
            menu.addItem(.separator())
            _ = add(lyricsLabel("关闭菜单栏歌词", "Hide Menu Bar Lyrics"), #selector(menuCloseMenuBar))
            _ = add(lyricsLabel("关闭全部歌词显示", "Hide All Lyrics"), #selector(menuCloseAll))
            item.menu = menu
            item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Lekis 歌词")
            item.button?.image?.isTemplate = true
            item.button?.imagePosition = .imageLeading
            item.button?.font = .systemFont(ofSize: 13, weight: .medium)
            item.button?.cell?.lineBreakMode = .byTruncatingTail
            statusItem = item
            statusMenu = menu
        }
        let text = frame["menuBarText"] as? String ?? frame["primary"] as? String ?? "Lekis"
        if text != statusText, let item = statusItem, let button = item.button {
            statusText = text
            let font = NSFont.systemFont(ofSize: 13, weight: .medium)
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            button.toolTip = text
        }
        statusPlayItem?.title = (frame["playing"] as? Bool ?? false) ? lyricsLabel("暂停", "Pause") : lyricsLabel("播放", "Play")
        statusDesktopItem?.state = visible ? .on : .off
        statusLockItem?.state = locked ? .on : .off
        statusLockItem?.isEnabled = visible
    }

    @objc private func menuPlayPause() { control("playPause") }
    @objc private func menuPrevious() { control("previous") }
    @objc private func menuNext() { control("next") }
    @objc private func menuToggleDesktop() {
        visible.toggle()
        emit(["event": "visibility", "visible": visible])
    }
    @objc private func menuToggleLock() { toggleLock() }
    @objc private func menuCloseMenuBar() {
        menuBarVisible = false
        updateMenuBar()
        emit(["event": "menuBarClosed"])
    }
    @objc private func menuCloseAll() {
        closeOverlay()
        menuCloseMenuBar()
    }

    @objc func smokeShowMenu() {
        // This demo-only main-menu shortcut must wait until its parent menu stops tracking.
        DispatchQueue.main.async {
            guard let button = self.statusItem?.button, let menu = self.statusMenu,
                  let screen = button.window?.screen ?? NSScreen.main else { return }
            let anchor = button.window?.convertToScreen(button.frame).minX ?? screen.frame.maxX - 260
            let x = min(max(screen.frame.minX, anchor), screen.frame.maxX - 260)
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: screen.frame.maxY - NSStatusBar.system.thickness), in: nil)
        }
    }

    func closeOverlay() {
        visible = false
        panel?.orderOut(nil)
        configureHoverTimer()
        emit(["event": "closed"])
    }

    func toggleLock() {
        locked.toggle()
        configureHoverTimer()
        refreshInteraction()
        emit(["event": "lock", "locked": locked])
    }

    func control(_ action: String) { emit(["event": "control", "action": action]) }

    // The standalone smoke verifier can change its own view state without moving the user's mouse.
    func smokeHover(_ hovering: Bool) {
        lyricView?.hovering = hovering
        refreshInteraction()
    }

    func smokeMenuAction(_ index: Int) {
        guard let statusMenu, statusMenu.items.indices.contains(index) else { return }
        statusMenu.performActionForItem(at: index)
    }

    private func emit(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8), let callback else { return }
        text.withCString { callback(context, $0) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { closeOverlay(); return false }
    func windowDidEndLiveResize(_ notification: Notification) { recordPlacement() }

    private func screenKey(_ screen: NSScreen) -> String {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "macos:\(id?.stringValue ?? screen.localizedName):\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    private func preferredScreen() -> NSScreen? {
        let last = placements["last"] as? String
        return NSScreen.screens.first(where: { screenKey($0) == last }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func clamped(_ rect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let work = screen?.visibleFrame else { return rect }
        let width = min(max(320, rect.width), work.width)
        let height = min(rect.height, work.height)
        return NSRect(x: min(max(rect.minX, work.minX), work.maxX - width),
                      y: min(max(rect.minY, work.minY), work.maxY - height), width: width, height: height)
    }

    private func restoredFrame(height: CGFloat) -> NSRect {
        guard let screen = preferredScreen() else { return NSRect(x: 80, y: 80, width: 880, height: height) }
        let work = screen.visibleFrame
        let saved = (placements["monitors"] as? [String: Any])?[screenKey(screen)] as? [String: Any]
        let width = (saved?["width"] as? NSNumber)?.doubleValue ?? min(560, work.width * 0.72)
        let x = work.minX + ((saved?["x"] as? NSNumber)?.doubleValue ?? (work.width - width) / 2)
        let y: CGFloat
        if let top = (saved?["y"] as? NSNumber)?.doubleValue { y = work.maxY - top - height }
        else { y = work.minY + 72 }
        return clamped(NSRect(x: x, y: y, width: width, height: height), to: screen)
    }

    func recordPlacement() {
        guard let panel, let screen = panel.screen ?? preferredScreen() else { return }
        let rect = clamped(panel.frame, to: screen)
        if rect != panel.frame { panel.setFrame(rect, display: true) }
        let work = screen.visibleFrame
        let key = screenKey(screen)
        var monitors = placements["monitors"] as? [String: Any] ?? [:]
        monitors[key] = ["x": rect.minX - work.minX, "y": work.maxY - rect.maxY, "width": rect.width]
        placements = ["last": key, "monitors": monitors]
        emit(["event": "placement", "placements": placements])
    }

    func resize(to width: CGFloat) {
        guard let panel else { return }
        var rect = panel.frame
        rect.size.width = max(320, width)
        panel.setFrame(clamped(rect, to: panel.screen ?? preferredScreen()), display: true)
    }

    // Read-only diagnostics used by the standalone smoke app; never touch AppKit off-main.
    func diagnostics() -> [String: Any] {
        let menu: [String: Any] = ["menuBarVisible": statusItem != nil, "menuBarText": statusText,
                                  "menuBarWidth": statusItem?.length ?? 0,
                                  "menuBarWindowVisible": statusItem?.button?.window?.isVisible ?? false,
                                  "menuItems": statusMenu?.items.filter { !$0.isSeparatorItem }.map { $0.title } ?? []]
        guard let panel else { return menu.merging(["created": false]) { _, new in new } }
        return ["created": true, "visible": panel.isVisible, "locked": locked,
                "ignoresMouseEvents": panel.ignoresMouseEvents, "opaque": panel.isOpaque,
                "unlockHovered": lyricView?.unlockScreenRect.contains(NSEvent.mouseLocation) ?? false,
                "backgroundAlpha": panel.backgroundColor.alphaComponent, "level": panel.level.rawValue,
                "floatingLevel": NSWindow.Level.floating.rawValue, "canBecomeKey": panel.canBecomeKey,
                "allSpaces": panel.collectionBehavior.contains(.canJoinAllSpaces),
                "fullScreenAuxiliary": panel.collectionBehavior.contains(.fullScreenAuxiliary),
                "primary": frame["primary"] ?? "", "secondary": frame["secondary"] ?? NSNull(),
                "windowNumber": panel.windowNumber,
                "toolbarVisible": lyricView?.controlsVisible ?? false,
                "lyricsTopScreenY": lyricView?.primaryTopInScreen ?? 0,
                "drawCount": lyricView?.drawCount ?? 0,
                "bodyBackgroundAlpha": lyricView?.bodyColor.alphaComponent ?? 0,
                "bodyBackgroundColor": "#202022",
                "windowAlpha": panel.alphaValue,
                "width": panel.frame.width, "height": panel.frame.height,
                "menuBarVisible": statusItem != nil, "menuBarText": statusText, "menuBarWidth": statusItem?.length ?? 0,
                "menuBarWindowVisible": statusItem?.button?.window?.isVisible ?? false,
                "menuItems": statusMenu?.items.filter { !$0.isSeparatorItem }.map { $0.title } ?? []]
    }
}

@MainActor
private final class LyricsView: NSView {
    unowned let controller: LyricsPanelController
    var frameData: [String: Any] = [:]
    var hovering = false
    private var controlsShown = false
    private var lockOnly = false
    private var tracking: NSTrackingArea?
    private var buttons: [NSButton] = []
    private var resizeStart: (point: NSPoint, width: CGFloat)?
    private var lastLocked: Bool?
    private var lastPlaying: Bool?
    private(set) var drawCount = 0
    let bodyColor = NSColor(srgbRed: 32 / 255, green: 32 / 255, blue: 34 / 255, alpha: 1)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(controller: LyricsPanelController) {
        self.controller = controller
        super.init(frame: .zero)
        let symbols = ["backward.end.fill", "pause.fill", "forward.end.fill", "lock", "xmark"]
        let actions = [#selector(previous), #selector(playPause), #selector(next), #selector(lock), #selector(close)]
        let descriptions = ["上一首 / Previous", "播放或暂停 / Play or pause", "下一首 / Next", "锁定或解锁 / Lock or unlock", "关闭桌面歌词 / Close lyrics"]
        for index in symbols.indices {
            let button = NSButton(title: "", target: self, action: actions[index])
            button.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: descriptions[index])
            button.imagePosition = .imageOnly
            button.contentTintColor = NSColor.white.withAlphaComponent(0.9)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            button.bezelStyle = .inline
            button.isBordered = false
            button.toolTip = descriptions[index]
            button.isHidden = true
            addSubview(button)
            buttons.append(button)
        }
    }
    required init?(coder: NSCoder) { nil }

    private var style: [String: Any] { frameData["style"] as? [String: Any] ?? [:] }
    private var fontSize: CGFloat { CGFloat((style["fontSize"] as? NSNumber)?.doubleValue ?? 26) }
    private var toolbarHeight: CGFloat { controlsShown ? 32 : 0 }
    var controlsVisible: Bool { controlsShown }
    var primaryTopInScreen: CGFloat {
        guard let window else { return 0 }
        return window.convertToScreen(convert(NSRect(x: 16, y: 16 + toolbarHeight, width: 1, height: 1), to: nil)).maxY
    }
    var desiredHeight: CGFloat {
        let two = style["twoLine"] as? Bool ?? true
        let secondary = frameData["secondary"] as? String ?? ""
        return toolbarHeight + 16 + fontSize * 1.35 + (two && !secondary.isEmpty ? min(18, fontSize * 0.69) * 1.4 + 4 : 0) + 16
    }

    override func layout() {
        super.layout()
        let start = (bounds.width - 5 * 32) / 2
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: start + CGFloat(index) * 32, y: 1, width: 30, height: 28)
        }
        if controller.locked { buttons[3].frame = NSRect(x: bounds.width - 34, y: 10, width: 26, height: 26) }
    }

    var unlockScreenRect: NSRect {
        guard buttons.count > 3, let window else { return .zero }
        return window.convertToScreen(buttons[3].convert(buttons[3].bounds, to: nil)).insetBy(dx: -4, dy: -3)
    }

    func showControls(all: Bool, lockOnly: Bool) {
        let changed = controlsShown != all || self.lockOnly != lockOnly
        controlsShown = all
        self.lockOnly = lockOnly
        if lastLocked != controller.locked {
            buttons[3].image = NSImage(systemSymbolName: controller.locked ? "lock.open" : "lock", accessibilityDescription: "锁定或解锁")
            lastLocked = controller.locked
        }
        let playing = frameData["playing"] as? Bool ?? false
        if lastPlaying != playing {
            buttons[1].image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: "播放或暂停")
            lastPlaying = playing
        }
        if changed {
            for (index, button) in buttons.enumerated() { button.isHidden = !all && !(lockOnly && index == 3) }
            needsDisplay = true; needsLayout = true; layoutSubtreeIfNeeded()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; controller.refreshInteraction() }
    override func mouseExited(with event: NSEvent) { hovering = false; controller.refreshInteraction() }

    override func mouseDown(with event: NSEvent) {
        guard !controller.locked, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= bounds.maxX - 12 { resizeStart = (NSEvent.mouseLocation, window.frame.width) }
        else { window.performDrag(with: event); controller.recordPlacement() }
    }
    override func mouseDragged(with event: NSEvent) {
        if let start = resizeStart { controller.resize(to: start.width + NSEvent.mouseLocation.x - start.point.x) }
    }
    override func mouseUp(with event: NSEvent) {
        if resizeStart != nil { resizeStart = nil; controller.recordPlacement() }
    }

    @objc private func previous() { controller.control("previous") }
    @objc private func playPause() { controller.control("playPause") }
    @objc private func next() { controller.control("next") }
    @objc private func lock() { controller.toggleLock() }
    @objc private func close() { controller.closeOverlay() }

    private func color(_ key: String, fallback: UInt32, opacity: CGFloat) -> NSColor {
        let value = (style[key] as? NSNumber)?.uint32Value ?? fallback
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255,
                       alpha: CGFloat((value >> 24) & 255) / 255 * opacity)
    }

    private func font(size: CGFloat) -> NSFont {
        let family = style["fontFamily"] as? String ?? ""
        let bold = style["bold"] as? Bool ?? false
        let base = family.isEmpty ? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium) : NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium)
        return !family.isEmpty && bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        // The default is a solid panel. Window alpha applies the user's opacity once to
        // the entire surface; menu-bar lyrics keep the system's native appearance.
        bodyColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let primary = frameData["primary"] as? String ?? "Lekis 桌面歌词"
        let width = max(1, bounds.width - 32)
        var mainFont = font(size: fontSize)
        let measured = (primary as NSString).size(withAttributes: [.font: mainFont]).width
        if measured > width { mainFont = font(size: max(14, fontSize * width / measured)) }
        let opacity: CGFloat = 1 // Global opacity is applied by NSPanel.alphaValue.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [.font: mainFont, .paragraphStyle: paragraph,
            .foregroundColor: color("unsungColor", fallback: 0xFFFFFFFF, opacity: opacity)]
        let rect = NSRect(x: 16, y: 16 + toolbarHeight, width: width, height: fontSize * 1.35)
        (primary as NSString).draw(in: rect, withAttributes: attributes)
        let fill = frameData["fill"] as? [String: Any] ?? [:]
        let kind = fill["kind"] as? String ?? "nothing"
        if kind != "nothing" {
            let textWidth = min(width, (primary as NSString).size(withAttributes: [.font: mainFont]).width)
            var sungWidth = textWidth
            if kind == "partial" {
                let words = frameData["words"] as? [String] ?? []
                let index = max(0, min(words.count, (fill["word"] as? NSNumber)?.intValue ?? 0))
                let prefix = words.prefix(index).joined()
                let partial = index < words.count ? (words[index] as NSString).size(withAttributes: [.font: mainFont]).width : 0
                let fraction = max(0, min(1, (fill["fraction"] as? NSNumber)?.doubleValue ?? 0))
                sungWidth = min(textWidth, (prefix as NSString).size(withAttributes: [.font: mainFont]).width + partial * fraction)
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: rect.midX - textWidth / 2, y: rect.minY, width: sungWidth, height: rect.height)).addClip()
            attributes[.foregroundColor] = color("sungColor", fallback: 0xFF8B7BFF, opacity: opacity)
            (primary as NSString).draw(in: rect, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        if style["twoLine"] as? Bool ?? true, let secondary = frameData["secondary"] as? String, !secondary.isEmpty {
            let secondarySize = min(18, fontSize * 0.69)
            attributes[.font] = NSFont.systemFont(ofSize: secondarySize, weight: .regular)
            attributes[.foregroundColor] = color("unsungColor", fallback: 0xFFFFFFFF, opacity: 1).withAlphaComponent(opacity * 0.78)
            (secondary as NSString).draw(in: NSRect(x: 16, y: rect.maxY + 4, width: width, height: secondarySize * 1.4), withAttributes: attributes)
        }
        if controlsShown {
            NSColor.secondaryLabelColor.setStroke()
            let grip = NSBezierPath()
            grip.move(to: NSPoint(x: bounds.maxX - 9, y: bounds.maxY - 15))
            grip.line(to: NSPoint(x: bounds.maxX - 9, y: bounds.maxY - 5))
            grip.stroke()
        }
    }
}

// Used by the standalone AppKit smoke executable, without a Flutter engine or Xcode project.
@_cdecl("lekis_lyrics_macos_run_application")
@MainActor public func runLyricsSmokeApplication() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    let application = NSMenuItem()
    let submenu = NSMenu()
    let lyricsMenu = submenu.addItem(withTitle: "Show Lyrics Menu", action: #selector(LyricsPanelController.smokeShowMenu), keyEquivalent: "l")
    lyricsMenu.target = LyricsPanelController.shared
    submenu.addItem(.separator())
    submenu.addItem(withTitle: "Quit Lekis Lyrics Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    application.submenu = submenu
    menu.addItem(application)
    app.mainMenu = menu
    app.run()
}

@_cdecl("lekis_lyrics_macos_diagnostics")
public func lyricsDiagnostics() -> UnsafeMutablePointer<CChar>? {
    let read: @MainActor () -> String = {
        let data = try? JSONSerialization.data(withJSONObject: LyricsPanelController.shared.diagnostics(), options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    let text: String
    if Thread.isMainThread { text = MainActor.assumeIsolated { read() } }
    else { text = DispatchQueue.main.sync { read() } }
    return strdup(text)
}

@_cdecl("lekis_lyrics_macos_free_diagnostics")
public func freeLyricsDiagnostics(_ text: UnsafeMutablePointer<CChar>?) { free(text) }

@_cdecl("lekis_lyrics_macos_smoke_hover")
public func smokeLyricsHover(_ hovering: Bool) {
    DispatchQueue.main.async { LyricsPanelController.shared.smokeHover(hovering) }
}

@_cdecl("lekis_lyrics_macos_smoke_menu_action")
public func smokeLyricsMenuAction(_ index: Int) {
    DispatchQueue.main.async { LyricsPanelController.shared.smokeMenuAction(index) }
}
