import SwiftUI
import AppKit
import Observation
import LRIKit

/// App-wide state: the library, and the shot currently open in the viewer.
@MainActor
@Observable
final class AppModel {
    let library = LibraryStore()
    @ObservationIgnored private(set) lazy var autoSync = AutoSync(library: library)
    private(set) var session: ShotSession?
    var showInspector = true
    var showCameraImport = false

    func open(_ shot: Shot) {
        guard shot.exists else {
            library.lastError = "\(shot.url.lastPathComponent) is no longer at \(shot.url.deletingLastPathComponent().path)."
            return
        }
        let session = ShotSession(shot: shot)
        self.session = session
        Task { await session.open() }
    }

    /// Returns to the library, saving any adjustments made in the viewer.
    func closeViewer() {
        guard let session else { return }
        let id = session.shotID
        let adjustments = session.adjustments
        if library.shot(id)?.adjustments != adjustments {
            library.update(id) { $0.adjustments = adjustments }
            Thumbnailer.shared.discard(id)
        }
        self.session = nil
    }

    func importFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [L16FileType.lri, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose .lri files, or a folder of them"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await library.importFiles(urls) }
    }

    func handleOpened(_ urls: [URL]) {
        Task {
            let added = await library.importFiles(urls)
            if urls.count == 1, let shot = added.first ?? library.shots.first(where: { $0.path == urls[0].path }) {
                open(shot)
            }
        }
    }
}

/// Receives files opened from Finder, the Dock or `open -a`. Handling this
/// in an app delegate (not `onOpenURL`) keeps SwiftUI creating its window
/// normally when the app is launched *by* opening a file.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    @MainActor static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            if let model = AppDelegate.model {
                model.handleOpened(urls)
            } else {
                AppDelegate.pending += urls
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct L16StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    init() {
        // Needed when launched as a bare executable (`swift run`); harmless in the bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // A single-window scene: opening a file must never spawn a second window.
        Window("L16 Studio", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear {
                    AppDelegate.model = model
                    if !AppDelegate.pending.isEmpty {
                        model.handleOpened(AppDelegate.pending)
                        AppDelegate.pending = []
                    }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import…") { model.importFromDisk() }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Import from Camera…") { model.showCameraImport = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu("Shot") {
                Button("Back to Library") { model.closeViewer() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.session == nil)
                Divider()
                Button("Previous Lens") { model.session?.selectAdjacent(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(model.session == nil)
                Button("Next Lens") { model.session?.selectAdjacent(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(model.session == nil)
                Divider()
                Button("Toggle Inspector") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

enum Theme {
    static let accent = Color(red: 1.0, green: 0.70, blue: 0.22)
    static let canvas = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let panel = Color(red: 0.105, green: 0.105, blue: 0.115)
    static let tile = Color(red: 0.14, green: 0.14, blue: 0.155)
    static let hairline = Color.white.opacity(0.08)
}
