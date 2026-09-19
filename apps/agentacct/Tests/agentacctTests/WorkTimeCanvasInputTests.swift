import AppKit
import SwiftUI
import XCTest
@testable import agentacct

final class WorkTimeCanvasInputTests: XCTestCase {
    func testScrollIntentResizesSpanWithBoundedFactors() throws {
        // Vertical and horizontal wheel input both resize the visible span;
        // a positive dominant delta zooms in, a negative one zooms out.
        XCTAssertEqual(try XCTUnwrap(scroll(x: 0, y: 12)), exp(12 * 0.004), accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(scroll(x: 12, y: 0)), exp(12 * 0.004), accuracy: 0.000_001)
        let zoomIn = try XCTUnwrap(scroll(x: 0, y: 50))
        let zoomOut = try XCTUnwrap(scroll(x: 0, y: -50))
        XCTAssertGreaterThan(zoomIn, 1)
        XCTAssertLessThan(zoomOut, 1)
        XCTAssertEqual(zoomIn * zoomOut, 1, accuracy: 0.000_001)
        // Per-event factors stay bounded even for a huge flick.
        XCTAssertEqual(try XCTUnwrap(scroll(x: 0, y: 10_000)), 1.33, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(scroll(x: 0, y: -10_000)), 0.75, accuracy: 0.000_001)
        // A non-precise mouse wheel uses a discrete per-line step, bounded the
        // same way once a notch exceeds the cap.
        XCTAssertEqual(try XCTUnwrap(scroll(x: 0, y: 1, precise: false)), exp(0.12), accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(scroll(x: 0, y: 3, precise: false)), 1.33, accuracy: 0.000_001)
        // Shift no longer changes what a wheel gesture means.
        XCTAssertEqual(try XCTUnwrap(scroll(x: 0, y: 3, modifiers: .shift)), exp(3 * 0.004), accuracy: 0.000_001)
    }

    func testScrollIntentRejectsSystemModifiersAndInvalidNumbers() {
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, [.control, .shift]] {
            XCTAssertNil(scroll(x: 12, y: 0, modifiers: modifiers))
        }
        XCTAssertNil(scroll(x: .infinity, y: 0))
        XCTAssertNil(scroll(x: 12, y: .nan))
        XCTAssertNil(scroll(x: 0, y: 0))
        // An extreme but finite device delta saturates at the factor bound
        // instead of overflowing to a pass-through event.
        XCTAssertEqual(scroll(x: .greatestFiniteMagnitude, y: 0, precise: false), 1.33)
    }

    func testPinchScaleAndAnchorUseBoundedFiniteValues() throws {
        let inward = try XCTUnwrap(WorkTimeCanvasInputIntent.zoomFactor(magnification: 0.2))
        let outward = try XCTUnwrap(WorkTimeCanvasInputIntent.zoomFactor(magnification: -0.2))
        XCTAssertGreaterThan(inward, 1)
        XCTAssertLessThan(outward, 1)
        XCTAssertEqual(inward * outward, 1, accuracy: 0.000_001)
        for invalid: Double in [0, .nan, .infinity, 1_000, -1_000] {
            XCTAssertNil(WorkTimeCanvasInputIntent.zoomFactor(magnification: invalid))
        }
        XCTAssertEqual(WorkTimeCanvasInputIntent.anchorFraction(x: 100, width: 400), 0.25)
        XCTAssertEqual(WorkTimeCanvasInputIntent.anchorFraction(x: -20, width: 400), 0)
        XCTAssertEqual(WorkTimeCanvasInputIntent.anchorFraction(x: 500, width: 400), 1)
        XCTAssertNil(WorkTimeCanvasInputIntent.anchorFraction(x: 1, width: 0))
        XCTAssertNil(WorkTimeCanvasInputIntent.anchorFraction(x: .nan, width: 400))
    }

    func testKeyboardIntentLeavesTextAndSystemBindingsAlone() {
        let action = WorkTimeCanvasInputIntent.keyAction
        XCTAssertEqual(action(123, "", []), .pan(48))
        XCTAssertEqual(action(124, "", []), .pan(-48))
        XCTAssertEqual(action(115, "", []), .edge(latest: false))
        XCTAssertEqual(action(119, "", []), .edge(latest: true))
        XCTAssertEqual(action(53, "", []), .dismiss)
        XCTAssertEqual(action(24, "+", .shift), .zoom(1.25))
        XCTAssertEqual(action(27, "-", []), .zoom(0.8))
        XCTAssertNil(action(123, "", .control))
        XCTAssertNil(action(24, "=", .command), "Reading shortcuts must not become time zoom")
        XCTAssertNil(action(126, "", []), "Vertical arrows remain available to the parent")
        XCTAssertNil(action(49, " ", []))
        XCTAssertNil(action(0, "a", []))
    }

    @MainActor func testHostedWheelZoomsOnceAndReservedModifiersReachParent() {
        var zooms: [(Double, Double)] = []
        var pans: [Double] = []
        let configuration = WorkTimeCanvasInput(interactiveRegions: [CGRect(x: 30, y: 20, width: 100, height: 70)],
            onPan: { pans.append($0) }, onZoom: { zooms.append(($0, $1)) }) { Text("Evidence") }
        let view = WorkTimeCanvasInputView(configuration: configuration)
        let parent = ScrollSink(frame: CGRect(x: 0, y: 0, width: 400, height: 180))
        view.frame = parent.bounds
        parent.addSubview(view)
        view.layout()

        // Wheel input over a card resizes the time window once, on either axis.
        let horizontal = CanvasEvent(x: 12, y: 0)
        view.hosting.scrollWheel(with: horizontal)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].0, exp(12 * 0.004), accuracy: 0.000_001)
        XCTAssertTrue(parent.events.isEmpty)

        // Vertical wheel over the canvas resizes the span; it no longer pans
        // or falls through to page scrolling.
        let vertical = CanvasEvent(x: 1, y: 20)
        view.hosting.scrollWheel(with: vertical)
        XCTAssertEqual(zooms.count, 2)
        XCTAssertEqual(zooms[1].0, exp(20 * 0.004), accuracy: 0.000_001)
        XCTAssertTrue(pans.isEmpty)
        XCTAssertTrue(parent.events.isEmpty)

        let reserved = CanvasEvent(x: 12, y: 0, modifiers: .control)
        view.hosting.scrollWheel(with: reserved)
        XCTAssertEqual(zooms.count, 2)
        XCTAssertEqual(parent.events.count, 1)
        XCTAssertTrue(parent.events.last === reserved)
    }

    @MainActor func testDominantScrollAxisStaysLatchedThroughMomentum() {
        var zooms: [Double] = []
        let view = WorkTimeCanvasInputView(configuration: WorkTimeCanvasInput(interactiveRegions: [],
            onPan: { _ in }, onZoom: { factor, _ in zooms.append(factor) }) { Color.clear })
        let parent = ScrollSink(frame: CGRect(x: 0, y: 0, width: 400, height: 180))
        parent.addSubview(view)
        // A vertical gesture keeps using vertical deltas when later events
        // drift horizontal, and releasing Shift during momentum changes
        // nothing: wheel direction never reinterprets mid-gesture.
        view.scrollWheel(with: CanvasEvent(x: 1, y: 10, phase: .began))
        view.scrollWheel(with: CanvasEvent(x: 8, y: 1, phase: .changed))
        view.scrollWheel(with: CanvasEvent(x: 8, y: 1, modifiers: .shift, momentum: .changed))
        XCTAssertEqual(zooms.count, 3)
        XCTAssertEqual(zooms[0], exp(10 * 0.004), accuracy: 0.000_001)
        XCTAssertEqual(zooms[1], exp(0.004), accuracy: 0.000_001)
        XCTAssertEqual(zooms[2], exp(0.004), accuracy: 0.000_001)
        XCTAssertTrue(parent.events.isEmpty)

        // The next gesture relatches its dominant axis independently.
        view.scrollWheel(with: CanvasEvent(x: 10, y: 1, phase: .began))
        view.scrollWheel(with: CanvasEvent(x: 2, y: 8, phase: .changed))
        XCTAssertEqual(zooms.count, 5)
        XCTAssertEqual(zooms[3], exp(10 * 0.004), accuracy: 0.000_001)
        XCTAssertEqual(zooms[4], exp(2 * 0.004), accuracy: 0.000_001)
    }

    @MainActor func testHostedPinchUsesPointerAnchorAndGestureCallbacks() {
        var zooms: [(Double, Double)] = []
        var interactions = 0
        var ended = 0
        var cancelled = 0
        let view = WorkTimeCanvasInputView(configuration: WorkTimeCanvasInput(interactiveRegions: [],
            onPan: { _ in }, onZoom: { zooms.append(($0, $1)) }, onInteraction: { interactions += 1 },
            onGestureEnded: { ended += 1 }, onGestureCancelled: { cancelled += 1 }) { Color.clear })
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 180)
        let pinch = CanvasEvent(phase: .changed)
        pinch.testLocation = CGPoint(x: 100, y: 50)
        pinch.testMagnification = 0.2
        view.hosting.magnify(with: pinch)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zooms[0].0, exp(0.2), accuracy: 0.000_001)
        XCTAssertEqual(zooms[0].1, 0.25)
        XCTAssertEqual(interactions, 1)
        view.hosting.magnify(with: CanvasEvent(phase: .ended))
        XCTAssertEqual(ended, 1)
        view.hosting.magnify(with: pinch)
        view.hosting.magnify(with: CanvasEvent(phase: .cancelled))
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(interactions, 2)
    }

    @MainActor func testBlankHitTestingLeavesCardsInsideSwiftUI() throws {
        // NSView.hitTest receives a point in its superview's coordinates, while
        // interactiveRegions are local, top-origin SwiftUI rectangles. Exercise
        // both parent orientations and a nonzero frame origin to prove routing.
        for topOrigin in [false, true] {
            let view = WorkTimeCanvasInputView(configuration: WorkTimeCanvasInput(
                interactiveRegions: [CGRect(x: 30, y: 20, width: 100, height: 70)],
                onPan: { _ in }, onZoom: { _, _ in }) { Button("Evidence") {} })
            let parent = HitCoordinateParent(topOrigin: topOrigin)
            view.frame = CGRect(x: 40, y: 30, width: 400, height: 180)
            parent.addSubview(view)
            view.layout()
            let blankPoint = view.convert(CGPoint(x: 300, y: 120), to: parent)
            XCTAssertTrue(view.hitTest(blankPoint) === view)
            let cardPoint = view.convert(CGPoint(x: 60, y: 40), to: parent)
            let card = try XCTUnwrap(view.hitTest(cardPoint))
            XCTAssertFalse(card === view)
            XCTAssertTrue(card === view.hosting || card.isDescendant(of: view.hosting))
            let outsidePoint = view.convert(CGPoint(x: -10, y: 40), to: parent)
            XCTAssertNil(view.hitTest(outsidePoint))
        }
    }

    @MainActor func testBlankDragReportsCumulativeTranslationForGestureScopedPans() {
        var drags: [Double] = []
        var interactions = 0
        let view = WorkTimeCanvasInputView(configuration: WorkTimeCanvasInput(interactiveRegions: [],
            onPan: { _ in }, onDrag: { drags.append($0) }, onZoom: { _, _ in }, onInteraction: { interactions += 1 },
            onBackgroundClick: {}) { Color.clear })
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 180)
        let down = CanvasEvent(); down.testLocation = CGPoint(x: 100, y: 50)
        view.mouseDown(with: down)
        let dragged = CanvasEvent(); dragged.testLocation = CGPoint(x: 110, y: 50)
        view.mouseDragged(with: dragged)
        dragged.testLocation.x = 120
        view.mouseDragged(with: dragged)
        view.mouseUp(with: dragged)
        // The translation is measured from gesture start, so the receiver can
        // resolve every event against one base window even if commits lag.
        XCTAssertEqual(drags, [10, 20])
        XCTAssertEqual(interactions, 1)
    }

    @MainActor func testClickJitterDoesNotPanButBlankDragDoes() {
        var pans: [Double] = []
        var clicks = 0
        var interactions = 0
        let view = WorkTimeCanvasInputView(configuration: WorkTimeCanvasInput(interactiveRegions: [],
            onPan: { pans.append($0) }, onZoom: { _, _ in }, onInteraction: { interactions += 1 },
            onBackgroundClick: { clicks += 1 }) { Color.clear })
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 180)
        let down = CanvasEvent(); down.testLocation = CGPoint(x: 100, y: 50)
        let jitter = CanvasEvent(); jitter.testLocation = CGPoint(x: 102, y: 50)
        view.mouseDown(with: down)
        view.mouseDragged(with: jitter)
        view.mouseUp(with: jitter)
        XCTAssertTrue(pans.isEmpty)
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(interactions, 0)
        view.mouseDown(with: down)
        let dragged = CanvasEvent(); dragged.testLocation = CGPoint(x: 110, y: 50)
        view.mouseDragged(with: dragged)
        dragged.testLocation.x = 120
        view.mouseDragged(with: dragged)
        view.mouseUp(with: dragged)
        XCTAssertEqual(pans, [10, 10])
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(interactions, 1)
    }

    @MainActor func testHostingBoundaryPreservesReadingSizeAndAppearance() {
        let observed = expectation(description: "Hosted content receives the containing environment")
        var fulfilled = false
        let outer = NSHostingView(rootView: WorkTimeCanvasInput(interactiveRegions: [],
            onPan: { _ in }, onZoom: { _, _ in }) {
                EnvironmentProbe { size, scheme in
                    if size == .accessibility5, scheme == .dark, !fulfilled {
                        fulfilled = true
                        observed.fulfill()
                    }
                }
            }
            .frame(width: 400, height: 180)
            .environment(\.dynamicTypeSize, .accessibility5)
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = outer
        defer { window.close() }
        outer.layoutSubtreeIfNeeded()
        _ = outer.fittingSize
        wait(for: [observed], timeout: 2)
    }

    private func scroll(x: Double, y: Double, precise: Bool = true,
                        modifiers: NSEvent.ModifierFlags = []) -> Double? {
        WorkTimeCanvasInputIntent.zoomScroll(deltaX: x, deltaY: y, precise: precise,
            modifiers: modifiers)
    }
}

private final class ScrollSink: NSView {
    var events: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { events.append(event) }
}

private final class HitCoordinateParent: NSView {
    var topOrigin: Bool
    init(topOrigin: Bool) {
        self.topOrigin = topOrigin
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
    }
    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { topOrigin }
}

/// These events only enter directly called test methods. They are never posted
/// to NSApplication, CGEvent, a monitor, or the user's event queue.
private final class CanvasEvent: NSEvent {
    var testLocation = NSPoint.zero
    var testMagnification: CGFloat = 0
    var testDeltaX: CGFloat
    var testDeltaY: CGFloat
    var testModifiers: NSEvent.ModifierFlags
    var testPhase: NSEvent.Phase
    var testMomentum: NSEvent.Phase

    init(x: CGFloat = 0, y: CGFloat = 0, modifiers: NSEvent.ModifierFlags = [],
         phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) {
        testDeltaX = x; testDeltaY = y; testModifiers = modifiers
        testPhase = phase; testMomentum = momentum
        super.init()
    }
    required init?(coder: NSCoder) { return nil }
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { testLocation }
    override var magnification: CGFloat { testMagnification }
    override var scrollingDeltaX: CGFloat { testDeltaX }
    override var scrollingDeltaY: CGFloat { testDeltaY }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var modifierFlags: NSEvent.ModifierFlags { testModifiers }
    override var phase: NSEvent.Phase { testPhase }
    override var momentumPhase: NSEvent.Phase { testMomentum }
}

private struct EnvironmentProbe: View {
    @Environment(\.dynamicTypeSize) private var size
    @Environment(\.colorScheme) private var scheme
    var report: (DynamicTypeSize, ColorScheme) -> Void
    var body: some View {
        report(size, scheme)
        return Color.clear
    }
}
