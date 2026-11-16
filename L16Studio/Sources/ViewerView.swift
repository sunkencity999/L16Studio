import SwiftUI
import AppKit
import LRIKit

/// The single-shot view: one lens large on a dark canvas, with a filmstrip of
/// every lens in the shot underneath.
struct ViewerView: View {
    @Environment(AppModel.self) private var model
    let session: ShotSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            canvas
            Divider().overlay(Theme.hairline)
            LensStrip(session: session)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { model.closeViewer() } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            Text(session.url.deletingPathExtension().lastPathComponent)
                .font(.headline)
            if session.showsFused {
                let lenses = session.fusableLenses
                Text("Fused  ·  \(lenses.count) lenses  ·  \(lenses.first?.camera.focalLength ?? 0) mm")
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
            } else if let lens = session.selectedImage {
                Text("\(lens.camera.label)  ·  \(lens.camera.focalLength) mm\(lens.sensor == .ar1335Mono ? "  ·  mono" : "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isWorking {
                ProgressView().controlSize(.small)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.panel)
    }

    private var statusText: String {
        if let progress = session.progressText { return progress }
        if session.image == nil { return "" }
        if session.showsFused { return "Fused" }
        return session.isFullResolution ? "Full resolution" : "Preview"
    }

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            Theme.canvas
            if let error = session.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(40)
            } else if let image = session.image, let lens = session.selectedImage {
                ZoomableImageView(
                    image: image,
                    nominalSize: CGSize(width: lens.width, height: lens.height),
                    fitToken: session.showsFused ? ShotSession.fusedToken : lens.camera.rawValue
                )
            } else {
                ProgressView(session.showsFused ? (session.progressText ?? "Fusing…") : "Developing…")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Thumbnails of every lens in the shot, grouped by focal length.
struct LensStrip: View {
    @Environment(AppModel.self) private var model
    let session: ShotSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 8) {
                if session.canFuse {
                    FusedTile(
                        shot: model.library.shot(session.shotID),
                        isSelected: session.showsFused,
                        version: session.fusionReport?.seconds
                    )
                        .onTapGesture { session.showsFused = true }
                    Divider().frame(height: 70).overlay(Theme.hairline)
                }
                ForEach(session.lenses, id: \.camera) { lens in
                    LensTile(
                        shot: model.library.shot(session.shotID),
                        lens: lens,
                        isSelected: !session.showsFused && lens.camera == session.selectedLens
                    )
                    .onTapGesture {
                        session.selectedLens = lens.camera
                        session.showsFused = false
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(height: 112)
        .background(Theme.panel)
    }
}

struct LensTile: View {
    let shot: Shot?
    let lens: RawImage
    let isSelected: Bool
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(Theme.tile)
                .frame(width: 96, height: 72)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 1)
                }
            Text("\(lens.camera.label) · \(lens.camera.focalLength)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isSelected ? Theme.accent : .secondary)
        }
        .contentShape(Rectangle())
        .task(id: lens.camera) {
            guard let shot else { return }
            thumbnail = await Thumbnailer.shared.thumbnail(for: shot, lens: lens.camera.label, maxDimension: 320)
        }
    }
}

/// The strip's entry for the merged image.
struct FusedTile: View {
    let shot: Shot?
    let isSelected: Bool
    /// Changes when a fusion run finishes, so the thumbnail reloads.
    let version: Double?
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(Theme.tile)
                .frame(width: 96, height: 72)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 1)
                }
            Text("Fused")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? Theme.accent : .secondary)
        }
        .contentShape(Rectangle())
        .task(id: version) {
            guard let shot else { return }
            // The merged preview is written just after the run finishes.
            if version != nil { try? await Task.sleep(for: .milliseconds(400)) }
            if let image = await Thumbnailer.shared.cached(for: shot, lens: "FUSED") { thumbnail = image }
        }
    }
}

/// An image in a native scroll view: pinch or scroll to zoom, drag to pan,
/// double-click to switch between fit and 100%.
struct ZoomableImageView: NSViewRepresentable {
    let image: CGImage
    /// The full-resolution pixel size. The document is always laid out at
    /// this size so swapping a preview for the full render doesn't jump.
    let nominalSize: CGSize
    /// Changing this refits the image to the window (a different lens or shot).
    let fitToken: Int

    final class Coordinator: NSObject {
        var fitToken: Int?
        weak var scrollView: NSScrollView?

        @objc func toggleZoom(_ recognizer: NSClickGestureRecognizer) {
            guard let scrollView, let document = scrollView.documentView else { return }
            if abs(scrollView.magnification - 1) < 0.01 {
                scrollView.animator().magnify(toFit: document.frame)
            } else {
                let point = recognizer.location(in: document)
                scrollView.animator().setMagnification(1, centeredAt: point)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 12

        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        scrollView.documentView = imageView

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        // Lay the document out in points so 100% zoom is one image pixel per screen pixel.
        let scale = scrollView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // A rotated shot swaps the nominal sides; trust the rendered image's aspect.
        let landscape = image.width >= image.height
        let longSide = max(nominalSize.width, nominalSize.height)
        let shortSide = min(nominalSize.width, nominalSize.height)
        let size = CGSize(width: (landscape ? longSide : shortSide) / scale, height: (landscape ? shortSide : longSide) / scale)

        imageView.image = NSImage(cgImage: image, size: size)
        if imageView.frame.size != size { imageView.setFrameSize(size) }

        if context.coordinator.fitToken != fitToken {
            context.coordinator.fitToken = fitToken
            DispatchQueue.main.async {
                scrollView.magnify(toFit: imageView.frame)
            }
        }
    }
}

/// Keeps the document centred when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}
