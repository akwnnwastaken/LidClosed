import AppKit

// Entry point for the LidClosed menu bar application.
// Sets up the NSApplication with our AppDelegate and starts the run loop.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
