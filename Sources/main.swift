import AppKit

// Menu bar app: no Dock icon (LSUIElement), lives in the status bar.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
