import Foundation
import Observation
import UniformTypeIdentifiers
import LRIKit

/// One imported `.lri` shot, as recorded in the library index.
struct Shot: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var addedAt = Date()
    var capturedAt: Date
    /// True once `capturedAt` has been read from the camera's own record in
    /// the file. Shots indexed by earlier versions carry the file's date
    /// instead and are refreshed on launch.
    var hasCameraTime: Bool?
    var hasLocation: Bool?
    var fileSize: Int64
    var focalLength: Int?
    var gain: Float?
    var shutter: Double?
    /// Module labels present in the file ("A1", "B3", ...), in file order.
    var lenses: [String] = []
    var referenceLens: String?
    var rating = 0
    var flagged = false
    var adjustments = RenderAdjustments()

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

enum LibraryFilter: Hashable {
    case all, flagged, rated, missing
}

enum L16FileType {
    /// Declared in the app bundle's Info.plist; falls back to a dynamic type
    /// when running unbundled (`swift run`).
    static let lri = UTType("dev.sunkencity.L16Studio.lri") ?? UTType(filenameExtension: "lri") ?? .data
}

/// The library: an index of shots persisted as JSON in Application Support.
/// Files opened from disk are referenced where they are; files imported from
/// the camera are downloaded into `libraryFolder`.
@MainActor
@Observable
final class LibraryStore {
    private(set) var shots: [Shot] = []
    var selection: Set<Shot.ID> = []
    var filter: LibraryFilter = .all
    var thumbnailSize: Double = 220
    var importStatus: String?
    var lastError: String?
    /// Bumped whenever files on disk may have changed (an import finished,
    /// the window became active again), so tiles re-check their file and
    /// reload a thumbnail they previously couldn't get.
    private(set) var filesRevision = 0

    func filesMayHaveChanged() { filesRevision += 1 }

    static let supportFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("L16Studio", isDirectory: true)
    }()

    /// Where shots pulled off the camera are stored.
    static let libraryFolder: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("L16 Studio", isDirectory: true)
    }()

    private static var indexURL: URL { supportFolder.appendingPathComponent("library.json") }

    init() {
        load()
        refreshCaptureTimes()
    }

    /// Re-reads the capture time for shots indexed before the app read it
    /// from the file. Runs once per shot, in the background.
    private func refreshCaptureTimes() {
        let stale = shots.filter { $0.hasCameraTime == nil && $0.exists }
        guard !stale.isEmpty else { return }
        Task { [weak self] in
            for shot in stale {
                let url = shot.url
                guard let fresh = try? await Task.detached(priority: .utility, operation: { try Self.describe(url) }).value else { continue }
                self?.update(shot.id) {
                    $0.capturedAt = fresh.capturedAt
                    $0.hasCameraTime = fresh.hasCameraTime
                    $0.hasLocation = fresh.hasLocation
                }
            }
        }
    }

    var visibleShots: [Shot] {
        let filtered: [Shot]
        switch filter {
        case .all: filtered = shots
        case .flagged: filtered = shots.filter(\.flagged)
        case .rated: filtered = shots.filter { $0.rating >= 3 }
        case .missing: filtered = shots.filter { !$0.exists }
        }
        return filtered.sorted { $0.capturedAt > $1.capturedAt }
    }

    func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .all: shots.count
        case .flagged: shots.filter(\.flagged).count
        case .rated: shots.filter { $0.rating >= 3 }.count
        case .missing: shots.filter { !$0.exists }.count
        }
    }

    func shot(_ id: Shot.ID?) -> Shot? {
        guard let id else { return nil }
        return shots.first { $0.id == id }
    }

    func update(_ id: Shot.ID, _ change: (inout Shot) -> Void) {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
        change(&shots[i])
        save()
    }

    func remove(_ ids: Set<Shot.ID>) {
        shots.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        for id in ids { Thumbnailer.shared.discard(id) }
        save()
    }

    // MARK: Import

    /// Adds `.lri` files (or folders containing them) to the library,
    /// referencing them in place. Returns the shots that were new.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> [Shot] {
        let candidates = Self.expand(urls)
        let known = Set(shots.map(\.path))
        let fresh = candidates.filter { !known.contains($0.path) }
        guard !fresh.isEmpty else {
            importStatus = candidates.isEmpty ? "No .lri files found" : "Already in the library"
            // A known shot may have just been re-downloaded after going missing.
            filesMayHaveChanged()
            return []
        }

        var added: [Shot] = []
        for (i, url) in fresh.enumerated() {
            importStatus = "Reading \(url.lastPathComponent) (\(i + 1) of \(fresh.count))"
            do {
                let shot = try await Task.detached(priority: .userInitiated) { try Self.describe(url) }.value
                shots.append(shot)
                added.append(shot)
            } catch {
                lastError = "\(url.lastPathComponent): \(error)"
            }
        }
        save()
        filesMayHaveChanged()
        importStatus = added.isEmpty ? nil : "Imported \(added.count) shot\(added.count == 1 ? "" : "s")"
        return added
    }

    private static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                out += items.filter { $0.pathExtension.lowercased() == "lri" }
            } else if url.pathExtension.lowercased() == "lri" {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Parses just enough of the file to describe it in the library.
    nonisolated static func describe(_ url: URL) throws -> Shot {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let file = try LRIFile.decode(data)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let created = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? Date()
        let taken = file.metadata.captureTime?.date
        return Shot(
            path: url.path,
            capturedAt: taken ?? created,
            hasCameraTime: taken != nil,
            hasLocation: file.metadata.latitude != nil && file.metadata.longitude != nil,
            fileSize: (attrs[.size] as? NSNumber)?.int64Value ?? Int64(data.count),
            focalLength: file.metadata.focalLength.map(Int.init),
            gain: file.metadata.imageGain,
            shutter: file.metadata.imageIntegrationTime,
            lenses: file.images.map(\.camera.label),
            referenceLens: file.metadata.referenceCamera?.label
        )
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        shots = (try? decoder.decode([Shot].self, from: data)) ?? []
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
            try encoder.encode(shots).write(to: Self.indexURL, options: .atomic)
        } catch {
            lastError = "Couldn't save the library index: \(error.localizedDescription)"
        }
    }
}

// MARK: Formatting helpers

enum Describe {
    static func shutter(_ seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "–" }
        if s >= 0.4 { return String(format: "%.1f s", s) }
        return "1/\(Int((1 / s).rounded())) s"
    }

    /// The camera records sensor gain, not ISO; base gain 1.0 is roughly ISO 100.
    static func iso(_ gain: Float?) -> String {
        guard let g = gain, g > 0 else { return "–" }
        return "ISO \(Int((g * 100 / 10).rounded()) * 10)"
    }

    static func focal(_ mm: Int?) -> String { mm.map { "\($0) mm" } ?? "–" }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
