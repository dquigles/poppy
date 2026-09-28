import AppKit

/// Owns the panel and its views. M2: a spike panel to verify fullscreen/Spaces
/// behavior and key input without activation (DESIGN §13).
final class PanelController: NSObject {
    private static let spikeSize = NSSize(width: 240, height: 80)
    private static let margin: CGFloat = 16

    let panel: GlassPanel
    private var spaceObserver: NSObjectProtocol?

    override init() {
        let size = Self.spikeSize
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let origin = NSPoint(x: visible.maxX - Self.margin - size.width, y: visible.minY + Self.margin)
        panel = GlassPanel(contentRect: NSRect(origin: origin, size: size))
        super.init()

        let background = SpikeBackgroundView(frame: NSRect(origin: .zero, size: size))
        background.controller = self
        background.autoresizingMask = [.width, .height]

        let field = NSTextField(frame: NSRect(x: 16, y: (size.height - 24) / 2, width: size.width - 32, height: 24))
        field.placeholderString = "Type here to test focus"
        field.autoresizingMask = [.width]
        background.addSubview(field)

        panel.contentView = background
        panel.allowsKey = true  // M2 spike: always key-capable so the text field can be tested

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        }

        panel.orderFrontRegardless()
    }

    func showContextMenu(event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let quit = NSMenuItem(title: "Quit Poppy", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// M2 spike content: translucent rounded HUD that logs the frontmost app on click.
private final class SpikeBackgroundView: NSVisualEffectView {
    weak var controller: PanelController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        appLog("click; frontmost app = \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(event: event, in: self)
    }
}
