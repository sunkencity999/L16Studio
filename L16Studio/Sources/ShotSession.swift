import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Observation
import UniformTypeIdentifiers
import LRIKit

/// Everything needed to view one open shot: the parsed file, a renderer per
/// lens (created on demand and kept, so switching back to a lens or moving a
/// slider is fast), the fused image, and whatever is currently on screen.
@MainActor
@Observable
final class ShotSession {
    let shotID: Shot.ID
    let url: URL

    private(set) var file: LRIFile?
    private(set) var lenses: [RawImage] = []
    private(set) var image: CGImage?
    private(set) var isFullResolution = false
    private(set) var isWorking = false
    private(set) var progressText: String?
    private(set) var error: String?
    private(set) var asShotTemperature: Float?
    private(set) var asShotTint: Float?
    /// What the last fusion run did (nil until one has finished).
    private(set) var fusionReport: FusionReport?
    /// Telephoto details of the last run, when it was a full fusion.
    private(set) var teleReport: TeleFusionReport?

    /// Which merge the Fused view shows.
    enum FusionMode: String, CaseIterable, Identifiable {
        /// Lenses of the reference's focal length only, on its 13 MP grid.
        case wide
        /// Wide merge plus telephoto detail, at the shot's focal length.
        case full
        var id: String { rawValue }
    }
    /// Full fusion needs several GB of memory at 52 MP, so machines with
    /// less than 24 GB start on the wide merge; the user can still switch.
    var fusionMode: FusionMode = ProcessInfo.processInfo.physicalMemory >= 24 << 30 ? .full : .wide {
        didSet { if oldValue != fusionMode, showsFused { image = nil; scheduleRender() } }
    }
    /// True when the shot has telephoto frames to add.
    private(set) var canFuseFull = false
    /// The mode actually in effect (full needs telephoto frames).
    var effectiveFusionMode: FusionMode { canFuseFull ? fusionMode : .wide }

    var selectedLens: CameraID? {
        didSet { if oldValue != selectedLens, !showsFused { image = nil; scheduleRender() } }
    }
    /// True when the fused image, not a single lens, is on screen.
    var showsFused = false {
        didSet { if oldValue != showsFused { image = nil; scheduleRender() } }
    }
    var adjustments: RenderAdjustments {
        didSet { if oldValue != adjustments { scheduleRender() } }
    }

    @ObservationIgnored private var renderers: [CameraID: LensRenderer] = [:]
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The last fused result at full precision, kept for export.
    @ObservationIgnored private var fused: (image: CGImage, adjustments: RenderAdjustments, mode: FusionMode)?

    nonisolated static let previewDimension = 1800
    /// Fit token for the fused image (lenses use their module number).
    var fusedToken: Int { effectiveFusionMode == .full ? -2 : -1 }

    init(shot: Shot) {
        shotID = shot.id
        url = shot.url
        adjustments = shot.adjustments
    }

    var selectedImage: RawImage? { lenses.first { $0.camera == selectedLens } }

    /// The lenses a fusion would merge: colour lenses sharing the reference's focal length.
    var fusableLenses: [RawImage] {
        guard let file, let reference = file.referenceImage, reference.cfaPattern != nil else { return [] }
        return lenses.filter { $0.cfaPattern != nil && $0.camera.focalLength == reference.camera.focalLength }
    }
    var canFuse: Bool { fusableLenses.count >= 2 }

    func open() async {
        isWorking = true
        let url = url
        do {
            let file = try await Task.detached(priority: .userInitiated) {
                try LRIFile.decode(Data(contentsOf: url, options: .mappedIfSafe))
            }.value
            self.file = file
            // Wide lenses first, then telephoto; within a group by module number.
            lenses = file.images.sorted { $0.camera.rawValue < $1.camera.rawValue }
            canFuseFull = TeleFusion.canFuse(file)
            selectedLens = file.metadata.referenceCamera ?? lenses.first?.camera
        } catch {
            self.error = "Couldn't read \(url.lastPathComponent): \(error)"
            isWorking = false
        }
    }

    /// Steps through the strip: the fused image (if available) first, then each lens.
    func selectAdjacent(_ offset: Int) {
        var position: Int
        if showsFused {
            position = -1
        } else if let i = lenses.firstIndex(where: { $0.camera == selectedLens }) {
            position = i
        } else {
            return
        }
        position = min(max(position + offset, canFuse ? -1 : 0), lenses.count - 1)
        if position < 0 {
            showsFused = true
        } else {
            let lens = lenses[position].camera
            if showsFused {
                selectedLens = lens
                showsFused = false
            } else {
                selectedLens = lens
            }
        }
    }

    private func scheduleRender() {
        guard let file else { return }
        generation += 1
        renderTask?.cancel()
        error = nil
        if showsFused {
            renderFused(file: file, generation: generation)
        } else if let lens = selectedImage {
            renderLens(lens, file: file, generation: generation)
        }
    }

    /// Renders a quick preview straight away, then the full-resolution image
    /// once the user has stopped changing things.
    private func renderLens(_ lens: RawImage, file: LRIFile, generation myGeneration: Int) {
        let adjustments = adjustments
        let existing = renderers[lens.camera]
        isWorking = true
        progressText = nil

        renderTask = Task { [weak self] in
            do {
                let renderer: LensRenderer
                if let existing {
                    renderer = existing
                } else {
                    renderer = try await Task.detached(priority: .userInitiated) {
                        try LensRenderer(image: lens, file: file)
                    }.value
                    self?.renderers[lens.camera] = renderer
                }
                guard let self, self.generation == myGeneration else { return }
                self.asShotTemperature = renderer.asShotTemperature
                self.asShotTint = renderer.asShotTint

                let preview = try await Task.detached(priority: .userInitiated) {
                    try renderer.render(adjustments, maxDimension: ShotSession.previewDimension)
                }.value
                guard self.generation == myGeneration else { return }
                self.image = preview
                self.isFullResolution = false

                try await Task.sleep(for: .milliseconds(350))
                guard self.generation == myGeneration else { return }
                let full = try await Task.detached(priority: .utility) {
                    try renderer.render(adjustments, maxDimension: nil)
                }.value
                guard self.generation == myGeneration else { return }
                self.image = full
                self.isFullResolution = true
                self.isWorking = false
            } catch is CancellationError {
                // superseded by a newer render
            } catch {
                guard let self, self.generation == myGeneration else { return }
                self.error = "\(lens.camera.label): \(error)"
                self.isWorking = false
            }
        }
    }

    /// Runs the lens merge. It takes a few seconds, so it waits briefly for
    /// slider movement to stop first, and a superseded run is discarded.
    private func renderFused(file: LRIFile, generation myGeneration: Int) {
        let adjustments = adjustments
        isWorking = true
        isFullResolution = false
        progressText = "Fusing…"
        if let reference = file.referenceImage, let renderer = renderers[reference.camera] {
            asShotTemperature = renderer.asShotTemperature
            asShotTint = renderer.asShotTint
        }

        renderTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self, self.generation == myGeneration else { return }
                let mode = self.effectiveFusionMode
                let note: WideFusion.Progress = { message, _ in
                    Task { @MainActor [weak self] in
                        if self?.generation == myGeneration { self?.progressText = message }
                    }
                }
                let (float, report, tele) = try await Task.detached(priority: .userInitiated) { () -> (CGImage, FusionReport, TeleFusionReport?) in
                    switch mode {
                    case .wide:
                        let result = try WideFusion.fuse(file: file, adjustments: adjustments, progress: note)
                        return (result.image, result.report, nil)
                    case .full:
                        let result = try TeleFusion.fuse(file: file, adjustments: adjustments, progress: note)
                        return (result.image, result.report.wide, result.report)
                    }
                }.value
                let display = try await Task.detached(priority: .userInitiated) {
                    try Self.displayImage(from: float)
                }.value
                guard self.generation == myGeneration else { return }
                self.fused = (float, adjustments, mode)
                self.fusionReport = report
                self.teleReport = tele
                self.image = display
                self.isFullResolution = true
                self.isWorking = false
                self.progressText = nil
                if adjustments.isIdentity, let small = try? Self.displayImage(from: float, maxDimension: 320) {
                    Thumbnailer.shared.store(small, for: self.shotID, lens: "FUSED")
                }
            } catch is CancellationError {
                // superseded
            } catch {
                guard let self, self.generation == myGeneration else { return }
                self.error = "Fusion failed: \(error)"
                self.isWorking = false
                self.progressText = nil
            }
        }
    }

    private nonisolated static let displayContext = CIContext(options: [.cacheIntermediates: false])

    /// Converts the float fusion result to an 8-bit Display P3 image for the screen.
    private nonisolated static func displayImage(from float: CGImage, maxDimension: Int? = nil) throws -> CGImage {
        var ci = CIImage(cgImage: float)
        if let maxDimension {
            let scale = CGFloat(maxDimension) / CGFloat(max(float.width, float.height))
            if scale < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        }
        guard let out = displayContext.createCGImage(
            ci, from: ci.extent.integral, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
        ) else { throw ImageRendererError.renderFailed }
        return out
    }

    // MARK: Export

    enum ExportFormat: String, CaseIterable, Identifiable {
        case jpeg = "JPEG", heic = "HEIC", dng = "DNG", tiff = "TIFF"
        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heic: "heic"
            case .dng: "dng"
            case .tiff: "tif"
            }
        }
        var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .heic: .heic
            case .dng: UTType(filenameExtension: "dng") ?? .data
            case .tiff: .tiff
            }
        }
        /// Single lenses export as JPEG/HEIC/DNG; the fused image has no raw
        /// form, so it offers 16-bit TIFF instead of DNG.
        static let lensFormats: [ExportFormat] = [.jpeg, .heic, .dng]
        static let fusedFormats: [ExportFormat] = [.jpeg, .heic, .tiff]
    }

    /// Exports one lens. Runs off the main thread; throws on failure.
    func export(_ lens: RawImage, as format: ExportFormat, to destination: URL) async throws {
        guard let file else { return }
        let adjustments = adjustments
        let existing = renderers[lens.camera]
        try await Task.detached(priority: .userInitiated) {
            switch format {
            case .dng:
                try ImageRenderer.exportDNG(lens, from: file, to: destination)
            case .jpeg, .heic, .tiff:
                let renderer = try existing ?? LensRenderer(image: lens, file: file)
                try renderer.export(adjustments, to: destination, type: format.type)
            }
        }.value
    }

    /// Lenses that can be exported in `format` (the mono lens has no DNG path yet).
    func exportable(_ format: ExportFormat) -> [RawImage] {
        lenses.filter { format != .dng || $0.cfaPattern != nil }
    }

    /// Exports the fused image, re-running the merge if the adjustments
    /// changed since it was last computed.
    func exportFused(as format: ExportFormat, to destination: URL) async throws {
        guard let file else { return }
        let adjustments = adjustments
        let mode = effectiveFusionMode
        let cached = (fused?.adjustments == adjustments && fused?.mode == mode) ? fused?.image : nil
        try await Task.detached(priority: .userInitiated) {
            let float: CGImage
            if let cached {
                float = cached
            } else if mode == .full {
                float = try TeleFusion.fuse(file: file, adjustments: adjustments).image
            } else {
                float = try WideFusion.fuse(file: file, adjustments: adjustments).image
            }
            try Self.write(float, as: format, to: destination)
        }.value
    }

    private nonisolated static func write(_ float: CGImage, as format: ExportFormat, to url: URL) throws {
        var image = float
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if format == .tiff {
            // 16-bit Display P3: far more widely readable than a float TIFF.
            guard let space = CGColorSpace(name: CGColorSpace.displayP3),
                  let context = CGContext(
                    data: nil, width: float.width, height: float.height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { throw ImageRendererError.renderFailed }
            context.draw(float, in: CGRect(x: 0, y: 0, width: float.width, height: float.height))
            guard let converted = context.makeImage() else { throw ImageRendererError.renderFailed }
            image = converted
            properties = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ImageRendererError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageRendererError.destinationCreationFailed }
    }
}
