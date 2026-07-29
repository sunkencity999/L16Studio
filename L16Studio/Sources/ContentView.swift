import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryModel.self) private var library
    @State private var isTargeted = false

    var body: some View {
        NavigationSplitView {
            List(library.shots, selection: bindingForSelection) { shot in
                VStack(alignment: .leading, spacing: 2) {
                    Text(shot.displayName)
                        .font(.headline)
                    Text("\(shot.renderableImages.count) of \(shot.file.images.count) captures")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(shot.id)
            }
            .navigationTitle("L16 Studio")
            .toolbar {
                ToolbarItem {
                    Button {
                        library.presentOpenPanel()
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let shot = library.selectedShot {
                ShotGalleryView(shot: shot)
            } else {
                ContentUnavailableView(
                    "No Shot Selected",
                    systemImage: "photo.stack",
                    description: Text("Import a .lri file or select one from the sidebar.")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if isTargeted {
                Color.accentColor.opacity(0.15)
                    .overlay(
                        Label("Drop .lri files to import", systemImage: "square.and.arrow.down")
                            .font(.title2)
                            .padding()
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    )
                    .allowsHitTesting(false)
            }
        }
        .alert("Import Error", isPresented: errorBinding) {
            Button("OK") { library.importError = nil }
        } message: {
            Text(library.importError ?? "")
        }
    }

    private var bindingForSelection: Binding<ImportedShot.ID?> {
        Binding(get: { library.selectedShotID }, set: { library.selectedShotID = $0 })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { library.importError != nil }, set: { _ in })
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    library.importFiles(at: [url])
                }
            }
        }
    }
}
