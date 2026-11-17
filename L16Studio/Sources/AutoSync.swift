import Foundation
import Observation

/// Automatic import over Wi-Fi: while it is switched on and a camera on the
/// network has Wi-Fi transfer running, shots taken since the Mac last saw
/// that camera are downloaded into the library on their own.
///
/// "New" is decided per camera. The first time a camera is seen, what is
/// already on it is recorded as known and left alone (a camera can hold tens
/// of gigabytes; the import sheet is the way to fetch older shots). From
/// then on, anything not in that record is new, including shots taken while
/// the camera was away from the network.
@MainActor
@Observable
final class AutoSync {
    private(set) var status = ""
    private(set) var isBusy = false

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let finder = WiFiCameraFinder()
    @ObservationIgnored private var loop: Task<Void, Never>?

    private static let enabledKey = "autoSyncEnabled"
    private static let knownKey = "autoSyncKnownShots"
    private static let interval: Duration = .seconds(12)

    init(library: LibraryStore) {
        self.library = library
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { start() }
    }

    private func start() {
        finder.start()
        status = "Looking for a camera…"
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pass()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        finder.stop()
        isBusy = false
        status = ""
    }

    // MARK: Record of shots already dealt with, per camera

    /// "L16_00012.lri:162625717" entries, keyed by camera id.
    private var known: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: Self.knownKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.knownKey) }
    }

    private static func key(_ file: CameraLink.RemoteFile) -> String { "\(file.name):\(file.size)" }

    /// Every L16 numbers its shots from 1, so two cameras produce files
    /// with the same names. A name already
    /// taken in the library folder goes into a folder of this camera's own
    /// instead of replacing the other camera's shot.
    private static func folder(for file: CameraLink.RemoteFile, from cameraID: String) -> URL {
        let main = LibraryStore.libraryFolder
        guard FileManager.default.fileExists(atPath: main.appendingPathComponent(file.name).path) else { return main }
        let safe = cameraID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        return main.appendingPathComponent("Camera \(safe.isEmpty ? "other" : safe)", isDirectory: true)
    }

    // MARK: One look at the network

    private func pass() async {
        guard let address = finder.addresses.first else {
            status = "Waiting for a camera with Wi-Fi transfer on"
            return
        }
        let camera: CameraLink.WiFiCamera
        do {
            camera = try await CameraLink.wifiCamera(at: address)
        } catch {
            status = "Camera found, but it isn't answering"
            return
        }
        guard !Task.isCancelled else { return }

        var record = known
        guard var seen = record[camera.id].map(Set.init) else {
            // First meeting: note what's there, fetch nothing.
            record[camera.id] = camera.files.map(Self.key)
            known = record
            let count = camera.files.count
            status = count == 0 ? "Connected. New shots will arrive here."
                : "Connected. New shots will arrive here; the \(count) already on the camera are left for Import."
            return
        }

        let fresh = camera.files.filter { !seen.contains(Self.key($0)) }
        guard !fresh.isEmpty else {
            if !isBusy { status = "Connected. Up to date." }
            return
        }

        isBusy = true
        defer { isBusy = false }
        var failed = 0
        for (i, file) in fresh.enumerated() {
            guard !Task.isCancelled, isEnabled else { return }
            status = "Receiving \(file.name)" + (fresh.count > 1 ? " (\(i + 1) of \(fresh.count))" : "")
            do {
                // A shot is listed as soon as the camera starts writing it;
                // a short file here just means "not finished", so it is
                // retried on the next pass rather than recorded.
                let url = try await CameraLink.download(file, into: Self.folder(for: file, from: camera.id))
                await library.importFiles([url])
                seen.insert(Self.key(file))
                record[camera.id] = Array(seen)
                known = record
            } catch {
                failed += 1
            }
        }
        let got = fresh.count - failed
        status = failed == 0 ? "Received \(got) new shot\(got == 1 ? "" : "s")."
            : "Received \(got) of \(fresh.count); will try the rest again."
    }
}
