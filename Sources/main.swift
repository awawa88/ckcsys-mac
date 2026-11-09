import Cocoa
import InputMethodKit

private var gServer: IMKServer?

@main
struct CKCApp {
    static func main() {
        let app = NSApplication.shared
        let bundleID = Bundle.main.bundleIdentifier ?? "com.andrewlam.inputmethod.ckc"
        let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
            ?? "\(bundleID)_Connection"
        gServer = IMKServer(name: connectionName, bundleIdentifier: bundleID)
        NSLog("[CKC] IMKServer started connection=%@ bundle=%@", connectionName, bundleID)
        DictionaryStore.shared.load()
        // IMK/LSUIElement often ignores system light/dark — pin NSApp to the saved 暗/亮 choice
        // before any floating chrome is created.
        if let raw = UserDefaults.standard.string(forKey: IMEAppearance.defaultsKey),
           let saved = IMEAppearance(rawValue: raw) {
            IMEAppearance.applyToApp(saved)
        } else {
            IMEAppearance.applyToApp(.dark)
        }
        app.run()
    }
}
