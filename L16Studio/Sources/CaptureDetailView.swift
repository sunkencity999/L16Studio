import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LRIKit

struct CaptureDetailView: View {
    let image: RawImage
    let shot: ImportedShot

    @Environment(\.dismiss) private var dismiss
    @State private var rendered: CGImage?
    @State private var isRendering = true
    @State private var exportError: String?
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color.black.opacity(0.02)
                if let rendered {
                    Image(decorative: rendered, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else if isRendering {
                    ProgressView("Debayering full resolution...")
                }
            }
            .frame(minWidth: 700, minHeight: 500)
        }
        .task { await renderFullSize() }
        .alert("Export Error", isPresented: errorBinding) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(image.camera)")
                    .font(.headline.monospaced())
                Text("\(image.width)\u{00d7}\(image.height) \u{00b7} \(String(describing: image.sensor))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            exportMenu
            Button("Done") { dismiss() }
        }
        .padding()
    }

    private var exportMenu: some View {
        Menu {
            Button("Save as DNG...") { export(.dng) }
            Button("Save as JPEG...") { export(.jpeg) }
            Button("Save as HEIC...") { export(.heic) }
        } label: {
            if isExporting {
                ProgressView().controlSize(.small)
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(isExporting || rendered == nil)
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { _ in })
    }

    private enum ExportFormat {
        case dng, jpeg, heic

        var fileExtension: String {
            switch self {
            case .dng: "dng"
            case .jpeg: "jpg"
            case .heic: "heic"
            }
        }

        var contentType: UTType {
            switch self {
            case .dng: .init(filenameExtension: "dng") ?? .data
            case .jpeg: .jpeg
            case .heic: .heic
            }
        }
    }

    private func renderFullSize() async {
        do {
            let cg = try await Task.detached(priority: .userInitiated) {
                try ImageRenderer.render(image, from: shot.file)
            }.value
            rendered = cg
            isRendering = false
        } catch {
            isRendering = false
            exportError = "Couldn't render this capture: \(error)"
        }
    }

    private func export(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(shot.displayName)_\(image.camera).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    switch format {
                    case .dng: try ImageRenderer.exportDNG(image, from: shot.file, to: url)
                    case .jpeg: try ImageRenderer.exportJPEG(image, from: shot.file, to: url)
                    case .heic: try ImageRenderer.exportHEIC(image, from: shot.file, to: url)
                    }
                }.value
            } catch {
                exportError = "Export failed: \(error)"
            }
        }
    }
}
