import SwiftUI
import AppKit

@main
struct MarginsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = Library()
    @State private var readingLog = ReadingLog()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(readingLog)
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct RootView: View {
    @State private var openBook: UUID?

    var body: some View {
        Group {
            if let id = openBook {
                ReaderView(bookID: id) { openBook = nil }
                    .id(id)
            } else {
                LibraryView { openBook = $0 }
            }
        }
    }
}
