import Foundation
import Observation

/// Talks to an L16 plugged in over USB. Two transports, tried in this order:
///
/// - **adb**, when USB debugging is enabled on the camera and this Mac is
///   authorised (`brew install android-platform-tools`). Fast and reliable.
/// - **MTP**, with the camera's USB mode set to file transfer. macOS has no
///   built-in MTP support, so this drives the libmtp command-line tools
///   (`brew install libmtp`). In photo-transfer (PTP) mode the camera exposes
///   no storage at all.
enum CameraLink {
    struct RemoteFile: Identifiable, Hashable {
        /// MTP object id, or the position in the listing for adb.
        let id: Int
        let name: String
        let size: Int64
        /// Full path on the camera when listed over adb; nil for MTP.
        var path: String? = nil
        /// Download address when listed over Wi-Fi.
        var url: URL? = nil
    }

    /// Where to look for the camera.
    enum Source: Hashable {
        /// A cable: adb if available, otherwise MTP.
        case usb
        /// The on-camera L16 Studio app's Wi-Fi transfer, at "host" or "host:port".
        case wifi(String)
    }

    static let wifiPort = 8016

    /// Where the stock camera app stores shots.
    static let cameraFolder = "/sdcard/DCIM/Camera"

    enum Failure: LocalizedError {
        case toolsMissing
        case noCamera
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .toolsMissing:
                "No transfer tools found. In Terminal, run: brew install android-platform-tools libmtp"
            case .noCamera:
                "No camera found. Plug the L16 in directly (not through a hub) and wake it. Either enable USB debugging on it, or set its USB mode to file transfer."
            case .failed(let detail):
                detail
            }
        }
    }

    private static func tool(_ name: String) -> URL? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static var isAvailable: Bool { tool("adb") != nil || (tool("mtp-files") != nil && tool("mtp-getfile") != nil) }

    /// True when a camera is attached and authorised for adb.
    private static func adbReady() async -> Bool {
        guard let adb = tool("adb"), let output = try? await run(adb, ["devices"], timeout: 15) else { return false }
        return output.split(whereSeparator: \.isNewline).dropFirst().contains { line in
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            return parts.count >= 2 && parts[1] == "device"
        }
    }

    private static func listOverADB() async throws -> [RemoteFile] {
        guard let adb = tool("adb") else { throw Failure.toolsMissing }
        // `ls -l` on the camera: mode owner group size date time name
        let output = try await run(adb, ["shell", "ls", "-l", cameraFolder], timeout: 30)
        var files: [RemoteFile] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 7, parts[0].hasPrefix("-"),
                  let name = parts.last.map(String.init), name.lowercased().hasSuffix(".lri"),
                  let size = Int64(parts[3]) else { continue }
            files.append(RemoteFile(id: files.count, name: name, size: size, path: "\(cameraFolder)/\(name)"))
        }
        return files.sorted { $0.name < $1.name }
    }

    /// Runs a tool to completion and returns its combined output.
    private static func run(_ url: URL, _ arguments: [String], in directory: URL? = nil, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = url
                process.arguments = arguments
                process.currentDirectoryURL = directory
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                var collected = Data()
                let lock = NSLock()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    lock.lock(); collected.append(chunk); lock.unlock()
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure.failed(error.localizedDescription))
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                pipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                let text = String(decoding: collected, as: UTF8.self)
                lock.unlock()
                continuation.resume(returning: text)
            }
        }
    }

    /// Takes a picture on a camera connected by cable and returns the new
    /// raw file once the camera has finished writing it. Needs adb (USB
    /// debugging), because it works by pressing the camera's shutter key.
    static func capture() async throws -> RemoteFile {
        guard let adb = tool("adb") else { throw Failure.toolsMissing }
        guard await adbReady() else {
            throw Failure.failed("Taking a picture from the Mac needs the cable, with USB debugging switched on in the camera's developer settings.")
        }
        let before = Set(try await listOverADB().map(\.name))

        _ = try await run(adb, ["shell", "input", "keyevent", "KEYCODE_WAKEUP"], timeout: 10)
        let windows = try await run(adb, ["shell", "dumpsys", "window"], timeout: 15)
        if windows.contains("mShowingLockscreen=true") {
            throw Failure.failed("The camera is locked. Unlock its screen, then try again.")
        }
        // Bring Light's camera app forward if it isn't already.
        let focus = windows.split(whereSeparator: \.isNewline).first { $0.contains("mCurrentFocus") } ?? ""
        if !focus.contains("light.co.lightcamera") {
            _ = try await run(adb, ["shell", "monkey", "-p", "light.co.lightcamera", "-c", "android.intent.category.LAUNCHER", "1"], timeout: 15)
            try await Task.sleep(for: .seconds(3))
        }
        _ = try await run(adb, ["shell", "input", "keyevent", "KEYCODE_CAMERA"], timeout: 10)

        // The file appears at once and grows; it is done when its size holds.
        var last: RemoteFile?
        for _ in 0..<25 {
            try await Task.sleep(for: .seconds(1))
            guard let fresh = try await listOverADB().last(where: { !before.contains($0.name) }) else { continue }
            if let last, last.name == fresh.name, last.size == fresh.size, fresh.size > 1_000_000 { return fresh }
            last = fresh
        }
        throw Failure.failed("The camera didn't produce a new shot. Check that its camera app is showing and nothing is covering the screen.")
    }

    private static func baseURL(_ address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespaces)
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !text.isEmpty else { return nil }
        if !text.contains(":") { text += ":\(wifiPort)" }
        return URL(string: "http://\(text)")
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 1800
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private struct WiFiListing: Decodable {
        struct Entry: Decodable {
            let name: String
            let rawSize: Int64
        }
        let shots: [Entry]
        /// Which camera this is (app 0.3.0 and later).
        let id: String?
    }

    /// The shots a camera offers over Wi-Fi, and which camera it is.
    struct WiFiCamera {
        /// The camera's own id, or its address for app versions before 0.3.0.
        let id: String
        let files: [RemoteFile]
    }

    static func wifiCamera(at address: String) async throws -> WiFiCamera {
        let (id, files) = try await fetchOverWiFi(address)
        return WiFiCamera(id: id ?? address, files: files)
    }

    private static func listOverWiFi(_ address: String) async throws -> [RemoteFile] {
        try await fetchOverWiFi(address).1
    }

    private static func fetchOverWiFi(_ address: String) async throws -> (String?, [RemoteFile]) {
        guard let base = baseURL(address) else { throw Failure.failed("Enter the address shown on the camera.") }
        do {
            let (data, response) = try await session.data(from: base.appendingPathComponent("api/shots"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure.failed("The camera at \(address) didn't answer as expected.")
            }
            let listing = try JSONDecoder().decode(WiFiListing.self, from: data)
            let files = listing.shots.enumerated().compactMap { index, entry -> RemoteFile? in
                guard entry.rawSize > 0 else { return nil } // preview only: nothing to import
                return RemoteFile(
                    id: index, name: entry.name + ".lri", size: entry.rawSize,
                    url: base.appendingPathComponent("raw/\(entry.name).lri"))
            }.sorted { $0.name < $1.name }
            return (listing.id, files)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.failed("Couldn't reach the camera at \(address). On the camera, open L16 Studio and turn on Wi-Fi transfer; the Mac must be on the same network. (\(error.localizedDescription))")
        }
    }

    /// Lists the `.lri` files on the camera.
    static func listShots(from source: Source = .usb) async throws -> [RemoteFile] {
        if case .wifi(let address) = source { return try await listOverWiFi(address) }
        if await adbReady() { return try await listOverADB() }
        guard let lister = tool("mtp-files") else {
            throw tool("adb") != nil ? Failure.noCamera : Failure.toolsMissing
        }
        let output = try await run(lister, [], timeout: 90)
        if output.contains("No raw devices found") || output.contains("No devices") { throw Failure.noCamera }

        var files: [RemoteFile] = []
        var id: Int?, name: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("File ID:") {
                id = Int(trimmed.dropFirst("File ID:".count).trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("Filename:") {
                name = trimmed.dropFirst("Filename:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("File size") {
                let digits = trimmed.dropFirst("File size".count).prefix { $0 == " " || $0.isNumber }
                if let id, let name, let size = Int64(digits.trimmingCharacters(in: .whitespaces)),
                   name.lowercased().hasSuffix(".lri") {
                    files.append(RemoteFile(id: id, name: name, size: size))
                }
                id = nil; name = nil
            }
        }
        return files.sorted { $0.name < $1.name }
    }

    /// Downloads one file into `folder` and returns where it landed. The
    /// camera occasionally refuses a session opened right after the previous
    /// one closed, so this retries a few times.
    static func download(_ file: RemoteFile, into folder: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(file.name)
        func localSize() -> Int64 {
            (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        }

        if let url = file.url {
            try? FileManager.default.removeItem(at: destination)
            do {
                let (temporary, response) = try await session.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw Failure.failed("The camera refused \(file.name).")
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.failed("Couldn't download \(file.name) over Wi-Fi: \(error.localizedDescription)")
            }
            if localSize() == file.size { return destination }
            try? FileManager.default.removeItem(at: destination)
            throw Failure.failed("\(file.name) arrived incomplete over Wi-Fi.")
        }

        if let path = file.path {
            guard let adb = tool("adb") else { throw Failure.toolsMissing }
            try? FileManager.default.removeItem(at: destination)
            let output = try await run(adb, ["pull", path, destination.path], timeout: 600)
            if localSize() == file.size { return destination }
            try? FileManager.default.removeItem(at: destination)
            throw Failure.failed("Couldn't download \(file.name) over adb. \(output.suffix(200))")
        }

        guard let getter = tool("mtp-getfile") else { throw Failure.toolsMissing }
        var lastOutput = ""
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .seconds(3)) }
            try? FileManager.default.removeItem(at: destination)
            lastOutput = try await run(getter, [String(file.id), file.name], in: folder, timeout: 600)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size == file.size { return destination }
        }
        try? FileManager.default.removeItem(at: destination)
        if lastOutput.contains("No devices") { throw Failure.noCamera }
        throw Failure.failed("Couldn't download \(file.name) from the camera.")
    }
}

/// Finds cameras running the on-camera app's Wi-Fi transfer on the local
/// network (advertised over Bonjour as `_l16studio._tcp`).
@MainActor
@Observable
final class WiFiCameraFinder: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    /// "host:port" of each camera found.
    private(set) var addresses: [String] = []

    @ObservationIgnored private let browser = NetServiceBrowser()
    @ObservationIgnored private var resolving: [NetService] = []
    /// Service name -> address, so a camera that stops advertising is dropped.
    @ObservationIgnored private var byName: [String: String] = [:]
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.searchForServices(ofType: "_l16studio._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        started = false
        resolving.removeAll()
        byName.removeAll()
        addresses.removeAll()
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        Task { @MainActor in
            resolving.removeAll { $0.name == name }
            if let address = byName.removeValue(forKey: name) {
                addresses.removeAll { $0 == address }
            }
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            service.delegate = self
            resolving.append(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName, port = sender.port, name = sender.name
        Task { @MainActor in
            guard let host, port > 0 else { return }
            let address = "\(host.trimmingCharacters(in: CharacterSet(charactersIn: "."))):\(port)"
            byName[name] = address
            if !addresses.contains(address) { addresses.append(address) }
        }
    }
}
