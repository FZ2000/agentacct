import AppKit

/// View geometry only. A held snapshot and its filters remain the evidence
/// authority; these offsets restore the user's reading position within it.
struct WorkTimelineScrollOffset: Equatable, Codable {
    var x: Double
    var y: Double

    func clamped(document: CGSize, viewport: CGSize) -> CGPoint {
        CGPoint(x: x.isFinite ? min(max(x, 0), max(document.width - viewport.width, 0)) : 0,
                y: y.isFinite ? min(max(y, 0), max(document.height - viewport.height, 0)) : 0)
    }
}

@MainActor
final class WorkTimelineViewport {
    weak var anchor: NSView?

    private var scrollViews: [NSScrollView] {
        var views: [NSScrollView] = []
        var current = anchor?.superview
        while let view = current {
            if let scroll = view as? NSScrollView { views.append(scroll) }
            current = view.superview
        }
        return views
    }

    func capture() -> [WorkTimelineScrollOffset]? {
        let views = scrollViews
        guard !views.isEmpty else { return nil }
        return views.map { .init(x: $0.contentView.bounds.minX, y: $0.contentView.bounds.minY) }
    }

    /// Inner list, horizontal timeline and outer Work scroll positions are
    /// restored together. A different hierarchy uses the record-ID fallback.
    @discardableResult
    func restore(_ offsets: [WorkTimelineScrollOffset]) -> Bool {
        let views = scrollViews
        guard !views.isEmpty, views.count == offsets.count,
              views.allSatisfy({ $0.documentView != nil }) else { return false }
        for (view, offset) in zip(views, offsets).reversed() {
            view.contentView.scroll(to: offset.clamped(document: view.documentView!.bounds.size, viewport: view.contentView.bounds.size))
            view.reflectScrolledClipView(view.contentView)
        }
        return true
    }
}
