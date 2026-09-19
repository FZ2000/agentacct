import AppKit
import SwiftUI

/// Commands are installed even when restored scene state presents no window.
/// Keep the request outside view creation so launch does not depend on an
/// already-visible view. One request per app instance preserves deliberate close.
@MainActor
final class NativeWindowLaunchRequest {
    private var scheduled = false

    func request(_ openWindow: OpenWindowAction, id: String) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openWindow(id: id)
            NSApplication.shared.unhide(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

struct NativeWindowCommands: Commands {
    let id: String
    let title: String
    let launch: NativeWindowLaunchRequest
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = launch.request(openWindow, id: id)
        CommandGroup(after: .newItem) {
            Button("Open " + title) { openWindow(id: id) }
                .buttonStyle(QuietButtonStyle())
        }
    }
}
