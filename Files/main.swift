import AppKit

// AppKit lifecycle without @main: create the application, install the
// delegate (kept alive by this top-level constant), and run the event loop.
let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.regular)
application.run()
