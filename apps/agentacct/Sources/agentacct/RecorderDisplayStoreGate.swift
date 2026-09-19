import Foundation

enum RecorderDisplayStoreGate {
    static func explanation(display: URL?, managedPath: String?) -> String? {
        guard let display, let managedPath, !managedPath.isEmpty else {
            return "The displayed store and the app-owned recorder store could not both be identified. Resolve the store configuration before reconnecting."
        }
        let managed = URL(fileURLWithPath: managedPath).standardizedFileURL.resolvingSymlinksInPath()
        let shown = display.standardizedFileURL.resolvingSymlinksInPath()
        guard managed == shown else {
            return "This window displays \(shown.path). The app manages a different recorder at \(managed.path). Start or repair the displayed development recorder separately, or reopen the app with its normal store selection."
        }
        return nil
    }
}
