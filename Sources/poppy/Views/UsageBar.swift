import AppKit

/// Formatting and colors shared by the footer and the pill ring (DESIGN §7.9, §7.11).
enum UsageStyle {
    static let warnPercent: Double = 90

    static func fill(for window: UsageWindow) -> NSColor {
        window.usedPercent >= warnPercent ? .systemRed : NSColor.labelColor.withAlphaComponent(0.75)
    }

    /// Computed on each use, so it's resolved for the appearance being drawn (a stored
    /// `withAlphaComponent` copy kept the appearance it was first used in).
    static var track: NSColor { NSColor.labelColor.withAlphaComponent(0.15) }

    /// The pill ring: the logo's neutral color, never red (the user's choice in M15).
    /// Call inside `performAsCurrentDrawingAppearance`.
    static var ringColor: CGColor { NSColor.labelColor.cgColor.copy(alpha: 0.75) ?? NSColor.labelColor.cgColor }

    /// "42m", "3h 5m", "2d 4h"; nil if past or unknown.
    static func countdown(to date: Date?, from now: Date = Date()) -> String? {
        guard let date else { return nil }
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

/// The expanded view's usage footer: one meter per window (DESIGN §7.9).
final class UsageBar: NSView {
    static let height: CGFloat = 22

    weak var controller: PanelController?

    private let stack = NSStackView()
    private let message = NSTextField(labelWithString: "")
    private let groups = [UsageGroup(fallback: "5h"), UsageGroup(fallback: "7d")]

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 20
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(message)
        for group in groups { stack.addArrangedSubview(group) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        show(nil, reason: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A report, or "loading" / "unavailable" (with the reason in the tooltip).
    func show(_ report: UsageReport?, reason: String?) {
        if let report {
            message.isHidden = true
            for (group, window) in zip(groups, [report.short, report.long]) { group.show(window) }
            setAccessibilityLabel("Usage: " + groups.compactMap(\.summary).joined(separator: ", "))
        } else {
            message.isHidden = false
            message.stringValue = reason == nil ? "Usage: loading…" : "Usage unavailable"
            message.toolTip = reason
            for group in groups { group.show(nil) }
            setAccessibilityLabel(message.stringValue)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(event: event, in: self)
    }
}

/// "5h ▬▬ 9% left · resets in 1h 26m".
private final class UsageGroup: NSView {
    private let fallback: String
    private let label = NSTextField(labelWithString: "")
    private let meter = UsageMeter()
    private let detail = NSTextField(labelWithString: "")
    private(set) var summary: String?

    init(fallback: String) {
        self.fallback = fallback
        super.init(frame: .zero)
        let stack = NSStackView(views: [label, meter, detail])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for field in [label, detail] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
        }
        label.font = .systemFont(ofSize: 11, weight: .medium)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            meter.widthAnchor.constraint(equalToConstant: 48),
            meter.heightAnchor.constraint(equalToConstant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ window: UsageWindow?) {
        guard let window else {
            isHidden = true
            summary = nil
            return
        }
        isHidden = false
        let name = window.label(fallback: fallback)
        label.stringValue = name
        meter.usage = window
        var text = UsageStyle.percent(window.leftPercent) + " left"
        if let countdown = UsageStyle.countdown(to: window.resetsAt) { text += " · resets in " + countdown }
        detail.stringValue = text
        summary = "\(name) \(text)"
        var tip = "\(UsageStyle.percent(window.usedPercent)) of the \(name) limit used"
        if let resets = window.resetsAt, resets > Date() {
            let formatter = DateFormatter()
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            tip += ", resets \(formatter.string(from: resets))"
        }
        toolTip = tip
    }
}

/// A small capsule filled to the used fraction.
private final class UsageMeter: NSView {
    var usage: UsageWindow? { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        UsageStyle.track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard let usage, usage.usedPercent > 0 else { return }
        var fill = bounds
        fill.size.width = max(bounds.height, bounds.width * usage.usedPercent / 100)
        UsageStyle.fill(for: usage).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
