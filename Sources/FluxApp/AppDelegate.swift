import AppKit
import FluxCore

/// Application delegate for the menu bar skeleton (batch 001).
///
/// Displays a status item with the frozen menu entries from `FluxMenuEntry`.
/// No event tap and no Accessibility permission work happens in this batch;
/// the non-quit entries are placeholders that later batches wire to behavior.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = AppMetadata.current.appName
        item.button?.toolTip = "\(AppMetadata.current.appName) \(AppMetadata.current.version)"

        let menu = NSMenu()
        for entry in FluxMenuEntry.allCases {
            let menuItem = NSMenuItem(
                title: entry.title,
                action: #selector(menuItemSelected(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = entry.rawValue
            menu.addItem(menuItem)
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let entry = FluxMenuEntry(rawValue: rawValue) else {
            return
        }
        switch entry {
        case .quit:
            NSApp.terminate(nil)
        case .pause, .permissions, .launchAtLogin, .showShortcuts:
            // Placeholder: wired to real behavior in later batches.
            NSLog("Flux: menu entry %@ is a placeholder in batch 001", entry.rawValue)
        }
    }
}
