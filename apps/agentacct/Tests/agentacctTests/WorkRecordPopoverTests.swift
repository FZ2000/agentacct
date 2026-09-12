import AppKit
import SwiftUI
import XCTest
@testable import agentacct

@MainActor
final class WorkRecordPopoverTests: XCTestCase {
    func testShortContentUsesItsNaturalHeightOnFirstMeasurement() {
        let content = Text("Recorded check passed").font(.system(size: 14)).padding(16)
        let natural = NSHostingView(rootView: content.frame(width: 400).fixedSize(horizontal: false, vertical: true)).fittingSize
        let host = NSHostingView(rootView: WorkRecordPopover(width: 400, maximumHeight: 420) { content })

        let first = host.fittingSize
        XCTAssertEqual(first.width, 400, accuracy: 0.5)
        XCTAssertEqual(first.height, natural.height, accuracy: 0.5)
        XCTAssertLessThan(first.height, 100)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, first.height, accuracy: 0.5, "No measured-height jump after initial layout")
    }

    func testLongContentCapsViewportButRetainsScrollableDocument() throws {
        let host = NSHostingView(rootView: WorkRecordPopover(width: 400, maximumHeight: 240) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<40) { Text("Recorded detail \($0)").font(.system(size: 14)) }
            }.padding(16)
        })
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.fittingSize.height, 240, accuracy: 0.5)
        let scroll = try XCTUnwrap(scrollView(in: host))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, 600)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertFalse(scroll.drawsBackground, "The enclosing Theme.canvas supplies one consistent surface")
    }

    func testReadingSizeAndEnvironmentReachTheNestedContent() {
        let selection = AppSelection()
        var receivedEnvironment = false
        let normal = NSHostingView(rootView: WorkRecordPopover(width: 300, maximumHeight: 420) {
            EnvironmentContent().padding(16)
        }.environment(selection).environment(\.dynamicTypeSize, .medium).environment(\.colorScheme, .dark))
        let enlarged = NSHostingView(rootView: WorkRecordPopover(width: 300, maximumHeight: 420) {
            EnvironmentContent { size, scheme, inheritedSelection in
                if size == .accessibility5, scheme == .dark, inheritedSelection === selection {
                    receivedEnvironment = true
                }
            }.padding(16)
        }.environment(selection).environment(\.dynamicTypeSize, .accessibility5).environment(\.colorScheme, .dark))

        XCTAssertGreaterThan(enlarged.fittingSize.height, normal.fittingSize.height)
        XCTAssertLessThanOrEqual(enlarged.fittingSize.height, 420)
        XCTAssertTrue(receivedEnvironment, "The native host must retain reading size, appearance, and environment object identity")
    }

    func testDisclosureExpansionChangesHeightAndKeepsOneContentTree() throws {
        let expansion = Expansion()
        let host = NSHostingView(rootView: WorkRecordPopover(width: 400, maximumHeight: 240) {
            ExpandableContent(expansion: expansion).padding(16)
        })
        let collapsed = host.fittingSize.height
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let originalDocument = try XCTUnwrap(scrollView(in: host)?.documentView)

        expansion.expanded = true
        settle(host)
        XCTAssertTrue(expansion.expanded)
        XCTAssertEqual(host.fittingSize.height, 240, accuracy: 0.5)
        XCTAssertTrue(scrollView(in: host)?.documentView === originalDocument)

        expansion.expanded = false
        settle(host)
        XCTAssertEqual(host.fittingSize.height, collapsed, accuracy: 0.5)
        XCTAssertTrue(scrollView(in: host)?.documentView === originalDocument)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private struct EnvironmentContent: View {
        @Environment(\.colorScheme) private var scheme
        @Environment(\.dynamicTypeSize) private var readingSize
        @Environment(AppSelection.self) private var selection
        var onRead: ((DynamicTypeSize, ColorScheme, AppSelection) -> Void)? = nil
        var body: some View {
            let _ = onRead?(readingSize, scheme, selection)
            Text(scheme == .dark ? "A recorded result with enough context to wrap naturally at larger reading sizes." : "Wrong environment")
                .workFont(.body)
        }
    }

    @Observable final class Expansion {
        var expanded = false
    }

    private struct ExpandableContent: View {
        @Bindable var expansion: Expansion
        var body: some View {
            DisclosureGroup("Record details", isExpanded: $expansion.expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<40) { Text("Source identity \($0)") }
                }
            }
        }
    }
}
