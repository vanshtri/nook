import AppKit
import SwiftUI

/// Borderless panel that can take keyboard input without activating the app (like Spotlight).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init(size: NSSize) {
        self.init(contentRect: NSRect(origin: .zero, size: size),
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}

// MARK: - Notch geometry

extension NSScreen {
    var hasNotch: Bool { safeAreaInsets.top > 0 }

    /// The notch in global screen coordinates (or a fake one at the top-centre on screens without one).
    var notchRect: NSRect {
        let f = frame
        if hasNotch, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea {
            let h = safeAreaInsets.top
            return NSRect(x: f.minX + l.width, y: f.maxY - h, width: f.width - l.width - r.width, height: h)
        }
        let h = max(f.maxY - visibleFrame.maxY, 24)
        return NSRect(x: f.midX - 110, y: f.maxY - h, width: 220, height: h)
    }
}

// MARK: - Shelf (hover the notch)

final class ShelfModel: ObservableObject {
    @Published var open = false
    @Published var query = ""
    var notchHeight: CGFloat = 32
    var notchWidth: CGFloat = 200
    var close: () -> Void = {}
}

final class ShelfController: NSObject, NSWindowDelegate {
    let model = ShelfModel()
    private var hoverZone: NSPanel!
    private var shelf: KeyPanel!
    private var watchTimer: Timer?
    private var outsideSince: Date?
    private let size = NSSize(width: 700, height: 270)

    private var screen: NSScreen {
        NSScreen.screens.first(where: \.hasNotch) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func setup() {
        model.close = { [weak self] in self?.close() }

        hoverZone = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hoverZone.isOpaque = false
        hoverZone.backgroundColor = .clear
        hoverZone.level = .statusBar
        hoverZone.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hv = HoverView()
        hv.onEnter = { [weak self] in self?.open() }
        hoverZone.contentView = hv

        shelf = KeyPanel(size: size)
        shelf.level = .statusBar
        shelf.hasShadow = false
        shelf.delegate = self
        shelf.contentView = NSHostingView(rootView: ShelfView(model: model, store: .shared))

        layout()
        hoverZone.orderFrontRegardless()
        NotificationCenter.default.addObserver(self, selector: #selector(layout),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func layout() {
        let notch = screen.notchRect
        model.notchHeight = notch.height
        model.notchWidth = notch.width
        // Without a real notch, keep the hot zone a thin strip so the menu bar stays clickable.
        var zone = notch
        if !screen.hasNotch { zone.origin.y = notch.maxY - 3; zone.size.height = 3 }
        hoverZone.setFrame(zone, display: true)
        shelf.setFrame(NSRect(x: notch.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    func open() {
        guard !model.open else { return }
        layout()
        shelf.orderFrontRegardless()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.open = true }
        outsideSince = nil
        // Only runs while the shelf is open, so idle cost stays at zero.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkMouse() }
    }

    func close() {
        guard model.open else { return }
        watchTimer?.invalidate(); watchTimer = nil
        withAnimation(.easeIn(duration: 0.16)) { model.open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, !self.model.open else { return }
            self.shelf.orderOut(nil)
            self.model.query = ""
        }
    }

    /// Close once the pointer has left the shelf for a moment, unless you're mid-search.
    private func checkMouse() {
        let inside = shelf.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
            || hoverZone.frame.contains(NSEvent.mouseLocation)
        if inside || (!model.query.isEmpty && shelf.isKeyWindow) { outsideSince = nil; return }
        if let t = outsideSince {
            if Date().timeIntervalSince(t) > 0.35 { close() }
        } else {
            outsideSince = Date()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !model.query.isEmpty { close() }
    }
}

private final class HoverView: NSView {
    var onEnter: () -> Void = {}
    private var pending: DispatchWorkItem?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // A tiny delay so swiping past the notch doesn't pop the shelf open.
    override func mouseEntered(with event: NSEvent) {
        let work = DispatchWorkItem { [weak self] in self?.onEnter() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func mouseExited(with event: NSEvent) { pending?.cancel() }
    override func mouseDown(with event: NSEvent) { onEnter() }
}

// MARK: - Memory panel (double-tap right ⌘)

final class PanelModel: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    @Published var copiedID: UUID?
    var close: () -> Void = {}
}

final class PanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()
    private var panel: KeyPanel!
    private var keyMonitor: Any?

    func setup() {
        panel = KeyPanel(size: NSSize(width: 780, height: 560))
        panel.level = .floating
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PanelView(model: model, store: .shared))
        model.close = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        model.query = ""
        model.selection = 0
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.midX - panel.frame.width / 2, y: v.midY - panel.frame.height / 2 + 60))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        installKeys()
    }

    func hide() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// Esc closes, ↑/↓ move, ↩ copies the selected item.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            let count = Store.shared.search(self.model.query).count
            switch e.keyCode {
            case 53: self.hide(); return nil
            case 125: self.model.selection = min(self.model.selection + 1, max(count - 1, 0)); return nil
            case 126: self.model.selection = max(self.model.selection - 1, 0); return nil
            case 36, 76:
                let results = Store.shared.search(self.model.query)
                if results.indices.contains(self.model.selection) { self.copyAndClose(results[self.model.selection]) }
                return nil
            default: return e
            }
        }
    }

    func copyAndClose(_ item: Item) {
        Store.shared.copy(item)
        model.copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.model.copiedID = nil
            self?.hide()
        }
    }
}
