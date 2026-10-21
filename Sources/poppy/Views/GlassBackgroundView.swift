import AppKit

/// Liquid Glass on macOS 26+, NSVisualEffectView fallback otherwise (DESIGN §10).
/// Callers add their content to `contentView`, inside the glass: the glass switches it to
/// dark text over light backgrounds (beside it, it stayed white on light glass; checked
/// by screenshot).
/// Marks the macOS 26 glass view in `glassLayers` (a type check that compiles for macOS 14).
protocol NSGlassEffectViewMarker {}
@available(macOS 26, *)
extension NSGlassEffectView: NSGlassEffectViewMarker {}

final class GlassBackgroundView: NSView {
    let contentView = NSView()

    /// The glass is drawn by the liquid overlay meanwhile (DESIGN §7.19); the content
    /// still shows, in place and in the glass (a view tracking the mouse must never leave
    /// the window, and content outside the glass doesn't adapt). Only the glass effect's
    /// own layers are hidden: see `glassLayers`.
    var isGlassHidden = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            Self.glassLayers(in: backing).forEach { $0.isHidden = isGlassHidden }
            CATransaction.commit()
        }
    }

    /// Whether the glass can be hidden apart from its content now (it has been drawn and
    /// has the layers `glassLayers` looks for).
    var canHideGlass: Bool { !Self.glassLayers(in: backing).isEmpty }

    /// An NSGlassEffectView (macOS 26) draws the glass with a CABackdropLayer (the blur
    /// and refraction, with its rim) and shows its content through portal layers beside
    /// it, which hide the content itself: hiding the whole view, or the branch holding the
    /// backdrop, hides the content too. Hiding just the backdrop leaves the content.
    /// A private structure, so it's looked up each time and the effects are off without it.
    private static func glassLayers(in glass: NSView) -> [CALayer] {
        func find(_ layer: CALayer) -> [CALayer] {
            String(describing: type(of: layer)) == "CABackdropLayer" ? [layer] : (layer.sublayers ?? []).flatMap(find)
        }
        guard let layer = glass.layer, glass is NSGlassEffectViewMarker else { return [] }
        return find(layer)
    }

    /// Liquid Glass (not the fallback): the liquid drag effects need it, and a glass that
    /// can be hidden apart from its content (`canHideGlass`).
    static var isLiquid: Bool {
        guard #available(macOS 26, *) else { return false }
        return ProcessInfo.processInfo.environment["POPPY_FORCE_FALLBACK"] != "1"
    }

    var cornerRadius: CGFloat {
        didSet { applyCornerRadius() }
    }

    /// Fade when not focused (DESIGN §7.20): the glass with everything in it, one layer
    /// inside this view, whose own alpha belongs to the Space-swipe reveal (§7.16). So a
    /// reveal while faded ends at the faded opacity.
    func setFade(_ alpha: CGFloat, animated: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard backing.alphaValue != alpha else { return }
        guard animated else {
            backing.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            backing.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    var fadeAlpha: CGFloat { backing.alphaValue }

    /// The mouse entered or left (tracked while Poppy isn't active, for the fade).
    var onHoverChange: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?() }
    override func mouseExited(with event: NSEvent) { onHoverChange?() }

    /// Either an NSGlassEffectView (macOS 26+) or an NSVisualEffectView.
    private let backing: NSView

    init(frame: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        let forceFallback = ProcessInfo.processInfo.environment["POPPY_FORCE_FALLBACK"] == "1"

        if #available(macOS 26, *), !forceFallback {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
            glass.style = .regular
            glass.tintColor = nil
            contentView.frame = glass.bounds
            contentView.autoresizingMask = [.width, .height]
            glass.contentView = contentView
            backing = glass
            appLog("glass: native")
        } else {
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            contentView.frame = effect.bounds
            contentView.autoresizingMask = [.width, .height]
            effect.addSubview(contentView)
            backing = effect
            appLog("glass: fallback")
        }

        super.init(frame: frame)
        wantsLayer = true  // the reveal animates this layer (DESIGN §7.16)
        backing.autoresizingMask = [.width, .height]
        addSubview(backing)
        applyCornerRadius()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyCornerRadius() {
        if #available(macOS 26, *), let glass = backing as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else if let effect = backing as? NSVisualEffectView {
            // layer.cornerRadius doesn't reliably clip behind-window blur; a mask image does.
            effect.maskImage = Self.roundedMask(radius: cornerRadius)
        }
    }

    /// Stretchable rounded-rect mask: (2r+1)² image with r-point cap insets.
    /// Nonisolated because AppKit may run the drawing handler off the main thread.
    private nonisolated static func roundedMask(radius r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}
