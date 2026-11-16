import SwiftUI
import AppKit
import LRIKit

struct LibraryGridView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var library = model.library
        let shots = library.visibleShots
        VStack(spacing: 0) {
            if shots.isEmpty {
                EmptyLibraryView(isFiltered: library.filter != .all && !library.shots.isEmpty)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: library.thumbnailSize, maximum: library.thumbnailSize * 1.6), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(shots) { shot in
                            ShotCell(shot: shot, isSelected: library.selection.contains(shot.id))
                                .gesture(TapGesture(count: 2).onEnded { model.open(shot) })
                                .simultaneousGesture(TapGesture().onEnded { select(shot) })
                                .contextMenu { menu(for: shot) }
                        }
                    }
                    .padding(18)
                }
            }
            Divider().overlay(Theme.hairline)
            footer(count: shots.count)
        }
        .onDeleteCommand { library.remove(library.selection) }
    }

    private func select(_ shot: Shot) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.library.selection.contains(shot.id) {
                model.library.selection.remove(shot.id)
            } else {
                model.library.selection.insert(shot.id)
            }
        } else {
            model.library.selection = [shot.id]
        }
    }

    private func footer(count: Int) -> some View {
        @Bindable var library = model.library
        return HStack(spacing: 12) {
            Text("\(count) shot\(count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
            Slider(value: $library.thumbnailSize, in: 140...420)
                .frame(width: 150)
                .controlSize(.small)
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    @ViewBuilder
    private func menu(for shot: Shot) -> some View {
        let targets: Set<Shot.ID> = model.library.selection.contains(shot.id) ? model.library.selection : [shot.id]
        Button("Open") { model.open(shot) }
        Button(shot.flagged ? "Remove Flag" : "Flag") {
            for id in targets { model.library.update(id) { $0.flagged = !shot.flagged } }
        }
        Menu("Rating") {
            ForEach((0...5).reversed(), id: \.self) { stars in
                Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                    for id in targets { model.library.update(id) { $0.rating = stars } }
                }
            }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
        Button("Remove from Library", role: .destructive) { model.library.remove(targets) }
    }
}

struct ShotCell: View {
    let shot: Shot
    let isSelected: Bool
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(Theme.tile)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if shot.exists {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                if shot.flagged {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .padding(7)
                        .shadow(radius: 2)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2.5)
            }

            HStack(spacing: 6) {
                Text(shot.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if shot.rating > 0 {
                    Text(String(repeating: "★", count: shot.rating))
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
            }
            Text("\(Describe.focal(shot.focalLength))  ·  \(Describe.shutter(shot.shutter))  ·  \(Describe.iso(shot.gain))  ·  \(shot.lenses.count) lenses")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: shot.id) {
            guard shot.exists else { return }
            thumbnail = await Thumbnailer.shared.thumbnail(for: shot)
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle" : "camera.aperture")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.9))
            Text(isFiltered ? "Nothing matches this filter" : "Your L16 library is empty")
                .font(.title2.weight(.semibold))
            if !isFiltered {
                Text("Drop .lri files here, or bring shots straight over from the camera.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Import from Disk…") { model.importFromDisk() }
                    Button("Import from Camera…") { model.showCameraImport = true }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
