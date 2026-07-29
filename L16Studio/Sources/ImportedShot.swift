import Foundation
import LRIKit

/// One imported `.lri` file: its source location, decoded contents, and a
/// display-friendly name.
struct ImportedShot: Identifiable {
    let id = UUID()
    let url: URL
    let file: LRIFile

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Captures worth showing in the gallery: only ones we can actually
    /// render right now (Bayer color captures with a known CFA pattern).
    /// Mono captures and BayerJPEG-format captures are excluded -- see
    /// ImageRenderer's documented gaps for why.
    var renderableImages: [RawImage] {
        file.images.filter { $0.cfaPattern != nil }
    }
}
