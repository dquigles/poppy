import AppKit

// `poppy [options] [directory]` from the shell (DESIGN §9.9): act as a client, not the app.
if CommandLine.arguments.dropFirst().first == CommandLineClient.flag {
    exit(CommandLineClient.run(Array(CommandLine.arguments.dropFirst(2))))
}

let app = NSApplication.shared
let appDelegate = AppDelegate()  // global strong ref; app.delegate is weak
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
