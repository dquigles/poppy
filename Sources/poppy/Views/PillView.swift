import AppKit

/// Collapsed content: the harness logo. Click expands, drag moves (DESIGN §7.8, §7.11).
final class PillView: NSView {
    weak var controller: PanelController?

    private var drag = WindowDrag()
    private let logo = NSImageView()

    /// Logo size on the default 44 pt pill.
    static let baseLogoPoints: CGFloat = 24

    /// Logo size for a pill diameter, scaled from the default (DESIGN §7.14).
    static func logoSize(forDiameter diameter: CGFloat) -> CGFloat {
        (diameter * baseLogoPoints / 44).rounded()
    }
    private var logoWidth: NSLayoutConstraint?
    /// The harness name (tooltip and accessibility label), before any status is added.
    private var baseLabel = ""
    private var status = AgentStatus.idle
    private var logoHeight: NSLayoutConstraint?
    /// The 5-hour usage ring just inside the glass edge, uncolored and with no track
    /// (DESIGN §7.11, §9.7).
    private let ring = CAShapeLayer()
    private var usage: UsageWindow?

    /// `title` names the CLI (DESIGN §7.11); it labels the pill when the harness isn't recognized.
    init(frame: NSRect, harness: Harness, title: String) {
        super.init(frame: frame)

        // NSImageView registers for image drags itself; it would take drops over the middle
        // of the pill and refuse them (DESIGN §9.10).
        logo.unregisterDraggedTypes()
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.contentTintColor = .labelColor  // black in light mode, white in dark
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        let size = Self.logoSize(forDiameter: frame.width)
        let width = logo.widthAnchor.constraint(equalToConstant: size)
        let height = logo.heightAnchor.constraint(equalToConstant: size)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            width, height,
        ])
        logoWidth = width
        logoHeight = height

        wantsLayer = true
        ring.fillColor = nil
        ring.lineCap = .round
        ring.isHidden = true
        layer?.addSublayer(ring)
        registerForDraggedTypes(Attachments.dropTypes)  // drop onto the pill (DESIGN §9.10)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(harness: harness, title: title)
    }

    /// Shows `harness`'s logo; also called when the agent is switched (DESIGN §9.5).
    func update(harness: Harness, title: String) {
        logo.image = HarnessLogo.image(for: harness, points: Self.baseLogoPoints)  // scaled by the constraints
        baseLabel = harness == .other ? title : harness.displayName
        updateLabel()
    }

    /// Status color for the logo, and the status in the tooltip and accessibility label,
    /// so it isn't conveyed by color alone (DESIGN §9.6).
    func setStatus(_ status: AgentStatus) {
        self.status = status
        logo.contentTintColor = status.tint ?? .labelColor
        updateLabel()
    }

    private func updateLabel() {
        let suffix = switch status {
        case .idle: ""
        case .working: " (working)"
        case .waiting: " (needs input)"
        case .done: " (done)"
        }
        var usageSuffix = ""
        if let usage {
            if let name = usage.name {
                let period = usage.minutes == 10080 ? " weekly" : usage.minutes == 1440 ? " daily" : ""
                usageSuffix = " · \(UsageStyle.percent(usage.usedPercent)) of the \(name)\(period) limit used"
            } else {
                usageSuffix = " · \(UsageStyle.percent(usage.usedPercent)) of \(usage.label(fallback: "5h")) used"
            }
        }
        toolTip = baseLabel + suffix + usageSuffix
        setAccessibilityLabel(baseLabel + suffix + usageSuffix)
    }

    /// The short window's usage for the ring; nil hides it (DESIGN §7.11).
    func setUsage(_ window: UsageWindow?) {
        guard window != usage else { return }
        usage = window
        ring.isHidden = window == nil
        ring.strokeEnd = (window?.usedPercent ?? 0) / 100
        updateRingColors()
        updateLabel()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let lineWidth = 2.5 * bounds.width / 44
        let radius = bounds.width / 2 - lineWidth / 2 - 1.5
        let path = CGMutablePath()
        // From 12 o'clock, clockwise (the layer's y axis points up).
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(radius, 1),
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        ring.frame = bounds
        ring.path = path
        ring.lineWidth = lineWidth
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRingColors()
    }

    /// Layers take CGColors, so dynamic colors are resolved for the current appearance.
    private func updateRingColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = UsageStyle.ringColor
        }
    }

    /// Called when the pill size preset changes (DESIGN §7.14).
    func setDiameter(_ diameter: CGFloat) {
        let size = Self.logoSize(forDiameter: diameter)
        logoWidth?.constant = size
        logoHeight?.constant = size
    }

    override func accessibilityPerformPress() -> Bool {
        guard let controller, !controller.isAnimating else { return false }
        controller.expand()
        return true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole pill handles the mouse; the logo never swallows clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        drag.cancel()
        guard let controller, !controller.isAnimating, let window else { return }
        drag.begin(window: window)
    }

    override func mouseDragged(with event: NSEvent) {
        // An animation started mid-drag (e.g. the hotkey) owns the frame now.
        guard let controller, !controller.isAnimating, let window else {
            drag.cancel()
            return
        }
        drag.moved(window: window)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag.isTracking else { return }
        if drag.end() {
            controller?.pillDragEnded()
        } else {
            controller?.pillClicked()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(event: event, in: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.canAcceptDrop == true ? Attachments.operation(for: sender) : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.canAcceptDrop == true ? Attachments.operation(for: sender) : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Attachments.logDrag(sender, "on pill")
        return controller?.dropped(sender.draggingPasteboard) ?? false
    }
}

/// Manual window drag with a 3pt click-vs-drag threshold, in screen coordinates.
struct WindowDrag {
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private(set) var isTracking = false
    private var isDragging = false

    mutating func cancel() {
        isTracking = false
        isDragging = false
    }

    mutating func begin(window: NSWindow) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window.frame.origin
        isTracking = true
        isDragging = false
    }

    mutating func moved(window: NSWindow) {
        guard isTracking else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        if !isDragging && hypot(dx, dy) > 3 {
            isDragging = true
        }
        if isDragging {
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }
    }

    /// Ends tracking; returns true if the gesture was a drag (false for a click or no gesture).
    mutating func end() -> Bool {
        let wasDrag = isTracking && isDragging
        cancel()
        return wasDrag
    }
}
