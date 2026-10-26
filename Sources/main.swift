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
        app.run()
    }
}
