import SwiftUI

/// Native reading controls for the main window's content views.
/// Default typography stays unchanged; the setting persists in the real app.
enum ReadingSize {
    struct Option: Identifiable {
        let id: Int
        let title: String
        let dynamicTypeSize: DynamicTypeSize
    }
    static let options: [Option] = [
        .init(id: 0, title: "100%", dynamicTypeSize: .large),
        .init(id: 1, title: "110%", dynamicTypeSize: .xLarge),
        .init(id: 2, title: "120%", dynamicTypeSize: .xxLarge),
        .init(id: 3, title: "130%", dynamicTypeSize: .xxxLarge),
        .init(id: 4, title: "145%", dynamicTypeSize: .accessibility1),
        .init(id: 5, title: "165%", dynamicTypeSize: .accessibility2),
        .init(id: 6, title: "185%", dynamicTypeSize: .accessibility3),
        .init(id: 7, title: "205%", dynamicTypeSize: .accessibility4),
        .init(id: 8, title: "230%", dynamicTypeSize: .accessibility5),
    ]
    static func clamped(_ value: Int) -> Int { min(max(value, 0), options.count - 1) }
    static func dynamicTypeSize(_ value: Int) -> DynamicTypeSize { options[clamped(value)].dynamicTypeSize }
}

struct ReadingSizeCommands: Commands {
    @Binding var selection: Int
    var body: some Commands {
        CommandMenu("Reading") {
            Button("Larger text") { selection = ReadingSize.clamped(selection + 1) }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("+", modifiers: .command)
                .disabled(ReadingSize.clamped(selection) == ReadingSize.options.count - 1)
            Button("Smaller text") { selection = ReadingSize.clamped(selection - 1) }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("-", modifiers: .command)
                .disabled(ReadingSize.clamped(selection) == 0)
            Button("Default text size") { selection = 0 }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Picker("Window content text size", selection: Binding(
                get: { ReadingSize.clamped(selection) }, set: { selection = $0 }
            )) {
                ForEach(ReadingSize.options) { option in Text(option.title).tag(option.id) }
            }
        }
    }
}
