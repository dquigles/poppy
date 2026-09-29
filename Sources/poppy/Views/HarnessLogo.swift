import AppKit

/// The agent CLI Poppy is running, detected from the command (DESIGN §7.11).
/// Drives the pill logo.
nonisolated enum Harness: Sendable {
    case claude, codex, gemini, opencode, other

    /// From the command's first word, e.g. "/usr/local/bin/claude --x" -> .claude.
    /// Aliases and wrappers (e.g. "npx …") are `.other`.
    init(command: String) {
        // The first word after any leading NAME=value assignments.
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        let first = words.first(where: { !AgentProfile.isAssignment($0) }) ?? command
        switch (first as NSString).lastPathComponent.lowercased() {
        case "claude": self = .claude
        case "codex": self = .codex
        case "gemini": self = .gemini
        case "opencode": self = .opencode
        default: self = .other
        }
    }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .opencode: "opencode"
        case .other: "Poppy"
        }
    }
}

/// Logo images for a harness: transparent black PNGs (128×128 px) used as template
/// images, so they tint black or white to match their background (DESIGN §7.11).
enum HarnessLogo {
    /// Looks in the app bundle's Contents/Resources/Logos (scripts/bundle.sh copies them
    /// there), then, in debug builds only, in the repo's Resources/Logos for `swift run`.
    private static let directories: [URL] = {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL {
            dirs.append(resources.appendingPathComponent("Logos"))
        }
        #if DEBUG
        let repoRoot = URL(fileURLWithPath: #filePath)  // Sources/poppy/Views/HarnessLogo.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(repoRoot.appendingPathComponent("Resources/Logos"))
        #endif
        return dirs
    }()

    private static func fileName(for harness: Harness) -> String {
        switch harness {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        case .opencode: "opencode"
        case .other: "poppy"  // unrecognized CLIs and plain shells
        }
    }

    /// Template logo sized `points` × `points`; `.other` is the Poppy logo.
    static func image(for harness: Harness, points: CGFloat) -> NSImage {
        image(named: fileName(for: harness), points: points, description: harness.displayName)
    }

    /// Poppy's own logo (the menu bar icon, DESIGN §7.12).
    static func poppy(points: CGFloat) -> NSImage {
        image(named: "poppy", points: points, description: "Poppy")
    }

    /// A missing file falls back to SF Symbol `terminal` (natural size).
    private static func image(named name: String, points: CGFloat, description: String) -> NSImage {
        let image: NSImage
        if let loaded = load(name) {
            loaded.size = NSSize(width: points, height: points)
            image = loaded
        } else {
            image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    private static func load(_ name: String) -> NSImage? {
        for dir in directories {
            let url = dir.appendingPathComponent(name + ".png")
            if let image = NSImage(contentsOf: url) { return image }
        }
        appLog("logo: \(name).png not found in \(directories.map(\.path))")
        return nil
    }
}
