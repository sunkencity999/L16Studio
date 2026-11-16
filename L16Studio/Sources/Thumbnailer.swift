import Foundation
import CoreGraphics
import ImageIO
import LRIKit

/// Renders and caches small previews. Rendering a lens means unpacking 13 MP
/// of raw data, so results are kept in memory and on disk (Caches), and work
/// is serialised on one background queue to keep memory use bounded.
final class Thumbnailer: @unchecked Sendable {
    static let shared = Thumbnailer()

    private let queue = DispatchQueue(label: "l16studio.thumbnailer", qos: .utility)
    private let memory = NSCache<NSString, CGImage>()
    private let folder: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("L16Studio/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    private func key(_ shot: Shot.ID, _ lens: String?) -> String {
        "\(shot.uuidString)-\(lens ?? "ref")"
    }

    private func fileURL(_ key: String) -> URL { folder.appendingPathComponent(key + ".jpg") }

    /// A preview of the shot's reference lens (`lens == nil`) or a specific lens.
    func thumbnail(for shot: Shot, lens: String? = nil, maxDimension: Int = 720) async -> CGImage? {
        let key = key(shot.id, lens)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.load(shot, lens: lens, key: key, maxDimension: maxDimension))
            }
        }
    }

    private func load(_ shot: Shot, lens: String?, key: String, maxDimension: Int) -> CGImage? {
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let url = fileURL(key)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        guard let image = try? render(shot, lens: lens, maxDimension: maxDimension) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return image
    }

    private func render(_ shot: Shot, lens: String?, maxDimension: Int) throws -> CGImage {
        let data = try Data(contentsOf: shot.url, options: .mappedIfSafe)
        let file = try LRIFile.decode(data)
        let wanted = lens ?? shot.referenceLens
        guard let image = file.images.first(where: { $0.camera.label == wanted })
            ?? file.referenceImage
            ?? file.images.first(where: { $0.cfaPattern != nil })
        else { throw ImageRendererError.renderFailed }
        return try LensRenderer(image: image, file: file).render(shot.adjustments, maxDimension: maxDimension)
    }

    /// A preview that already exists in memory or on disk; never renders.
    func cached(for shot: Shot, lens: String) async -> CGImage? {
        let key = key(shot.id, lens)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async {
                let url = self.fileURL(key)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.memory.setObject(image, forKey: key as NSString)
                continuation.resume(returning: image)
            }
        }
    }

    /// Stores a preview rendered elsewhere (the viewer already has the file open).
    func store(_ image: CGImage, for shot: Shot.ID, lens: String?) {
        let key = key(shot, lens)
        memory.setObject(image, forKey: key as NSString)
        queue.async {
            if let dest = CGImageDestinationCreateWithURL(self.fileURL(key) as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
        }
    }

    /// Drops every cached preview of a shot (after removal or an adjustment change).
    func discard(_ shot: Shot.ID) {
        let prefix = shot.uuidString
        queue.async {
            let items = (try? FileManager.default.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: nil)) ?? []
            for item in items where item.lastPathComponent.hasPrefix(prefix) {
                self.memory.removeObject(forKey: item.deletingPathExtension().lastPathComponent as NSString)
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}
