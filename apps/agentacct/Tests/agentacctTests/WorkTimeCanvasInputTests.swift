import AppKit
import SwiftUI
import XCTest
@testable import agentacct

final class WorkTimeCanvasInputTests: XCTestCase {
    func testScrollIntentPreservesDeviceScaleAndDirectionalScrolling() {
        XCTAssertEqual(scroll(x: 12, y: 0), 12)
        XCTAssertEqual(scroll(x: 2, y: 0, precise: false), 64)
        XCTAssertNil(scroll(x: 0, y: 12))
        XCTAssertNil(scroll(x: 1, y: 10), "Vertical trackpad jitter must not steal page scrolling")
        XCTAssertEqual(scroll(x: 10, y: 1), 10)
        XCTAssertEqual(scroll(x: 0, y: 3, modifiers: .shift), 3)
        XCTAssertEqual(scroll(x: 2, y: 10, modifiers: .shift), 2, "A supplied horizontal delta is not counted twice")
        XCTAssertNil(scroll(x: 0, y: 3, precise: false))
        XCTAssertEqual(scroll(x: 0, y: 3, precise: false, allowVertical: true), 96)
    }

    func testScrollIntentRejectsSystemModifiersAndInvalidNumbers() {
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, [.control, .shift]] {
            XCTAssertNil(scroll(x: 12, y: 0, modifiers: modifiers))
        }
        XCTAssertNil(scroll(x: .infinity, y: 0))
        XCTAssertNil(scroll(x: 12, y: .nan))
        XCTAssertNil(scroll(x: 0, y: 0))
        XCTAssertNil(scroll(x: .greatestFiniteMagnitude, y: 0, precise: false))
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

    @MainActor func testHostedCardWheelRoutesOnceAndVerticalWheelReachesParent() {
        var pans: [Double] = []
        let configuration = WorkTimeCanvasInput(interactiveRegions: [CGRect(x: 30, y: 20, width: 100, height: 70)],
            onPan: { pans.append($0) }, onZoom: { _, _ in }) { Text("Evidence") }
        let view = WorkTimeCanvasInputView(configuration: configuration)
        let parent = ScrollSink(frame: CGRect(x: 0, y: 0, width: 400, height: 180))
        view.frame = parent.bounds
        parent.addSubview(view)
        view.layout()

        let horizontal = CanvasEvent(x: 12, y: 0)
        view.hosting.scrollWheel(with: horizontal)
        XCTAssertEqual(pans, [12])
        XCTAssertTrue(parent.events.isEmpty)

        let vertical = CanvasEvent(x: 1, y: 20)
        view.hosting.scrollWheel(with: vertical)
        XCTAssertEqual(pans, [12])
        XCTAssertEqual(parent.events.count, 1)
        XCTAssertTrue(parent.events.first === vertical)

        let reserved = CanvasEvent(x: 12, y: 0, modifiers: .control)
        view.hosting.scrollWheel(with: reserved)
        XCTAssertEqual(pans, [12])
        XCTAssertEqual(parent.events.count, 2)
        XCTAssertTrue(parent.events.last === reserved)
    }

    @MainActor func testScrollDirectionAndShiftStayLatchedThroughMomentum() {
        var pans: [Double] = []
        let view = WorkTimeCanvasInputView(configuration: WorkTimeCanvasInput(interactiveRegions: [],
            onPan: { pans.append($0) }, onZoom: { _, _ in }) { Color.clear })
        let parent = ScrollSink(frame: CGRect(x: 0, y: 0, width: 400, height: 180))
        parent.addSubview(view)
        view.scrollWheel(with: CanvasEvent(x: 1, y: 10, phase: .began))
        view.scrollWheel(with: CanvasEvent(x: 8, y: 1, phase: .changed))
        view.scrollWheel(with: CanvasEvent(x: 8, y: 1, modifiers: .shift, momentum: .changed))
        XCTAssertTrue(pans.isEmpty, "A vertical gesture must not turn into time pan during its tail")
        XCTAssertEqual(parent.events.count, 3)

        view.scrollWheel(with: CanvasEvent(x: 10, y: 1, phase: .began))
        view.scrollWheel(with: CanvasEvent(x: 2, y: 8, phase: .changed))
        XCTAssertEqual(pans, [10, 2], "Horizontal gesture ownership survives small axis changes")

        view.scrollWheel(with: CanvasEvent(x: 0, y: 4, modifiers: .shift, phase: .began))
        view.scrollWheel(with: CanvasEvent(x: 0, y: 3, momentum: .changed))
        XCTAssertEqual(pans, [10, 2, 4, 3], "Releasing Shift during momentum does not change the operation")
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
                        modifiers: NSEvent.ModifierFlags = [], allowVertical: Bool = false) -> Double? {
        WorkTimeCanvasInputIntent.horizontalScroll(deltaX: x, deltaY: y, precise: precise,
            modifiers: modifiers, allowVertical: allowVertical)
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
