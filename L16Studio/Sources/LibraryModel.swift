import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers
import LRIKit

/// Declared in project.yml's UTImportedTypeDeclarations -- .lri isn't a
/// system-registered type, so without this declaration `UTType(filenameExtension:)`
/// silently fails and NSOpenPanel's content-type filter ends up empty (which
/// means "show everything," not "show nothing").
private let lriType = UTType("dev.sunkencity.L16Studio.lri")!

@Observable
@MainActor
final class LibraryModel {
    var shots: [ImportedShot] = []
    var selectedShotID: ImportedShot.ID?
    var importError: String?

    var selectedShot: ImportedShot? {
        shots.first { $0.id == selectedShotID }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [lriType]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importFiles(at: panel.urls)
        }
    }

    func importFiles(at urls: [URL]) {
        importError = nil
        Task {
            for url in urls where url.pathExtension.lowercased() == "lri" {
                await importFile(at: url)
            }
        }
    }

    private func importFile(at url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let file = try await Task.detached(priority: .userInitiated) {
                try LRIFile.decode(data)
            }.value
            let shot = ImportedShot(url: url, file: file)
            shots.append(shot)
            if selectedShotID == nil {
                selectedShotID = shot.id
            }
        } catch {
            importError = "Couldn't import \(url.lastPathComponent): \(error)"
        }
    }
}
