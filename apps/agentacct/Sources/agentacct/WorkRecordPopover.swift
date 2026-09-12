import AppKit
import SwiftUI

/// One content tree keeps disclosure state while its native scroll viewport
/// grows to the content's ideal height, up to the supplied screen-height cap.
struct WorkRecordPopover<Content: View>: View {
    let width: CGFloat
    let maximumHeight: CGFloat
    private let content: Content

    init(width: CGFloat, maximumHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = max(1, width.isFinite ? width : 400)
        self.maximumHeight = max(1, maximumHeight.isFinite ? maximumHeight : 560)
        self.content = content()
    }

    var body: some View {
        RecordScrollHost(width: width, maximumHeight: maximumHeight, content: content)
            .frame(width: width)
            .background(Theme.canvas)
    }
}

private struct RecordScrollHost<Content: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    let width: CGFloat
    let maximumHeight: CGFloat
    let content: Content

    func makeNSView(context: Context) -> RecordScrollView<Content> {
        RecordScrollView(width: width, maximumHeight: maximumHeight,
            content: content, environment: environment)
    }

    func updateNSView(_ view: RecordScrollView<Content>, context: Context) {
        view.maximumHeight = maximumHeight
        view.hosting.rootView = RecordContent(width: width, content: content, environment: environment)
        view.needsLayout = true
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecordScrollView<Content>, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

private struct RecordContent<Content: View>: View {
    let width: CGFloat
    let content: Content
    let environment: EnvironmentValues

    var body: some View {
        content
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.canvas)
            .environment(\.self, environment)
    }
}

private final class RecordScrollView<Content: View>: NSScrollView {
    let hosting: RecordHostingView<RecordContent<Content>>
    var maximumHeight: CGFloat

    init(width: CGFloat, maximumHeight: CGFloat, content: Content, environment: EnvironmentValues) {
        self.maximumHeight = maximumHeight
        hosting = RecordHostingView(rootView: RecordContent(width: width, content: content, environment: environment))
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        hosting.sizingOptions = [.intrinsicContentSize]
        documentView = hosting
        hosting.onContentSizeChanged = { [weak self] in
            self?.needsLayout = true
            self?.invalidateIntrinsicContentSize()
        }
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let ideal = hosting.fittingSize
        return NSSize(width: ideal.width, height: min(maximumHeight, ideal.height))
    }

    override func layout() {
        let ideal = hosting.fittingSize
        if hosting.frame.size != ideal { hosting.setFrameSize(ideal) }
        super.layout()
    }
}

private final class RecordHostingView<Content: View>: NSHostingView<Content> {
    var onContentSizeChanged: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChanged?()
    }
}
