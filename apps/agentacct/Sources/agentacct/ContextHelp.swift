import SwiftUI

/// Supplemental explanation stays quiet until requested. Native hover help
/// and a selectable popover share the same copy; keyboard users can open it.
struct ContextHelp: View {
    let title: String
    let message: String
    var identifier: String? = nil
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle").workFont(.caption)
        }
        .buttonStyle(QuietButtonStyle(tint: Theme.muted, horizontalPadding: 5, verticalPadding: 5))
        .help(message)
        .accessibilityLabel(title)
        .accessibilityHint("Show explanation")
        .accessibilityIdentifier(identifier ?? "context-help.\(title)")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(title).workFont(.rowLabel)
                Text(message).workFont(.body).textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.l).frame(width: 340, alignment: .leading)
        }
    }
}
