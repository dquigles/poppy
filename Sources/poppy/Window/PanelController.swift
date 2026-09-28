import AppKit

/// Owns the panel and its views; screen geometry helpers (DESIGN §7).
/// M3: collapsed pill only; click logs, drag moves (position not persisted yet).
final class PanelController: NSObject {
    static let pillSize = NSSize(width: 168, height: 44)
    static let pillCornerRadius: CGFloat = 22
    static let margin: CGFloat = 16
    static let clampInset: CGFloat = 8

    let panel: GlassPanel
    private let glass: GlassBackgroundView
    private let pillView: PillView
    private var spaceObserver: NSObjectProtocol?

    private(set) var isAnimating = false
    private(set) var pillFrame: NSRect

    override init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        pillFrame = NSRect(origin: Self.defaultPillOrigin(on: screen), size: Self.pillSize)
        panel = GlassPanel(contentRect: pillFrame)

        let bounds = NSRect(origin: .zero, size: Self.pillSize)
        glass = GlassBackgroundView(frame: bounds, cornerRadius: Self.pillCornerRadius)
        glass.autoresizingMask = [.width, .height]
        pillView = PillView(frame: glass.contentView.bounds, title: "claude")
        pillView.autoresizingMask = [.width, .height]
        super.init()

        pillView.controller = self
        glass.contentView.addSubview(pillView)
        panel.contentView = glass
        panel.allowsKey = false

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        }

        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    // MARK: - Pill interaction

    func pillClicked() {
        appLog("pill clicked")
    }

    func pillDragEnded() {
        let frame = Self.clamp(panel.frame, in: Self.screen(for: panel.frame))
        panel.setFrame(frame, display: true)
        pillFrame = frame
        panel.invalidateShadow()
    }

    // MARK: - Context menu

    func showContextMenu(event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let restart = NSMenuItem(title: "Restart Agent", action: #selector(restartAgent), keyEquivalent: "")
        restart.target = self
        restart.isEnabled = false  // no terminal session until M5
        menu.addItem(restart)

        let quit = NSMenuItem(title: "Quit Poppy", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func restartAgent() {}

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Geometry (DESIGN §7.2–7.4)

    static func defaultPillOrigin(on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(x: visible.maxX - margin - pillSize.width, y: visible.minY + margin)
    }

    /// Screen containing the rect's center, else largest intersection, else main, else first.
    static func screen(for rect: NSRect) -> NSScreen {
        let screens = NSScreen.screens
        let center = NSPoint(x: rect.midX, y: rect.midY)
        if let hit = screens.first(where: { $0.frame.contains(center) }) {
            return hit
        }
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea {
                best = screen
                bestArea = area
            }
        }
        return best ?? NSScreen.main ?? screens[0]
    }

    /// Screen under the mouse pointer, edges included (else main).
    static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Stable identity for comparing screens (NSScreen objects can be recreated).
    static func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    /// Shift `frame` inside the inset visible area, never shrinking it. An axis that
    /// doesn't fit is aligned to the area's left (x) or top (y) edge.
    static func clamp(_ frame: NSRect, in screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame.insetBy(dx: clampInset, dy: clampInset)
        var result = frame
        if frame.width > area.width {
            result.origin.x = area.minX
        } else {
            result.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        }
        if frame.height > area.height {
            result.origin.y = area.maxY - frame.height
        } else {
            result.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        }
        return result
    }
}
