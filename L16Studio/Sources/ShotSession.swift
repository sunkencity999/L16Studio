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
    /// Bumped whenever a lens thumbnail has been written to the cache.
    private(set) var thumbnailVersion = 0
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
        /// A black-and-white picture built on the monochrome lens.
        case mono
        var id: String { rawValue }
    }
    /// Full fusion needs several GB of memory at 52 MP, so machines with
    /// less than 24 GB start on the wide merge; the user can still switch.
    var fusionMode: FusionMode = ProcessInfo.processInfo.physicalMemory >= 24 << 30 ? .full : .wide {
        didSet { if oldValue != fusionMode, showsFused { image = nil; scheduleRender() } }
    }
    /// True when the shot has telephoto frames to add.
    private(set) var canFuseFull = false
    /// True when the shot has a frame from the monochrome lens.
    private(set) var canFuseMono = false
    /// Distances measured during the last merge, when the file allows it.
    private(set) var depth: DepthMap?
    /// Background blur works on the merges made on a single lens's grid.
    var canRefocus: Bool { depth != nil && effectiveFusionMode != .full }

    /// Moves the point that stays sharp (fractions of the picture's size).
    func setFocus(x: Double, y: Double) {
        guard showsFused, canRefocus, var refocus = adjustments.refocus else { return }
        refocus.focusX = min(1, max(0, x))
        refocus.focusY = min(1, max(0, y))
        adjustments.refocus = refocus
    }
    /// The mode actually in effect (full needs telephoto frames).
    var effectiveFusionMode: FusionMode {
        switch fusionMode {
        case .wide: .wide
        case .full: canFuseFull ? .full : .wide
        case .mono: canFuseMono ? .mono : .wide
        }
    }

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
    /// The last merge at full precision, before any look is applied. Kept so
    /// that changing the look, or exporting, doesn't re-run the merge.
    @ObservationIgnored private var fused: (image: CGImage, adjustments: RenderAdjustments, mode: FusionMode)?

    nonisolated static let previewDimension = 1800
    /// Fit token for the fused image (lenses use their module number).
    var fusedToken: Int {
        switch effectiveFusionMode {
        case .wide: -1
        case .full: -2
        case .mono: -3
        }
    }

    init(shot: Shot) {
        shotID = shot.id
        url = shot.url
        adjustments = shot.adjustments
    }

    var selectedImage: RawImage? { lenses.first { $0.camera == selectedLens } }

    /// The lenses the wide merge combines: everything sharing the reference's
    /// focal length (the mono lens adds luminance detail).
    var fusableLenses: [RawImage] {
        guard let file, let reference = file.referenceImage, reference.cfaPattern != nil else { return [] }
        return lenses.filter {
            $0.camera.focalLength == reference.camera.focalLength && ($0.cfaPattern != nil || $0.sensor == .ar1335Mono)
        }
    }
    /// A merge needs the reference plus at least one other colour lens.
    var canFuse: Bool { fusableLenses.filter { $0.cfaPattern != nil }.count >= 2 }

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
            canFuseMono = WideFusion.hasMonochromeLens(file)
            selectedLens = file.metadata.referenceCamera ?? lenses.first?.camera
            buildLensThumbnails(file: file)
        } catch {
            self.error = "Couldn't read \(url.lastPathComponent): \(error)"
            isWorking = false
        }
    }

    /// Fills the lens strip. The file is already parsed here, so each
    /// thumbnail costs one small render; asking the shared thumbnailer
    /// instead would re-read and re-parse the whole file once per lens.
    private func buildLensThumbnails(file: LRIFile) {
        let shot = Shot(id: shotID, path: url.path, capturedAt: Date(), fileSize: 0)
        let adjustments = adjustments
        let lenses = lenses
        Task(priority: .utility) { [weak self] in
            for lens in lenses {
                guard let self else { return }
                if await Thumbnailer.shared.cached(for: shot, lens: lens.camera.label) != nil { continue }
                var renderer = self.renderers[lens.camera]
                if renderer == nil {
                    renderer = try? await Task.detached(priority: .utility) { try LensRenderer(image: lens, file: file) }.value
                    if let renderer, self.renderers[lens.camera] == nil { self.renderers[lens.camera] = renderer }
                    renderer = self.renderers[lens.camera]
                }
                guard let renderer else { continue }
                if let image = try? await Task.detached(priority: .utility, operation: { try renderer.render(adjustments, maxDimension: 320) }).value {
                    Thumbnailer.shared.store(image, for: self.shotID, lens: lens.camera.label)
                    self.thumbnailVersion += 1
                }
            }
            self?.thumbnailVersion += 1
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
        let look = adjustments.look
        let refocus = adjustments.refocus
        // The merge depends only on the raw development; the look is applied
        // to its result.
        let development = adjustments.withoutLook
        let mode = effectiveFusionMode
        let cached = (fused?.adjustments == development && fused?.mode == mode) ? fused?.image : nil
        isWorking = true
        isFullResolution = false
        progressText = cached == nil ? "Fusing…" : nil
        if let reference = file.referenceImage, let renderer = renderers[reference.camera] {
            asShotTemperature = renderer.asShotTemperature
            asShotTint = renderer.asShotTint
        }

        renderTask = Task { [weak self] in
            do {
                // Let slider movement settle: briefly for a look change, a
                // little longer before a full merge.
                try await Task.sleep(for: .milliseconds(cached == nil ? 300 : 60))
                guard let self, self.generation == myGeneration else { return }

                let merged: CGImage
                if let cached {
                    merged = cached
                } else {
                    let note: WideFusion.Progress = { message, _ in
                        Task { @MainActor [weak self] in
                            if self?.generation == myGeneration { self?.progressText = message }
                        }
                    }
                    let (float, report, tele) = try await Task.detached(priority: .userInitiated) { () -> (CGImage, FusionReport, TeleFusionReport?) in
                        switch mode {
                        case .wide:
                            let result = try WideFusion.fuse(file: file, adjustments: development, progress: note)
                            return (result.image, result.report, nil)
                        case .full:
                            let result = try TeleFusion.fuse(file: file, adjustments: development, progress: note)
                            return (result.image, result.report.wide, result.report)
                        case .mono:
                            let result = try WideFusion.fuse(file: file, adjustments: development, monochrome: true, progress: note)
                            return (result.image, result.report, nil)
                        }
                    }.value
                    guard self.generation == myGeneration else { return }
                    self.fused = (float, development, mode)
                    self.fusionReport = report
                    self.teleReport = tele
                    self.depth = report.depth
                    merged = float
                }

                let depth = mode == .full ? nil : self.depth
                let display = try await Task.detached(priority: .userInitiated) {
                    try Self.displayImage(from: Self.finished(merged, look: look, refocus: refocus, depth: depth))
                }.value
                guard self.generation == myGeneration else { return }
                self.image = display
                self.isFullResolution = true
                self.isWorking = false
                self.progressText = nil
                if development.isIdentity, look == nil, refocus == nil, mode != .mono, let small = try? Self.displayImage(from: merged, maxDimension: 320) {
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

    /// The merged image with the look applied (or as it is, with no look).
    private nonisolated static func finished(_ merged: CGImage, look: LookSettings?, refocus: RefocusSettings?, depth: DepthMap?) -> CGImage {
        var image = merged
        // Blur first, so the look's sharpening doesn't re-crisp what was blurred.
        if let refocus, let depth, depth.width * depth.scale == merged.width,
           let blurred = Refocus.apply(refocus, to: merged, depth: depth) {
            image = blurred
        }
        guard let look, let styled = LookRenderer.apply(look, to: image) else { return image }
        return styled
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
        /// Single lenses export as JPEG/HEIC/DNG. The fused image adds
        /// 16-bit TIFF, and its DNG is a "linear raw" one: the merge itself,
        /// with no tone curve or look, for editing in a raw converter.
        static let lensFormats: [ExportFormat] = [.jpeg, .heic, .dng]
        static let fusedFormats: [ExportFormat] = [.jpeg, .heic, .tiff, .dng]
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

    /// Lenses that can be exported in `format`. Every lens the app can render
    /// has a DNG form: CFA for colour, LinearRaw for the mono lens.
    func exportable(_ format: ExportFormat) -> [RawImage] {
        lenses.filter { $0.cfaPattern != nil || $0.sensor == .ar1335Mono }
    }

    /// Exports the fused image, re-running the merge if the adjustments
    /// changed since it was last computed.
    func exportFused(as format: ExportFormat, to destination: URL) async throws {
        guard let file else { return }
        let look = adjustments.look
        let refocus = adjustments.refocus
        let development = adjustments.withoutLook
        let mode = effectiveFusionMode
        let cached = (fused?.adjustments == development && fused?.mode == mode) ? fused?.image : nil
        let cachedDepth = depth
        try await Task.detached(priority: .userInitiated) {
            if format == .dng {
                // Merged again without the tone curve, so the file holds
                // scene-linear data. The look is left out: it is the raw
                // converter's job from here.
                let linear = mode == .full
                    ? try TeleFusion.fuse(file: file, adjustments: development, sceneLinear: true).image
                    : try WideFusion.fuse(file: file, adjustments: development, sceneLinear: true, monochrome: mode == .mono).image
                try DNGWriter.writeLinear(image: linear, metadata: file.metadata).write(to: destination, options: .atomic)
                return
            }
            let merged: CGImage
            var depth: DepthMap?
            if let cached {
                merged = cached
                depth = mode == .full ? nil : cachedDepth
            } else if mode == .full {
                merged = try TeleFusion.fuse(file: file, adjustments: development).image
            } else {
                let result = try WideFusion.fuse(file: file, adjustments: development, monochrome: mode == .mono)
                merged = result.image
                depth = result.report.depth
            }
            // Either merge covers the wide lenses' field of view.
            let details = file.metadata.imageProperties(focalLength35: 28)
            try Self.write(Self.finished(merged, look: look, refocus: refocus, depth: depth), as: format, to: destination, details: details)
        }.value
    }

    private nonisolated static func write(_ float: CGImage, as format: ExportFormat, to url: URL, details: [CFString: Any]) throws {
        var image = float
        var properties = details
        properties[kCGImageDestinationLossyCompressionQuality] = 0.95
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
            properties[kCGImageDestinationLossyCompressionQuality] = nil
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ImageRendererError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageRendererError.destinationCreationFailed }
    }
}
