import SwiftUI
import LRIKit

struct CaptureThumbnailView: View {
    let image: RawImage
    let shot: ImportedShot

    @State private var thumbnail: CGImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)

            Text("\(image.camera)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        do {
            let rendered = try await Task.detached(priority: .userInitiated) {
                try ImageRenderer.renderThumbnail(image, from: shot.file)
            }.value
            thumbnail = rendered
        } catch {
            failed = true
        }
    }
}
