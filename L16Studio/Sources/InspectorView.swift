import SwiftUI
import AppKit
import LRIKit

/// The right-hand panel: shot details in the library; shot details, per-lens
/// details, adjustments and export while a shot is open.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let session = model.session, let shot = model.library.shot(session.shotID) {
                    ShotInfoSection(shot: shot)
                    if session.showsFused {
                        FusionInfoSection(session: session)
                    } else if let lens = session.selectedImage {
                        LensInfoSection(lens: lens)
                    }
                    AdjustSection(session: session)
                    ExportSection(session: session, shotName: shot.name)
                } else if model.library.selection.count == 1, let shot = model.library.shot(model.library.selection.first) {
                    ShotInfoSection(shot: shot)
                    Button("Open") { model.open(shot) }
                        .buttonStyle(.borderedProminent)
                } else if model.library.selection.count > 1 {
                    Text("\(model.library.selection.count) shots selected")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a shot to see its details.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panel)
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct ShotInfoSection: View {
    @Environment(AppModel.self) private var model
    let shot: Shot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shot.name).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 10) {
                RatingControl(rating: shot.rating) { stars in
                    model.library.update(shot.id) { $0.rating = stars }
                }
                Spacer()
                Button {
                    model.library.update(shot.id) { $0.flagged.toggle() }
                } label: {
                    Image(systemName: shot.flagged ? "flag.fill" : "flag")
                        .foregroundStyle(shot.flagged ? Theme.accent : .secondary)
                }
                .buttonStyle(.borderless)
                .help(shot.flagged ? "Remove flag" : "Flag this shot")
            }
            .padding(.bottom, 4)

            SectionHeader(title: "Shot")
            InfoRow(label: "Focal length", value: Describe.focal(shot.focalLength))
            InfoRow(label: "Shutter", value: Describe.shutter(shot.shutter))
            InfoRow(label: "Sensitivity", value: Describe.iso(shot.gain))
            InfoRow(label: "Lenses fired", value: "\(shot.lenses.count)")
            InfoRow(label: "File", value: Describe.size(shot.fileSize))
            InfoRow(label: "Added", value: Describe.date(shot.capturedAt))
        }
    }
}

struct RatingControl: View {
    let rating: Int
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    set(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? Theme.accent : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct LensInfoSection: View {
    let lens: RawImage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Lens \(lens.camera.label)")
            InfoRow(label: "Focal length", value: "\(lens.camera.focalLength) mm")
            InfoRow(label: "Sensor", value: lens.sensor == .ar1335Mono ? "13 MP mono" : "13 MP colour")
            InfoRow(label: "Size", value: "\(lens.width) × \(lens.height)")
            InfoRow(label: "Exposure", value: Describe.shutter(lens.exposure))
            InfoRow(label: "Gain", value: String(format: "%.2f×", lens.analogGain * (lens.digitalGain ?? 1)))
            InfoRow(label: "Focus position", value: "\(lens.lensPosition)")
        }
    }
}

struct FusionInfoSection: View {
    let session: ShotSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Fusion")
            if let report = session.fusionReport {
                InfoRow(label: "Reference", value: report.reference.label)
                ForEach(report.frames, id: \.camera) { frame in
                    InfoRow(
                        label: frame.camera.label,
                        value: String(format: "used in %.0f%% · shift %.0f px", frame.coverage * 100, frame.medianShift)
                    )
                }
                InfoRow(label: "Time", value: String(format: "%.1f s", report.seconds))
            } else {
                Text("Merging…").font(.callout).foregroundStyle(.secondary)
            }
            Text("Lenses with the same focal length are aligned to the reference and merged: lower noise, and the sharpest detail from each. A lens is left out wherever it doesn't line up, such as around close objects.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AdjustSection: View {
    @Bindable var session: ShotSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Adjust")
                Spacer()
                Button("Reset") { session.adjustments = .none }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(session.adjustments.isIdentity)
            }
            slider("Exposure", value: $session.adjustments.exposure, range: -3...3, format: "%+.2f EV")

            if let asShotTemp = session.asShotTemperature, let asShotTint = session.asShotTint {
                slider(
                    "Temperature",
                    value: Binding(
                        get: { session.adjustments.temperature ?? asShotTemp },
                        set: { session.adjustments.temperature = $0 }
                    ),
                    range: 2000...12000, format: "%.0f K"
                )
                slider(
                    "Tint",
                    value: Binding(
                        get: { session.adjustments.tint ?? asShotTint },
                        set: { session.adjustments.tint = $0 }
                    ),
                    range: -150...150, format: "%+.0f"
                )
            } else if session.selectedImage?.sensor == .ar1335Mono {
                Text("White balance doesn't apply to the mono lens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Adjustments apply to every lens in this shot.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}

struct ExportSection: View {
    @Environment(AppModel.self) private var model
    let session: ShotSession
    let shotName: String

    @State private var format: ShotSession.ExportFormat = .jpeg
    @State private var status: String?
    @State private var isExporting = false

    private var formats: [ShotSession.ExportFormat] {
        session.showsFused ? ShotSession.ExportFormat.fusedFormats : ShotSession.ExportFormat.lensFormats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Export")
            Picker("Format", selection: $format) {
                ForEach(formats) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: session.showsFused) {
                if !formats.contains(format) { format = .jpeg }
            }

            if session.showsFused {
                Button {
                    exportFused()
                } label: {
                    Label("Export Fused Image…", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isExporting)
            } else {
                Button {
                    exportSelected()
                } label: {
                    Label("Export This Lens…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isExporting || !canExportSelected)

                Button {
                    exportAll()
                } label: {
                    Label("Export All Lenses…", systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isExporting || session.exportable(format).isEmpty)
            }

            if format == .dng {
                Text("DNG is the untouched raw frame with Light's colour calibration; adjustments aren't baked in.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if format == .tiff {
                Text("16-bit TIFF in Display P3, for further editing.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var canExportSelected: Bool {
        guard let lens = session.selectedImage else { return false }
        return session.exportable(format).contains { $0.camera == lens.camera }
    }

    private func exportFused() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(shotName)_fused.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = format
        run(count: 1) { try await session.exportFused(as: format, to: url) }
    }

    private func exportSelected() {
        guard let lens = session.selectedImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = "\(shotName)_\(lens.camera.label).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = format
        run(count: 1) { try await session.export(lens, as: format, to: url) }
    }

    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let lenses = session.exportable(format)
        let format = format
        let name = shotName
        run(count: lenses.count) {
            for lens in lenses {
                let url = folder.appendingPathComponent("\(name)_\(lens.camera.label).\(format.fileExtension)")
                try await session.export(lens, as: format, to: url)
            }
        }
    }

    private func run(count: Int, _ work: @escaping () async throws -> Void) {
        isExporting = true
        status = "Exporting \(count) file\(count == 1 ? "" : "s")…"
        Task {
            do {
                try await work()
                status = "Exported \(count) file\(count == 1 ? "" : "s")."
            } catch {
                status = nil
                model.library.lastError = "Export failed: \(error)"
            }
            isExporting = false
        }
    }
}
