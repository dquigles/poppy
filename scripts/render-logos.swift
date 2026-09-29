// Renders Resources/Logos/src/*.svg to Resources/Logos/*.png: 128×128 px,
// black on a transparent background (DESIGN §7.11). The PNGs are committed:
// re-run this after editing any SVG.
// Usage: swift scripts/render-logos.swift   (works from any directory)
//
// The harness SVGs (all but poppy.svg and poppy-menubar.svg, which are Poppy's own) are lobehub/lobe-icons
// mono marks (MIT License, Copyright (c) 2023 LobeHub; see src/LICENSE-lobe-icons)
// with packed arc flags ("01") expanded ("0 1"), since CoreSVG can't parse the packed form.
import AppKit

let size = 128
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let srcDir = repoRoot.appendingPathComponent("Resources/Logos/src")
let outDir = repoRoot.appendingPathComponent("Resources/Logos")

let svgs = try FileManager.default.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "svg" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !svgs.isEmpty else {
    print("no SVGs found in \(srcDir.path)")
    exit(1)
}

for svg in svgs {
    guard let image = NSImage(contentsOf: svg) else {
        print("could not load \(svg.lastPathComponent)")
        exit(1)
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    image.draw(in: rect)
    // Force pure black wherever the logo has coverage, keeping its alpha.
    NSColor.black.setFill()
    rect.fill(using: .sourceIn)
    NSGraphicsContext.restoreGraphicsState()

    let name = svg.deletingPathExtension().lastPathComponent + ".png"
    try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
    print("wrote Resources/Logos/\(name)")
}
