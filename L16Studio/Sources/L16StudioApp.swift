import SwiftUI

@main
struct L16StudioApp: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .onOpenURL { url in
                    // Handles both Finder (double-click/"Open With") and the
                    // CLI launcher (`l16studio path/to/file.lri`) -- both
                    // arrive via the same Apple Event mechanism.
                    library.importFiles(at: [url])
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    library.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
