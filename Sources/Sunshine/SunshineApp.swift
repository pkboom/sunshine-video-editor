import AppKit
import SwiftUI

@main
struct SunshineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = EditorModel()

    var body: some Scene {
        Window("Sunshine", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 620)
                .task { model.onLaunch() }
        }
        .defaultSize(width: 1040, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open File…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                    .disabled(!model.can(.openFile))
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `swift run` launches an unbundled binary; make it a regular app before windows are created.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
