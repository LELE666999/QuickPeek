import SwiftUI

@main
struct QuickPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("QuickPeek 正在运行")
                .frame(width: 200, height: 100)
        }
    }
}
