import AppKit

let app = NSApplication.shared
let appDelegate = AppDelegate()  // global strong ref; app.delegate is weak
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
