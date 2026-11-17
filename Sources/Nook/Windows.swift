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
    @Published var copiedID: UUID?
    var notchHeight: CGFloat = 32
    var notchWidth: CGFloat = 200
    /// Size of the black shelf itself; the window is a little bigger to leave room for its shadow.
    let width: CGFloat = 720
    let height: CGFloat = 256
    var close: () -> Void = {}
    var copy: (Item) -> Void = { _ in }
    var openPanel: () -> Void = {}
}

final class ShelfController: NSObject, NSWindowDelegate {
    let model = ShelfModel()
    private var hoverZone: NSPanel!
    private var shelf: KeyPanel!
    private var watchTimer: Timer?
    private var outsideSince: Date?
    private var windowSize: NSSize { NSSize(width: model.width + 80, height: model.height + 60) }

    private var screen: NSScreen {
        NSScreen.screens.first(where: \.hasNotch) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func setup() {
        model.close = { [weak self] in self?.close() }
        model.copy = { [weak self] item in self?.copy(item) }

        hoverZone = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hoverZone.isOpaque = false
        hoverZone.backgroundColor = .clear
        hoverZone.level = .statusBar
        hoverZone.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hv = HoverView()
        hv.onEnter = { [weak self] in self?.open() }
        hoverZone.contentView = hv

        shelf = KeyPanel(size: windowSize)
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
        let size = windowSize
        shelf.setFrame(NSRect(x: notch.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// The black shelf's own rectangle in screen coordinates (the window around it is larger).
    private var shelfRect: NSRect {
        let f = shelf.frame
        return NSRect(x: f.midX - model.width / 2, y: f.maxY - model.height, width: model.width, height: model.height)
    }

    func open() {
        guard !model.open else { return }
        layout()
        model.copiedID = nil
        shelf.orderFrontRegardless()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) { model.open = true }
        outsideSince = nil
        // Only runs while the shelf is open, so idle cost stays at zero.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkMouse() }
    }

    func close() {
        guard model.open else { return }
        watchTimer?.invalidate(); watchTimer = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.95)) { model.open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, !self.model.open else { return }
            self.shelf.orderOut(nil)
            self.model.query = ""
            self.model.copiedID = nil
        }
    }

    /// Copies with a quick "Copied" tick on the card, then folds the shelf back into the notch.
    func copy(_ item: Item) {
        Store.shared.writeToPasteboard(item)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { model.copiedID = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Store.shared.bump(item) }
        }
    }

    /// Close once the pointer has left the shelf for a moment, unless you're mid-search.
    private func checkMouse() {
        let mouse = NSEvent.mouseLocation
        let inside = shelfRect.insetBy(dx: -10, dy: -10).contains(mouse) || hoverZone.frame.contains(mouse)
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

enum PanelFilter: String, CaseIterable {
    case all = "All"
    case screenshots = "Screenshots"
    case text = "Text"

    func matches(_ item: Item) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return item.kind == .image
        case .text: return item.kind == .text
        }
    }
}

final class PanelModel: ObservableObject {
    @Published var query = ""
    @Published var filter: PanelFilter = .all
    @Published var selection = 0
    @Published var copiedID: UUID?
    @Published var toast: String?
    @Published var appeared = false
    @Published var focusToken = 0

    var close: () -> Void = {}
    var copyAndClose: (Item) -> Void = { _ in }
    var copyTextAndClose: (Item, String) -> Void = { _, _ in }

    /// Results for the current search and filter, newest first.
    func results() -> [Item] {
        let f = filter
        return Store.shared.search(query).filter { f.matches($0) }
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()
    private var panel: KeyPanel!
    private var keyMonitor: Any?
    private var hideToken: UUID?
    private let size = NSSize(width: 860, height: 540)

    func setup() {
        panel = KeyPanel(size: size)
        panel.level = .floating
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PanelView(model: model, store: .shared))
        model.close = { [weak self] in self?.hide() }
        model.copyAndClose = { [weak self] item in self?.copyAndClose(item) }
        model.copyTextAndClose = { [weak self] item, text in self?.copyTextAndClose(item, text) }
    }

    var isVisible: Bool { panel.isVisible && model.appeared }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        hideToken = nil
        model.query = ""
        model.filter = .all
        model.selection = 0
        model.copiedID = nil
        model.toast = nil
        model.appeared = false
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2 + 50,
                              width: size.width, height: size.height), display: false)
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
        DispatchQueue.main.async { [weak self] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self?.model.appeared = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.panel.invalidateShadow() }
        installKeys()
    }

    func hide() {
        guard panel.isVisible else { return }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        withAnimation(.easeIn(duration: 0.12)) { model.appeared = false }
        let token = UUID()
        hideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.panel.orderOut(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// ↑/↓ move, ↩ copies, ⇧↩ copies a screenshot's text, ⇥ switches filter, esc clears then closes.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            let results = self.model.results()
            let shift = e.modifierFlags.contains(.shift)
            switch e.keyCode {
            case 53:
                if self.model.query.isEmpty { self.hide() } else { self.model.query = "" }
                return nil
            case 125: self.move(1, in: results.count); return nil
            case 126: self.move(-1, in: results.count); return nil
            case 48: self.cycleFilter(backwards: shift); return nil
            case 36, 76:
                guard results.indices.contains(self.model.selection) else { return nil }
                let item = results[self.model.selection]
                if shift, item.kind == .image, let ocr = item.ocr, !ocr.isEmpty {
                    self.copyTextAndClose(item, ocr)
                } else {
                    self.copyAndClose(item)
                }
                return nil
            default:
                return e
            }
        }
    }

    private func move(_ delta: Int, in count: Int) {
        guard count > 0 else { return }
        let next = min(max(model.selection + delta, 0), count - 1)
        withAnimation(.easeOut(duration: 0.12)) { model.selection = next }
    }

    private func cycleFilter(backwards: Bool) {
        let all = PanelFilter.allCases
        let i = all.firstIndex(of: model.filter) ?? 0
        let next = all[(i + (backwards ? all.count - 1 : 1)) % all.count]
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { model.filter = next }
    }

    func copyAndClose(_ item: Item) {
        Store.shared.writeToPasteboard(item)
        finishCopy(item, toast: item.kind == .image ? "Screenshot copied" : "Copied")
    }

    func copyTextAndClose(_ item: Item, _ text: String) {
        Store.shared.copyString(text)
        finishCopy(item, toast: "Text copied")
    }

    /// Shows a tick, closes, then moves the item to the top, so the list doesn't jump while you watch.
    private func finishCopy(_ item: Item, toast: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            model.copiedID = item.id
            model.toast = toast
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Store.shared.bump(item) }
        }
    }
}
