import AppKit

/// A damped spring for one value, stepped at display rate (DESIGN §7.19).
struct Spring {
    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0

    init(_ value: CGFloat) {
        self.value = value
        target = value
    }

    mutating func step(_ dt: CGFloat, stiffness k: CGFloat, damping zeta: CGFloat) {
        let acceleration = -k * (value - target) - 2 * sqrt(k) * zeta * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    var isSettled: Bool { abs(value - target) < 0.2 && abs(velocity) < 2 }
}

/// A glass shape on springs: center, size and corner radius, in screen coordinates.
/// Position and shape have their own stiffness, so a shape can follow the mouse tightly
/// and still wobble as it changes from a row into a pill.
struct GlassShape {
    var cx, cy, width, height, radius: Spring
    var moveStiffness: CGFloat = 420
    var moveDamping: CGFloat = 0.72
    var shapeStiffness: CGFloat = 300
    var shapeDamping: CGFloat = 0.55

    init(_ rect: NSRect, radius: CGFloat) {
        cx = Spring(rect.midX)
        cy = Spring(rect.midY)
        width = Spring(rect.width)
        height = Spring(rect.height)
        self.radius = Spring(radius)
    }

    var rect: NSRect {
        NSRect(x: cx.value - width.value / 2, y: cy.value - height.value / 2,
               width: max(width.value, 1), height: max(height.value, 1))
    }

    var target: NSRect {
        NSRect(x: cx.target - width.target / 2, y: cy.target - height.target / 2,
               width: width.target, height: height.target)
    }

    mutating func aim(at rect: NSRect, radius: CGFloat) {
        cx.target = rect.midX
        cy.target = rect.midY
        width.target = rect.width
        height.target = rect.height
        self.radius.target = radius
    }

    /// Jumps there, no spring (a shape pinned to a window that moves with the mouse).
    mutating func place(at rect: NSRect, radius: CGFloat) {
        aim(at: rect, radius: radius)
        for keyPath in [\GlassShape.cx, \.cy, \.width, \.height, \.radius] {
            self[keyPath: keyPath].value = self[keyPath: keyPath].target
            self[keyPath: keyPath].velocity = 0
        }
    }

    mutating func motion(stiffness: CGFloat, damping: CGFloat) {
        moveStiffness = stiffness
        moveDamping = damping
    }

    mutating func step(_ dt: CGFloat) {
        cx.step(dt, stiffness: moveStiffness, damping: moveDamping)
        cy.step(dt, stiffness: moveStiffness, damping: moveDamping)
        width.step(dt, stiffness: shapeStiffness, damping: shapeDamping)
        height.step(dt, stiffness: shapeStiffness, damping: shapeDamping)
        radius.step(dt, stiffness: shapeStiffness, damping: 0.9)
    }

    var isSettled: Bool {
        cx.isSettled && cy.isSettled && width.isSettled && height.isSettled && radius.isSettled
    }

    /// A push outward, for the bounce when something flows into it.
    mutating func bump(_ speed: CGFloat) {
        width.velocity += speed
        height.velocity += speed
    }
}

/// One glass shape in the overlay. A pill's or a panel's own content stays in its window
/// (above the overlay); only a dragged row carries content here: its logo and name, which
/// fade into the pill's logo as it becomes a pill.
@available(macOS 26, *)
final class LiquidBlob {
    let glass = NSGlassEffectView()
    var shape: GlassShape
    private let logo: NSImageView?
    private let label: NSTextField?
    /// The row → pill morph: the size it counts as a row, and the pill's logo size.
    private let rowWidth: CGFloat
    private let pillLogo: CGFloat
    /// Fades the content (flowing into another pill).
    var contentAlpha: CGFloat = 1

    init(rect: NSRect, radius: CGFloat, logo image: NSImage? = nil, tint: NSColor? = nil, name: String? = nil,
         pillLogo: CGFloat = 24) {
        shape = GlassShape(rect, radius: radius)
        rowWidth = rect.width
        self.pillLogo = pillLogo
        glass.style = .regular
        glass.cornerRadius = radius
        let inner = NSView()
        if let image {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.contentTintColor = tint ?? .labelColor
            view.unregisterDraggedTypes()
            inner.addSubview(view)
            logo = view
        } else {
            logo = nil
        }
        if let name {
            let field = NSTextField(labelWithString: name)
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            inner.addSubview(field)
            label = field
        } else {
            label = nil
        }
        glass.contentView = inner
    }

    /// Places the glass from the springs. Between a row and a pill the name fades out and
    /// the logo grows and moves to the middle.
    func apply(origin: NSPoint) {
        let rect = shape.rect.offsetBy(dx: -origin.x, dy: -origin.y)
        if glass.frame != rect { glass.frame = rect }
        glass.cornerRadius = min(max(shape.radius.value, 0), min(rect.width, rect.height) / 2)
        guard let logo else { return }
        let squareness = rowWidth > rect.height ? max(0, min(1, (rowWidth - rect.width) / (rowWidth - rect.height))) : 1
        let size = SidebarRowMetrics.logo + (pillLogo - SidebarRowMetrics.logo) * squareness
        let rowX = SidebarRowMetrics.logoX
        let x = rowX + ((rect.width - size) / 2 - rowX) * (label == nil ? 1 : squareness)
        logo.frame = NSRect(x: x, y: (rect.height - size) / 2, width: size, height: size)
        logo.alphaValue = contentAlpha
        if let label {
            let labelX = SidebarRowMetrics.labelX
            label.sizeToFit()
            label.frame = NSRect(x: labelX, y: (rect.height - label.frame.height) / 2,
                                 width: max(rect.width - labelX - 8, 0), height: label.frame.height)
            label.alphaValue = contentAlpha * (1 - min(1, squareness * 2))
        }
    }
}

/// Where a sidebar row draws its logo and name, shared with the row blob.
enum SidebarRowMetrics {
    static let logo: CGFloat = 16
    static let logoX: CGFloat = 8
    static let labelX: CGFloat = 8 + 16 + 7
}

/// One transparent window covering a screen, whose glass container merges the glass of
/// everything taking part in a drag: shapes that come within `spacing` flow together, and
/// pull apart like liquid (DESIGN §7.19). The windows involved hide their own glass and
/// shadow meanwhile and stay above it (a window level lower) with their content; the
/// overlay's shadow draws the rims. It never takes the mouse or the keyboard.
@available(macOS 26, *)
final class LiquidOverlay {
    static let spacing: CGFloat = 28

    private let window: NSPanel
    private let container = NSGlassEffectContainerView()
    private let content = NSView()
    private(set) var blobs: [LiquidBlob] = []
    private var timer: Timer?
    /// Every frame, after the springs moved: the drag updates targets and finishes.
    var onFrame: (() -> Void)?
    private(set) var screen: NSScreen?

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        container.spacing = Self.spacing
        container.contentView = content
        window.contentView = container
    }

    var isActive: Bool { window.isVisible }
    var level: NSWindow.Level { window.level }

    /// Covers `screen` at `level`. Windows that must stay above it with their content (the
    /// pills whose glass it draws) get a higher level meanwhile (`LiquidDrag.lend`):
    /// ordering a never-activated app's windows relative to each other didn't hold (the
    /// overlay's glass covered them, checked by screenshot).
    func show(on screen: NSScreen, at level: NSWindow.Level) {
        window.level = level
        if self.screen.flatMap(PanelController.screenNumber) != PanelController.screenNumber(screen) || !window.isVisible {
            self.screen = screen
            window.setFrame(screen.frame, display: false)
            content.frame = container.bounds
        }
        window.orderFrontRegardless()
        startTimer()
    }

    func add(_ blob: LiquidBlob) {
        blobs.append(blob)
        content.addSubview(blob.glass)
        blob.apply(origin: window.frame.origin)
        window.invalidateShadow()
    }

    /// Draws `blob` where its shape is now, without waiting for the next frame.
    func redraw(_ blob: LiquidBlob) {
        blob.apply(origin: window.frame.origin)
        window.invalidateShadow()
    }

    func remove(_ blob: LiquidBlob) {
        blobs.removeAll { $0 === blob }
        blob.glass.removeFromSuperview()
        window.invalidateShadow()
    }

    /// Ends it: every blob goes and the window leaves the screen.
    func clear() {
        timer?.invalidate()
        timer = nil
        blobs.forEach { $0.glass.removeFromSuperview() }
        blobs = []
        window.orderOut(nil)
        screen = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func frame() {
        let origin = window.frame.origin
        for blob in blobs {
            blob.shape.step(1.0 / 120)
            blob.apply(origin: origin)
        }
        window.invalidateShadow()
        onFrame?()
    }
}
