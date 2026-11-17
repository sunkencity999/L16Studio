import SwiftUI
import AppKit
import LRIKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                if let session = model.session {
                    ViewerView(session: session)
                } else {
                    LibraryGridView()
                }
            }
            .background(Theme.canvas)
            .inspector(isPresented: $model.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 250, ideal: 280, max: 340)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.importFromDisk() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import .lri files from disk")
                Button { model.showCameraImport = true } label: {
                    Label("Camera", systemImage: "camera")
                }
                .help("Import from a connected L16")
                Button { model.showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector")
            }
        }
        .sheet(isPresented: $model.showCameraImport) {
            CameraImportView()
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleOpened(urls)
            return true
        }
        // Files can change behind the app's back (a drive mounted, a shot
        // moved or restored in Finder), so look again when it comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.library.filesMayHaveChanged()
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { model.library.lastError = nil }
        } message: {
            Text(model.library.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.library.lastError != nil }, set: { if !$0 { model.library.lastError = nil } })
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var library = model.library
        // Reading the revision makes the counts below (which look at the
        // disk) refresh whenever files may have changed.
        let _ = library.filesRevision
        List(selection: filterBinding) {
            Section("Library") {
                row("All Shots", "photo.on.rectangle.angled", .all)
                row("Flagged", "flag.fill", .flagged)
                row("3 Stars and Up", "star.fill", .rated)
                if library.count(for: .missing) > 0 {
                    row("Missing Files", "exclamationmark.triangle", .missing)
                }
            }
            Section("Camera") {
                Button { model.showCameraImport = true } label: {
                    Label("Import from L16…", systemImage: "cable.connector")
                }
                .buttonStyle(.plain)
                Button { model.takePicture() } label: {
                    Label(model.isCapturing ? "Taking a picture…" : "Take a Picture", systemImage: "camera.shutter.button")
                }
                .buttonStyle(.plain)
                .disabled(model.isCapturing)
                .help("Fire a camera connected by cable and open the shot here (needs USB debugging on the camera)")
                AutoSyncRow(sync: model.autoSync)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let status = library.importStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
    }

    private var filterBinding: Binding<LibraryFilter?> {
        Binding(
            get: { model.library.filter },
            set: { newValue in
                if let newValue { model.library.filter = newValue }
                model.closeViewer()
            }
        )
    }

    private func row(_ title: String, _ symbol: String, _ filter: LibraryFilter) -> some View {
        Label(title, systemImage: symbol)
            .badge(model.library.count(for: filter))
            .tag(filter)
    }
}

/// The switch for automatic import over Wi-Fi, with what it is doing.
struct AutoSyncRow: View {
    @Bindable var sync: AutoSync

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $sync.isEnabled) {
                Label("Auto-import over Wi-Fi", systemImage: "wifi")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if sync.isEnabled, !sync.status.isEmpty {
                HStack(spacing: 6) {
                    if sync.isBusy { ProgressView().controlSize(.mini) }
                    Text(sync.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help("While this is on, shots you take arrive in the library by themselves whenever the camera has Wi-Fi transfer switched on and is on this network.")
    }
}
