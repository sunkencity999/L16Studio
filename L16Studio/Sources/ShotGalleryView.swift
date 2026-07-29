import SwiftUI
import LRIKit

/// Wraps a `RawImage` with a stable identity for SwiftUI's `sheet(item:)` --
/// `RawImage.camera` alone isn't unique within a shot (an HDR burst repeats
/// the same camera IDs once per bracketed exposure), so we can't rely on it
/// for identity here.
struct SelectedCapture: Identifiable {
    let id = UUID()
    let image: RawImage
}

struct ShotGalleryView: View {
    let shot: ImportedShot
    @State private var selectedCapture: SelectedCapture?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataHeader
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(shot.renderableImages.enumerated()), id: \.offset) { _, image in
                        CaptureThumbnailView(image: image, shot: shot)
                            .onTapGesture { selectedCapture = SelectedCapture(image: image) }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(shot.displayName)
        .sheet(item: $selectedCapture) { capture in
            CaptureDetailView(image: capture.image, shot: shot)
        }
    }

    private var metadataHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shot.displayName)
                .font(.title2.bold())
            HStack(spacing: 12) {
                if let focalLength = shot.file.metadata.focalLength {
                    Label("\(focalLength)mm", systemImage: "camera.aperture")
                }
                if let hdr = shot.file.metadata.hdrMode {
                    Label("HDR: \(String(describing: hdr))", systemImage: "sun.max")
                }
                if let scene = shot.file.metadata.sceneMode {
                    Label("\(String(describing: scene))", systemImage: "photo")
                }
                Label("\(shot.renderableImages.count) lenses", systemImage: "camera.macro")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
}
