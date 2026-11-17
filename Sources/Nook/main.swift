import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let clipboard = ClipboardWatcher()
    private let screenshots = ScreenshotWatcher()
    private let hotkeys = DoubleTapDetector()
    private let shelf = ShelfController()
    private let panel = PanelController()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Store.shared
        debugLog("launch: accessibility trusted=\(Permissions.accessibilityTrusted), path=\(Bundle.main.bundlePath)")
        // Ask for Accessibility only on the very first launch; afterwards the menu bar item offers it.
        let askedKey = "askedForAccessibility"
        if !Permissions.accessibilityTrusted && !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            Permissions.requestAccessibility()
        }

        clipboard.start()
        screenshots.start()
        shelf.setup()
        panel.setup()
        shelf.model.openPanel = { [weak self] in
            self?.shelf.close()
            self?.panel.show()
        }

        hotkeys.onLeft = { Capture.region() }
        hotkeys.onRight = { [weak self] in self?.panel.toggle() }
        hotkeys.start()

        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Nook")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuilt each time so the Pause / permission state is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        add("Open Memory  (right ⌘ ⌘)", #selector(openPanel))
        add("Capture Area  (left ⌘ ⌘)", #selector(capture))
        menu.addItem(.separator())
        add(Store.shared.paused ? "Resume Remembering" : "Pause Remembering", #selector(togglePause))
        add("Show Data Folder", #selector(showData))
        add("Clear History…", #selector(clearHistory))
        if !Permissions.accessibilityTrusted {
            menu.addItem(.separator())
            add("Grant Accessibility (for ⌘ ⌘)…", #selector(grantAccess))
        }
        menu.addItem(.separator())
        add("Quit Nook", #selector(quit), "q")
    }

    @objc private func openPanel() { panel.show() }
    @objc private func capture() { Capture.region() }
    @objc private func togglePause() { Store.shared.paused.toggle() }
    @objc private func showData() { NSWorkspace.shared.open(Store.shared.root) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func grantAccess() {
        Permissions.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "This permanently deletes every remembered screenshot and copy."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Store.shared.clearAll() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
