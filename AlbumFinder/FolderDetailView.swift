import SwiftUI

/// One saved video: its albums, plus what the app heard and saw so misses can be checked later.
struct FolderDetailView: View {
    @Bindable var folder: RecommendationFolder
    let onDelete: () -> Void
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(folder.title)
                        .font(.largeTitle.bold())
                    Text("\(folder.createdAt.formatted(date: .long, time: .omitted)) · ^[\(folder.albums.count) album](inflect: true)")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if folder.albums.isEmpty {
                    Text("No albums found in this video.")
                        .foregroundStyle(.secondary)
                }
                ForEach(folder.sortedAlbums.filter { !$0.isMention }) { AlbumRow(album: $0) }
            }

            // Albums named only to describe a recommendation ("for fans of …") or in passing.
            let mentions = folder.sortedAlbums.filter(\.isMention)
            if !mentions.isEmpty {
                Section("Also mentioned") {
                    ForEach(mentions) { AlbumRow(album: $0) }
                }
            }

            if let note = folder.speechNote {
                Section {
                    Label("Only used on-screen text. \(note)", systemImage: "waveform.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                DisclosureGroup("What the app heard and saw") {
                    Text(folder.transcript.isEmpty ? "(no speech)" : folder.transcript)
                        .font(.footnote)
                    Text(folder.onScreenText.joined(separator: "\n"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !folder.timings.isEmpty {
                        Text((folder.foundBy.isEmpty ? "" : "Found by \(folder.foundBy)\n") + folder.timings)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu("More", systemImage: "ellipsis") {
                Button("Rename", systemImage: "pencil") {
                    newTitle = folder.title
                    renaming = true
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
            }
        }
        .confirmationDialog("Delete this folder?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Its albums will be removed from Album Finder.")
        }
        .alert("Rename folder", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { folder.title = title }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct AlbumRow: View {
    let album: SavedAlbum

    var body: some View {
        Link(destination: album.link) {
            HStack(spacing: 14) {
                Artwork(url: album.artworkURL)
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(.headline)
                        .lineLimit(2)
                    if !album.artist.isEmpty {
                        Text(album.artist)
                            .foregroundStyle(.secondary)
                    }
                    // Mentions have their own section, so they need no label.
                    if let kind = RecommendationKind(rawValue: album.kind), kind != .mention {
                        Text(kind == .song && !album.song.isEmpty ? "Song recommendation: “\(album.song)”" : kind.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.pink)
                    }
                    if !album.summary.isEmpty {
                        Text(album.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if !album.matched {
                        Text("No exact match. Tap to search Apple Music")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if album.coverSeen {
                        Label("Cover seen in video", systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .foregroundStyle(.primary)

                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.pink)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        // Without this the whole row is tinted like a link.
        .buttonStyle(.plain)
    }
}
