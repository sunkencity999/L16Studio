import SwiftUI

@main
struct L16StudioApp: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
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
