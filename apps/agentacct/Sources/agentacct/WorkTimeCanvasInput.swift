import AppKit
import SwiftUI

/// Native input for a fixed-size time canvas. Content-motion pixels are positive
/// to the right; zoom factors above one zoom in. Interactive rectangles use the
/// same top-left coordinate system as the hosted SwiftUI content.
struct WorkTimeCanvasInput<Content: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    var interactiveRegions: [CGRect]
    var allowVerticalScroll: Bool
    var onPan: (Double) -> Void
    var onZoom: (Double, Double) -> Void
    var onInteraction: (() -> Void)?
    var onEdge: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?
    var onBackgroundClick: (() -> Void)?
    var onGestureEnded: (() -> Void)?
    var onGestureCancelled: (() -> Void)?
    var accessibilityValue: String
    var accessibilityIdentifier: String
    var content: Content

    var hostedContent: WorkTimeCanvasHostedContent<Content> {
        .init(content: content, environment: environment)
    }

    init(interactiveRegions: [CGRect], allowVerticalScroll: Bool = false, onPan: @escaping (Double) -> Void,
         onZoom: @escaping (Double, Double) -> Void, onInteraction: (() -> Void)? = nil,
         onEdge: ((Bool) -> Void)? = nil, onDismiss: (() -> Void)? = nil,
         onBackgroundClick: (() -> Void)? = nil, onGestureEnded: (() -> Void)? = nil,
         onGestureCancelled: (() -> Void)? = nil, accessibilityValue: String = "",
         accessibilityIdentifier: String = "work.timeline.navigation",
         @ViewBuilder content: () -> Content) {
        self.interactiveRegions = interactiveRegions
        self.allowVerticalScroll = allowVerticalScroll
        self.onPan = onPan; self.onZoom = onZoom; self.onInteraction = onInteraction
        self.onEdge = onEdge; self.onDismiss = onDismiss
        self.onBackgroundClick = onBackgroundClick; self.onGestureEnded = onGestureEnded
        self.onGestureCancelled = onGestureCancelled
        self.accessibilityValue = accessibilityValue; self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    func makeNSView(context: Context) -> WorkTimeCanvasInputView<Content> {
        WorkTimeCanvasInputView(configuration: self)
    }

    func updateNSView(_ view: WorkTimeCanvasInputView<Content>, context: Context) {
        view.configuration = self
        view.hosting.rootView = hostedContent
        view.setAccessibilityValue(accessibilityValue)
    }
}

extension WorkTimeCanvasInput {
    /// ImageRenderer cannot draw AppKit hosts. Static fixtures draw the same
    /// SwiftUI content directly; native review and the app retain real input.
    @ViewBuilder var renderingSurface: some View {
        if SnapshotMode.enabled && !SnapshotMode.interactiveFixture {
            content
        } else {
            self
        }
    }
}

/// NSHostingView begins a new SwiftUI tree, so explicitly carry the containing
/// window's environment, including Reading size, appearance and Reduce Motion.
struct WorkTimeCanvasHostedContent<Content: View>: View {
    var content: Content
    var environment: EnvironmentValues
    var body: some View { content.environment(\.self, environment) }
}

/// Pure interpretation helpers keep device deltas, zoom direction and reserved
/// modifiers testable without posting input into the user's desktop session.
enum WorkTimeCanvasInputIntent {
    enum KeyAction: Equatable {
        case pan(Double), zoom(Double), edge(latest: Bool), dismiss
    }

    static func horizontalScroll(deltaX: Double, deltaY: Double, precise: Bool,
                                 modifiers: NSEvent.ModifierFlags,
                                 allowVertical: Bool = false,
                                 horizontalGesture: Bool? = nil) -> Double? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty,
              deltaX.isFinite, deltaY.isFinite else { return nil }
        if !modifiers.contains(.shift), !allowVertical {
            if let horizontalGesture {
                guard horizontalGesture else { return nil }
            } else if precise, abs(deltaX) < abs(deltaY) { return nil }
        }
        let delta = deltaX != 0 ? deltaX : (modifiers.contains(.shift) || allowVertical ? deltaY : 0)
        let pixels = delta * (precise ? 1 : 32)
        return pixels.isFinite && pixels != 0 ? pixels : nil
    }

    static func zoomFactor(magnification: Double) -> Double? {
        guard magnification.isFinite, magnification != 0 else { return nil }
        let factor = exp(magnification)
        return factor.isFinite && factor > 0 ? factor : nil
    }

    static func anchorFraction(x: Double, width: Double) -> Double? {
        guard x.isFinite, width.isFinite, width > 0 else { return nil }
        return min(max(x / width, 0), 1)
    }

    static func keyAction(keyCode: UInt16, characters: String,
                          modifiers: NSEvent.ModifierFlags) -> KeyAction? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch keyCode {
        case 123: return .pan(48) // Left: reveal earlier time.
        case 124: return .pan(-48)
        case 115: return .edge(latest: false)
        case 119: return .edge(latest: true)
        case 53: return .dismiss
        default:
            switch characters {
            case "+", "=": return .zoom(1.25)
            case "-": return .zoom(0.8)
            default: return nil
            }
        }
    }
}

/// The hosting child routes wheel and pinch events here even when a card is
/// under the pointer. Blank-area mouse input is handled by this parent; card
/// mouse input remains inside SwiftUI. No application-wide event monitor exists.
final class WorkTimeCanvasInputView<Content: View>: NSView {
    var configuration: WorkTimeCanvasInput<Content>
    let hosting: WorkTimeCanvasHostingView<WorkTimeCanvasHostedContent<Content>>
    private var dragStart: NSPoint?
    private var lastDragX: CGFloat = 0
    private var dragging = false
    private var magnifying = false
    private var scrollShiftAtStart: Bool?
    private var scrollHorizontalAtStart: Bool?
    private var cursorTracking: NSTrackingArea?

    init(configuration: WorkTimeCanvasInput<Content>) {
        self.configuration = configuration
        hosting = WorkTimeCanvasHostingView(rootView: configuration.hostedContent)
        super.init(frame: .zero)
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hosting.routeScroll = { [weak self] in self?.scrollWheel(with: $0) }
        hosting.routeMagnify = { [weak self] in self?.magnify(with: $0) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Time canvas")
        setAccessibilityIdentifier(configuration.accessibilityIdentifier)
        setAccessibilityValue(configuration.accessibilityValue)
        setAccessibilityHelp("Scroll horizontally through time or pinch to zoom. The viewing window also supports dragging and resizing.")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Move earlier") { [weak self] in self?.perform(.pan(48)) ?? false },
            NSAccessibilityCustomAction(name: "Move later") { [weak self] in self?.perform(.pan(-48)) ?? false },
            NSAccessibilityCustomAction(name: "Narrow viewing window") { [weak self] in self?.perform(.zoom(1.25)) ?? false },
            NSAccessibilityCustomAction(name: "Widen viewing window") { [weak self] in self?.perform(.zoom(0.8)) ?? false },
        ])
    }

    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) ?? false }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let local = convert(point, from: superview)
        return configuration.interactiveRegions.contains { $0.contains(local) } ? hit : self
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            scrollShiftAtStart = event.modifierFlags.contains(.shift)
            scrollHorizontalAtStart = nil
        }
        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        var modifiers = event.modifierFlags
        if phased, let scrollShiftAtStart {
            modifiers.remove(.shift)
            if scrollShiftAtStart { modifiers.insert(.shift) }
        }
        if phased, scrollHorizontalAtStart == nil,
           event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            scrollHorizontalAtStart = configuration.allowVerticalScroll || modifiers.contains(.shift)
                || abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
        }
        defer {
            if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended)
                || event.momentumPhase.contains(.cancelled) {
                scrollShiftAtStart = nil; scrollHorizontalAtStart = nil
            }
        }
        guard let pixels = WorkTimeCanvasInputIntent.horizontalScroll(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas, modifiers: modifiers,
            allowVertical: configuration.allowVerticalScroll,
            horizontalGesture: phased ? scrollHorizontalAtStart : nil) else {
            super.scrollWheel(with: event)
            return
        }
        configuration.onInteraction?()
        configuration.onPan(pixels)
    }

    override func magnify(with event: NSEvent) {
        if event.phase == .cancelled {
            if magnifying { configuration.onGestureCancelled?() }
            magnifying = false
            return
        }
        if let factor = WorkTimeCanvasInputIntent.zoomFactor(magnification: event.magnification),
           let anchor = WorkTimeCanvasInputIntent.anchorFraction(
            x: convert(event.locationInWindow, from: nil).x, width: bounds.width) {
            if !magnifying { configuration.onInteraction?(); magnifying = true }
            configuration.onZoom(factor, anchor)
        }
        if event.phase == .ended {
            if magnifying { configuration.onGestureEnded?() }
            magnifying = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        lastDragX = dragStart!.x
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite else { return }
        if !dragging {
            guard abs(point.x - dragStart.x) > 3 else { return }
            dragging = true
            configuration.onInteraction?()
            NSCursor.closedHand.set()
        }
        let delta = point.x - lastDragX
        lastDragX = point.x
        if delta != 0 { configuration.onPan(delta) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        let wasDragging = dragging
        dragStart = nil; dragging = false
        if wasDragging { configuration.onGestureEnded?() }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { configuration.onBackgroundClick?() }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self,
              let action = WorkTimeCanvasInputIntent.keyAction(keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags),
              perform(action) else {
            super.keyDown(with: event)
            return
        }
    }

    @discardableResult
    private func perform(_ action: WorkTimeCanvasInputIntent.KeyAction) -> Bool {
        switch action {
        case .pan(let pixels): configuration.onInteraction?(); configuration.onPan(pixels)
        case .zoom(let factor): configuration.onInteraction?(); configuration.onZoom(factor, 0.5)
        case .edge(let latest):
            guard let onEdge = configuration.onEdge else { return false }
            configuration.onInteraction?(); onEdge(latest)
        case .dismiss:
            if dragging || magnifying {
                configuration.onGestureCancelled?()
                dragStart = nil; dragging = false; magnifying = false
                NSCursor.openHand.set()
            } else if let onDismiss = configuration.onDismiss { onDismiss() }
            else { return false }
        }
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .cursorUpdate, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(area); cursorTracking = area
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { if !dragging { NSCursor.arrow.set() } }

    private func updateCursor(at point: NSPoint) {
        if dragging { NSCursor.closedHand.set() }
        else if configuration.interactiveRegions.contains(where: { $0.contains(point) }) { NSCursor.arrow.set() }
        else { NSCursor.openHand.set() }
    }
}

final class WorkTimeCanvasHostingView<Content: View>: NSHostingView<Content> {
    var routeScroll: ((NSEvent) -> Void)?
    var routeMagnify: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        if let routeScroll { routeScroll(event) } else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) {
        if let routeMagnify { routeMagnify(event) } else { super.magnify(with: event) }
    }
}
