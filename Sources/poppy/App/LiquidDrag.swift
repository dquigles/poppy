import AppKit

/// The Liquid Glass side of dragging (DESIGN §7.19): while a row or a pill is dragged, the
/// glass of the dragged shape and of collapsed pills near it is drawn by one
/// `LiquidOverlay`, so shapes that come close flow together and tear apart like liquid.
/// An open panel's glass is never drawn there: the overlay can't draw large glass the way
/// the panel draws its own (which adapts to what's behind it, having grown from the pill),
/// so the panel would change look (checked by screenshot). The model changes
/// (`PillManager.move` / `merge`) happen at the drop, as without it; this only animates.
/// Windows' frames are never set from a spring: they keep their exact frames, and a new
/// pill gets its final frame at once (hidden until it lands).
@available(macOS 26, *)
final class LiquidDrag {
    unowned let manager: PillManager
    private let overlay = LiquidOverlay()
    /// Pills whose glass the overlay draws now, each with its blob and its own window level
    /// (raised above the overlay meanwhile).
    private var lent: [(pill: PanelController, blob: LiquidBlob, level: NSWindow.Level)] = []
    /// A drop's animation is running; another drag doesn't start a liquid one meanwhile.
    private(set) var isFinishing = false
    /// Bumped by every start and end, so a late "next turn" step of an old drag does nothing.
    private var generation = 0

    // A row drag
    private var rowBlob: LiquidBlob?
    private var rowSession: TerminalSession?
    private weak var source: PanelController?
    private var grab = NSPoint.zero
    private var rowSize = NSSize.zero
    private var torn = false
    private var returning = false

    // A pill drag
    private weak var draggedPill: PanelController?
    /// A dragged pill whose content is faded (near another pill or an open panel).
    private weak var fadedPill: PanelController?
    /// The open panel the dragged pill is over, showing empty slots for its sessions.
    private weak var previewed: PanelController?

    /// A row becomes a pill once its center is this far outside the panel (a row again
    /// back over it).
    static let tearMargin: CGFloat = 12
    static let rowRadius: CGFloat = 6
    /// Pills closer than this (center to center) join the overlay; farther than `leaveDistance` they leave.
    static let joinDistance: CGFloat = 120
    static let leaveDistance: CGFloat = 160
    /// A dragged pill's content is gone at this many diameters from another pill's center.
    static let contentGoneAt: CGFloat = 0.6
    /// A pill's content fades over the last this many points before an open panel's edge.
    static let panelFadeGap: CGFloat = 40
    /// The target grows by this while a drop would land in it.
    static let readyGrowth: CGFloat = 3

    init(manager: PillManager) {
        self.manager = manager
        overlay.onFrame = { [weak self] in self?.frame() }
    }

    var isActive: Bool { overlay.isActive }

    // MARK: - Lending glass

    private func blob(for pill: PanelController) -> LiquidBlob? {
        lent.first { $0.pill === pill }?.blob
    }

    /// The overlay draws `pill`'s glass: its blob first, the pill's own glass hidden on the
    /// next turn (so nothing flashes in between).
    @discardableResult
    private func lend(_ pill: PanelController) -> LiquidBlob {
        if let blob = blob(for: pill) { return blob }
        let made = LiquidBlob(rect: pill.panel.frame, radius: pill.glassRadius)
        overlay.add(made)
        lent.append((pill, made, pill.panel.level))
        pill.panel.level = NSWindow.Level(rawValue: overlay.level.rawValue + 1)
        let generation = generation
        DispatchQueue.main.async { [weak self, weak pill] in
            guard let self, generation == self.generation, let pill, blob(for: pill) != nil else { return }
            pill.lendGlass()
        }
        return made
    }

    /// The pill draws its own glass again; its blob goes on the next turn.
    private func giveBack(_ pill: PanelController) {
        guard let index = lent.firstIndex(where: { $0.pill === pill }) else { return }
        let (_, blob, level) = lent.remove(at: index)
        pill.panel.level = level
        if !pill.isRemoved { pill.takeGlassBack() }
        DispatchQueue.main.async { [weak self] in self?.overlay.remove(blob) }
    }

    private static func screen(at point: NSPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? PanelController.screen(for: NSRect(origin: point, size: NSSize(width: 1, height: 1)))
    }

    private static func onScreen(_ pill: PanelController, _ screen: NSScreen) -> Bool {
        PanelController.screenNumber(PanelController.screen(for: pill.panel.frame)) == PanelController.screenNumber(screen)
    }

    private static func distance(_ a: NSRect, _ b: NSRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    /// The gap between two rects (0 if they overlap).
    private static func gap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        hypot(max(0, a.minX - b.maxX, b.minX - a.maxX), max(0, a.minY - b.maxY, b.minY - a.maxY))
    }

    /// Whether a collapsed pill should join the overlay for a shape at `frame`, or leave it
    /// (nil: never, e.g. an open panel).
    private func closeness(of other: PanelController, to frame: NSRect) -> (join: Bool, leave: Bool)? {
        guard !other.isAnimating, other.state == .collapsed else { return nil }
        let distance = Self.distance(other.panel.frame, frame)
        return (distance < Self.joinDistance, distance > Self.leaveDistance)
    }

    /// Collapsed pills near `frame` join (their glass in the overlay); those that moved
    /// away leave. The one a drop would land in (`target`) swells a little.
    private func updateGuests(near frame: NSRect, excluding excluded: PanelController, target: PanelController?) {
        guard let screen = overlay.screen else { return }
        for pill in manager.pills where pill !== excluded && pill !== source && Self.onScreen(pill, screen) {
            guard let closeness = closeness(of: pill, to: frame) else { continue }
            if blob(for: pill) == nil, closeness.join {
                lend(pill)
                draggedPill?.panel.orderFrontRegardless()  // the dragged one above it
            } else if blob(for: pill) != nil, closeness.leave {
                giveBack(pill)
            }
        }
        for (pill, blob, _) in lent where pill !== excluded {
            let grow = pill === target ? Self.readyGrowth : 0
            blob.shape.aim(at: pill.panel.frame.insetBy(dx: -grow, dy: -grow), radius: pill.glassRadius + grow)
        }
    }

    /// The pill a drop at the mouse would join: under the mouse, or a joined one the
    /// dragged shape mostly covers.
    private func dropTarget(for shape: NSRect, excluding excluded: PanelController, expanded: Bool = false) -> PanelController? {
        if let target = manager.dropTarget(at: DragPointer.location, excluding: excluded, expanded: expanded),
           target !== source {
            return target
        }
        return lent.first { $0.pill !== excluded && $0.pill.state == .collapsed
            && Self.distance($0.pill.panel.frame, shape) < manager.pillDiameter * 0.75 }?.pill
    }

    // MARK: - Ending

    /// Every pill gets its glass back, then the overlay goes.
    private func end() {
        generation += 1
        draggedPill?.setContentAlpha(1)
        for (pill, _, level) in lent {
            pill.panel.level = level
            if !pill.isRemoved { pill.takeGlassBack() }
        }
        lent = []
        source?.setDraggedRowHidden(nil)
        rowBlob = nil
        rowSession = nil
        source = nil
        draggedPill = nil
        torn = false
        returning = false
        isFinishing = false
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.generation else { return }
            overlay.clear()
        }
    }

    /// After a drop: `step` runs every frame until it returns true, then it all ends.
    private var finish: (() -> Bool)?

    private func frame() {
        guard let finish else { return }
        if finish() {
            self.finish = nil
            end()
        }
    }

    // MARK: - A row dragged out of the sidebar

    /// `frame`: the row on screen when the drag started.
    func rowDragBegan(_ session: TerminalSession, from source: PanelController, frame: NSRect) {
        if isActive { end() }
        let mouse = DragPointer.location
        rowSession = session
        self.source = source
        grab = NSPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        rowSize = frame.size
        torn = false
        returning = false
    }

    /// Over the sidebar the row moves in the list itself, and a blob that's out springs
    /// back into it. Elsewhere the row is a glass blob above the panel: over the panel it
    /// follows the mouse as a row; outside it (past `tearMargin`) it becomes a pill under
    /// the mouse, and flows together with collapsed pills it comes near.
    func rowDragMoved(overSidebar: Bool, rowFrame: NSRect) {
        guard let source, let session = rowSession else { return }
        let mouse = DragPointer.location
        if overSidebar {
            if let rowBlob, !returning {
                returning = true
                torn = false
                rowBlob.shape.motion(stiffness: 300, damping: 0.75)
                rowBlob.shape.aim(at: rowFrame, radius: Self.rowRadius)
                for (pill, _, _) in lent { giveBack(pill) }
                finish = { [weak self] in
                    guard let self, returning, let blob = self.rowBlob, blob.shape.isSettled else { return false }
                    // Back in its row: the overlay stays (the drag goes on) but the blob goes.
                    overlay.remove(blob)
                    self.rowBlob = nil
                    returning = false
                    source.setDraggedRowHidden(nil)
                    self.finish = nil
                    return false
                }
            }
            return
        }
        let screen = Self.screen(at: mouse)
        if overlay.screen.flatMap(PanelController.screenNumber) != PanelController.screenNumber(screen) {
            moveOverlay(to: screen)
        }
        if rowBlob == nil {
            let blob = LiquidBlob(rect: rowFrame, radius: Self.rowRadius,
                                  logo: HarnessLogo.image(for: Harness(command: session.command), points: 16),
                                  tint: session.status.tint, name: session.name,
                                  pillLogo: PillView.logoSize(forDiameter: manager.pillDiameter))
            overlay.add(blob)
            rowBlob = blob
            source.setDraggedRowHidden(session)
        }
        guard let rowBlob else { return }
        if returning {
            returning = false
            finish = nil
        }
        let panel = source.panel.frame
        let wanted = NSRect(origin: NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y), size: rowSize)
        let center = NSPoint(x: wanted.midX, y: wanted.midY)
        let nearest = NSPoint(x: min(max(center.x, panel.minX), panel.maxX), y: min(max(center.y, panel.minY), panel.maxY))
        let excess = hypot(center.x - nearest.x, center.y - nearest.y)
        let diameter = manager.pillDiameter
        if excess == 0 || (!torn && excess < Self.tearMargin) {
            if torn { appLog("drag: \"\(session.name)\" back over the panel") }
            torn = false
            rowBlob.shape.motion(stiffness: 1400, damping: 0.9)
            rowBlob.shape.aim(at: wanted, radius: Self.rowRadius)
        } else {
            if !torn {
                torn = true
                appLog("drag: \"\(session.name)\" out of the panel")
                rowBlob.shape.motion(stiffness: 600, damping: 0.7)  // morphs into a pill under the mouse
            } else {
                rowBlob.shape.motion(stiffness: 900, damping: 0.85)
            }
            rowBlob.shape.aim(at: NSRect(x: mouse.x - diameter / 2, y: mouse.y - diameter / 2,
                                         width: diameter, height: diameter), radius: diameter / 2)
        }
        let target = torn ? dropTarget(for: rowBlob.shape.target, excluding: source) : nil
        if torn {
            updateGuests(near: NSRect(origin: mouse, size: .zero), excluding: source, target: target)
        } else {
            for (pill, _, _) in lent { giveBack(pill) }
        }
    }

    /// The overlay moves to the screen under the mouse, above the panel (the row floats
    /// over it); pills nearby join again from there.
    private func moveOverlay(to screen: NSScreen) {
        // At once, not next turn: the blobs' coordinates change with the window.
        for (pill, blob, level) in lent {
            pill.panel.level = level
            if !pill.isRemoved { pill.takeGlassBack() }
            overlay.remove(blob)
        }
        lent = []
        let level = source?.panel.level ?? .floating
        overlay.show(on: screen, at: NSWindow.Level(rawValue: level.rawValue + 1))
    }

    /// The drop. Returns false if the row never left the sidebar (nothing to animate).
    /// Over its panel, or not torn off yet: it springs back into its row. Over a pill: it
    /// joins that pill and flows into it. Elsewhere: a new pill, which it lands in.
    func rowDragEnded(overPanel: Bool) -> Bool {
        guard let source, let session = rowSession, let rowBlob else {
            if isActive { end() } else { rowSession = nil; self.source = nil }
            return false
        }
        isFinishing = true
        let target = torn && !overPanel ? dropTarget(for: rowBlob.shape.target, excluding: source) : nil
        if overPanel || !torn {
            appLog("drag: \"\(session.name)\" back to its row")
            rowBlob.shape.motion(stiffness: 300, damping: 0.75)
            rowBlob.shape.aim(at: source.rowScreenFrame(of: session), radius: Self.rowRadius)
            manager.saveLayout()
            finish = { rowBlob.shape.isSettled }
            return true
        }
        if let target {
            manager.move(session, from: source, to: target)
            flow(rowBlob, into: target)
        } else {
            let pill = manager.move(session, from: source, to: nil, newPillAt: DragPointer.location)
            land(rowBlob, in: pill)
        }
        source.setDraggedRowHidden(nil)
        manager.saveLayout()
        return true
    }

    /// `blob` flows into `target`'s glass, its content fading; on arrival it's gone and the
    /// target gives a small bounce.
    private func flow(_ blob: LiquidBlob, into target: PanelController) {
        let into = lend(target)
        blob.shape.motion(stiffness: 260, damping: 0.8)
        blob.shape.aim(at: target.panel.frame, radius: target.glassRadius)
        into.shape.aim(at: target.panel.frame, radius: target.glassRadius)
        var arrived = false
        finish = { [weak self] in
            guard let self else { return true }
            if !arrived {
                let left = Self.distance(blob.shape.rect, target.panel.frame)
                blob.contentAlpha = min(1, left / 40)
                guard left < 3 else { return false }
                arrived = true
                overlay.remove(blob)
                into.shape.bump(160)
                return false
            }
            return into.shape.isSettled
        }
    }

    /// `blob` lands where `pill` (new, still hidden) is, turning into it; then the pill shows.
    private func land(_ blob: LiquidBlob, in pill: PanelController?) {
        guard let pill else {
            finish = { true }
            return
        }
        pill.panel.alphaValue = 0
        blob.shape.motion(stiffness: 420, damping: 0.72)
        blob.shape.aim(at: pill.panel.frame, radius: pill.glassRadius)
        finish = {
            guard blob.shape.isSettled else { return false }
            pill.panel.alphaValue = 1  // same frame, its own glass: the blob goes next turn
            return true
        }
    }

    // MARK: - A pill dragged onto another

    /// The dragged pill and collapsed pills near it share the overlay while it's close to
    /// any. Its content (logo, usage ring, badge) fades as it nears another pill, gone by
    /// the time it's over it, or an open panel (which keeps its own glass), gone once it
    /// touches the panel's edge.
    func pillDragMoved(_ pill: PanelController) {
        guard !isFinishing else { return }
        let frame = pill.panel.frame
        let screen = PanelController.screen(for: frame)
        var alpha = manager.pills.filter { $0 !== pill && $0.state == .expanded }
            .map { Self.gap($0.panel.frame, frame) / Self.panelFadeGap }.min() ?? 1
        if !isActive {
            let near = manager.pills.contains { other in
                other !== pill && Self.onScreen(other, screen) && closeness(of: other, to: frame)?.join == true
            }
            if near {
                generation += 1
                draggedPill = pill
                overlay.show(on: screen, at: NSWindow.Level(rawValue: pill.panel.level.rawValue + 1))
                lend(pill)
            }
        } else if overlay.screen.flatMap(PanelController.screenNumber) != PanelController.screenNumber(screen) {
            end()
        }
        if isActive, let dragged = blob(for: pill) {
            // Exactly under the window, at once: its logo moves with the window, and a glass
            // that trailed it on a spring separated from it.
            dragged.shape.place(at: frame, radius: pill.glassRadius)
            overlay.redraw(dragged)
            let target = dropTarget(for: frame, excluding: pill)
            updateGuests(near: frame, excluding: pill, target: target)
            if lent.count == 1 {
                end()  // moved away from every other pill
            } else {
                let gone = manager.pillDiameter * Self.contentGoneAt
                let near = lent.filter { $0.pill !== pill }
                    .map { (Self.distance($0.pill.panel.frame, frame) - gone) / (Self.joinDistance - gone) }.min() ?? 1
                alpha = min(alpha, near)
            }
        }
        pill.setContentAlpha(max(0, min(1, alpha)))
        fadedPill = pill
        let panel = dropTarget(for: frame, excluding: pill, expanded: true).flatMap { $0.state == .expanded ? $0 : nil }
        preview(panel, for: pill)
    }

    /// The open panel under a dragged pill shows empty slots for its sessions (the sidebar
    /// sliding in if it had none); the previous one stops.
    private func preview(_ panel: PanelController?, for pill: PanelController?) {
        guard panel !== previewed else { return }
        previewed?.setDropPreview(0)
        panel?.setDropPreview(pill?.sessionCount ?? 0)
        previewed = panel
    }

    /// The drop: onto a pill or an open panel, `merge(target)` moves every session there
    /// (`PillManager.merge`). Onto a pill, the dragged glass flows into the target's. Onto a
    /// panel, what's left of the pill fades, then the merge. False if there was no target.
    func pillDropped(_ pill: PanelController, merge: @escaping (PanelController) -> Void) -> Bool {
        guard let target = dropTarget(for: pill.panel.frame, excluding: pill, expanded: true) else {
            if isActive, draggedPill === pill { end() }
            pill.setContentAlpha(1)
            preview(nil, for: nil)
            return false
        }
        fadedPill = nil
        if target.state == .collapsed {
            guard isActive, draggedPill === pill, let dragged = blob(for: pill) else {
                merge(target)  // not in the overlay (e.g. a finishing drop had it): just merge
                return true
            }
            isFinishing = true
            if let index = lent.firstIndex(where: { $0.pill === pill }) {  // the pill goes; its blob flows on
                pill.panel.level = lent.remove(at: index).level
            }
            draggedPill = nil
            merge(target)
            flow(dragged, into: target)
            return true
        }
        snap(pill, into: target, merge: merge)
        return true
    }

    /// A pill dropped onto an open panel: it becomes a glass chip with its (selected)
    /// session's logo and name, which flies from the pill into the panel's first empty
    /// slot, turning from a circle into a row; there it's replaced by the real row (the
    /// merge) and the terminal makes room for the sidebar.
    private func snap(_ pill: PanelController, into target: PanelController, merge: @escaping (PanelController) -> Void) {
        if isActive { end() }
        isFinishing = true
        if previewed !== target { preview(target, for: pill) }
        let slot = target.dropSlotFrame
        let shown = pill.allSessions[pill.selectedSessionIndex]
        overlay.show(on: PanelController.screen(for: target.panel.frame),
                     at: NSWindow.Level(rawValue: target.panel.level.rawValue + 1))
        let chip = LiquidBlob(rect: slot, radius: Self.rowRadius,
                              logo: HarnessLogo.image(for: Harness(command: shown.command), points: 16),
                              tint: shown.status.tint, name: shown.name,
                              pillLogo: PillView.logoSize(forDiameter: manager.pillDiameter))
        chip.shape.place(at: pill.panel.frame, radius: pill.glassRadius)
        overlay.add(chip)
        pill.panel.alphaValue = 0  // the chip takes its place
        chip.shape.motion(stiffness: 320, damping: 0.8)
        chip.shape.aim(at: slot, radius: Self.rowRadius)
        appLog("drag: \"\(shown.name)\" into an open panel")
        finish = { [weak self] in
            guard chip.shape.isSettled else { return false }
            self?.previewed = nil
            merge(target)  // the slot becomes the row; the chip goes with the overlay
            return true
        }
    }

    /// Poppy Dev's debug hook: `pill`'s glass held in the overlay at rest (to compare its
    /// look with the pill's own), or let go.
    func debugHold(_ pill: PanelController, _ on: Bool) {
        guard on else {
            end()
            return
        }
        generation += 1
        overlay.show(on: PanelController.screen(for: pill.panel.frame), at: NSWindow.Level(rawValue: pill.panel.level.rawValue + 1))
        lend(pill)
    }

    /// The pill drag stopped (an animation took over).
    func cancel() {
        fadedPill?.setContentAlpha(1)
        fadedPill = nil
        preview(nil, for: nil)
        guard isActive, !isFinishing else { return }
        end()
    }
}

/// Where a session or pill drag is: the mouse, or for Poppy Dev's debug hook a scripted
/// point (DESIGN §12.2), so a script can step a drag and screenshot it.
enum DragPointer {
    static var scripted: NSPoint?
    static var location: NSPoint { scripted ?? NSEvent.mouseLocation }
}
