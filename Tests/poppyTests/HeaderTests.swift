import AppKit
import Testing
@testable import poppy

/// The header's title opens the folder menu on a click (DESIGN §7.9).
struct HeaderTests {
    private func header() -> (HeaderView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 600, height: 36),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let header = HeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 36), title: "poppy")
        window.contentView = header
        header.layoutSubtreeIfNeeded()
        return (header, window)
    }

    private func click(_ header: HeaderView, at point: NSPoint) {
        let location = header.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                           windowNumber: header.window!.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            type == .leftMouseDown ? header.mouseDown(with: event) : header.mouseUp(with: event)
        }
    }

    @Test func clickOnTheTitleOpensTheMenu() {
        let (header, window) = header()
        defer { window.close() }
        var shownFrom: NSView?
        header.onTitleClick = { shownFrom = $0 }
        click(header, at: NSPoint(x: 300, y: 18))
        #expect(shownFrom != nil)
        #expect(shownFrom.map { header.convert($0.frame, from: $0.superview).contains(NSPoint(x: 300, y: 18)) } == true)
    }

    @Test func clickBesideTheTitleOnlyDrags() {
        let (header, window) = header()
        defer { window.close() }
        var clicks = 0
        header.onTitleClick = { _ in clicks += 1 }
        click(header, at: NSPoint(x: 120, y: 18))
        #expect(clicks == 0)
    }

    @Test func noMenuOnTheSettingsPage() {
        let (header, window) = header()
        defer { window.close() }
        var clicks = 0
        header.onTitleClick = { _ in clicks += 1 }
        header.setShowsSettings(true)
        header.layoutSubtreeIfNeeded()
        click(header, at: NSPoint(x: 300, y: 18))
        #expect(clicks == 0)
        header.setShowsSettings(false)
        header.layoutSubtreeIfNeeded()
        click(header, at: NSPoint(x: 300, y: 18))
        #expect(clicks == 1)
    }

    @Test func titleButtonsStillTakeTheirClicks() {
        let (header, window) = header()
        defer { window.close() }
        // ＋ at the left edge and fold at the right are buttons, not the drag area.
        #expect(header.hitTest(NSPoint(x: 12, y: 18)) is NSButton)
        #expect(header.hitTest(NSPoint(x: 588, y: 18)) is NSButton)
        #expect(header.hitTest(NSPoint(x: 300, y: 18)) === header)  // the title drags too
    }
}
