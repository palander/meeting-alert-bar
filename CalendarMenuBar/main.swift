import AppKit

// LSUIElement=YES in Info.plist prevents the Dock icon at launch.
// setActivationPolicy is a defensive fallback for the same effect.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
