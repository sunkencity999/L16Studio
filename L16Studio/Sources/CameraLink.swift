import Foundation

/// Talks to an L16 plugged in over USB in file-transfer (MTP) mode.
///
/// macOS has no built-in MTP support, so this drives the libmtp command-line
/// tools (`brew install libmtp`). The camera must be awake with USB set to
/// file transfer; in photo-transfer (PTP) mode it exposes no storage at all.
enum CameraLink {
    struct RemoteFile: Identifiable, Hashable {
        let id: Int
        let name: String
        let size: Int64
    }

    enum Failure: LocalizedError {
        case toolsMissing
        case noCamera
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .toolsMissing:
                "The libmtp tools aren't installed. In Terminal, run: brew install libmtp"
            case .noCamera:
                "No camera found. Plug the L16 in directly, wake it, and set its USB mode to file transfer."
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

    static var isAvailable: Bool { tool("mtp-files") != nil && tool("mtp-getfile") != nil }

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

    /// Lists the `.lri` files on the camera.
    static func listShots() async throws -> [RemoteFile] {
        guard let lister = tool("mtp-files") else { throw Failure.toolsMissing }
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
        guard let getter = tool("mtp-getfile") else { throw Failure.toolsMissing }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(file.name)
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
