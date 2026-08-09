import AppKit

// Entry point: create the shared application, install the delegate, hide the
// Dock icon, and run the AppKit event loop.
//
// The packaging script sets LSUIElement in Info.plist for the assembled
// bundle; the accessory activation policy also covers `swift run` development
// so the Dock icon never appears in either mode.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
