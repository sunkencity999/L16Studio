import SwiftUI

/// Sheet for pulling shots straight off a connected L16.
struct CameraImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Transport: String, CaseIterable, Identifiable {
        case usb = "USB cable", wifi = "Wi-Fi"
        var id: String { rawValue }
    }

    /// Remembered between uses of the sheet.
    @AppStorage("cameraTransport") private var transport: Transport = .usb
    @AppStorage("cameraWiFiAddress") private var wifiAddress = ""
    @State private var finder = WiFiCameraFinder()
    @State private var files: [CameraLink.RemoteFile] = []
    @State private var chosen: Set<Int> = []
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var progress: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "camera.aperture").font(.title2).foregroundStyle(Theme.accent)
                Text("Import from L16").font(.title2.weight(.semibold))
                Spacer()
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(isLoading || isImporting)
                    .help("Look for the camera again")
            }

            Picker("Connection", selection: $transport) {
                ForEach(Transport.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isImporting)
            .onChange(of: transport) { Task { await refresh() } }

            if transport == .wifi {
                HStack {
                    TextField("Camera address, e.g. 192.168.1.20", text: $wifiAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await refresh() } }
                    Button("Connect") { Task { await refresh() } }
                        .disabled(wifiAddress.trimmingCharacters(in: .whitespaces).isEmpty || isImporting)
                }
                if let found = finder.addresses.first, found != wifiAddress {
                    Button("Use the camera found on this network (\(found))") {
                        wifiAddress = found
                        Task { await refresh() }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }

            content

            HStack {
                if let progress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(chosen.count) Shot\(chosen.count == 1 ? "" : "s")") { Task { await importChosen() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || isImporting)
            }
        }
        .padding(20)
        .frame(width: 520, height: 500)
        .task {
            finder.start()
            await refresh()
        }
        .onDisappear { finder.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack { ProgressView("Looking for the camera…") }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let problem {
            VStack(spacing: 10) {
                Image(systemName: "cable.connector.slash").font(.largeTitle).foregroundStyle(.secondary)
                Text(problem).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            Text("The camera has no shots on it.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(files) { file in
                let have = alreadyHave(file)
                Toggle(isOn: Binding(
                    get: { chosen.contains(file.id) },
                    set: { if $0 { chosen.insert(file.id) } else { chosen.remove(file.id) } }
                )) {
                    HStack {
                        Text(file.name)
                        Spacer()
                        if have {
                            Text("In library").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(Describe.size(file.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .disabled(isImporting)
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func localURL(_ file: CameraLink.RemoteFile) -> URL {
        LibraryStore.libraryFolder.appendingPathComponent(file.name)
    }

    /// Same name and size as a file already downloaded into the library folder.
    private func alreadyHave(_ file: CameraLink.RemoteFile) -> Bool {
        let path = localURL(file).path
        guard model.library.shots.contains(where: { $0.path == path }) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        return size == file.size
    }

    private func refresh() async {
        isLoading = true
        problem = nil
        do {
            if transport == .wifi, wifiAddress.trimmingCharacters(in: .whitespaces).isEmpty {
                files = []
                problem = "On the camera, open L16 Studio and turn on Wi-Fi transfer, then enter the address it shows."
                isLoading = false
                return
            }
            files = try await CameraLink.listShots(from: transport == .wifi ? .wifi(wifiAddress) : .usb)
            chosen = Set(files.filter { !alreadyHave($0) }.map(\.id))
        } catch {
            files = []
            problem = error.localizedDescription
        }
        isLoading = false
    }

    private func importChosen() async {
        isImporting = true
        let queue = files.filter { chosen.contains($0.id) }
        var failures: [String] = []
        for (i, file) in queue.enumerated() {
            progress = "Downloading \(file.name) (\(i + 1) of \(queue.count))"
            do {
                let url = try await CameraLink.download(file, into: LibraryStore.libraryFolder)
                await model.library.importFiles([url])
                chosen.remove(file.id)
            } catch {
                failures.append("\(file.name): \(error.localizedDescription)")
            }
        }
        progress = nil
        isImporting = false
        if failures.isEmpty {
            dismiss()
        } else {
            problem = failures.joined(separator: "\n")
        }
    }
}
