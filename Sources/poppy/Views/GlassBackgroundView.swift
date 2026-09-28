import AppKit

/// Liquid Glass on macOS 26+, NSVisualEffectView fallback otherwise (DESIGN §10).
/// Callers add their content to `contentView`.
final class GlassBackgroundView: NSView {
    let contentView = NSView()

    var cornerRadius: CGFloat {
        didSet { applyCornerRadius() }
    }

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
