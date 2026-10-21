import PhotosUI
import SwiftData
import SwiftUI

@Observable
final class Finder {
    enum State {
        case idle
        case working(String)
        case failed(String)
    }

    var state = State.idle
    /// The run in progress, so iOS can stop it if it has to.
    var runTask: Task<Void, Never>?

    /// Analyzes the video and saves the result as a new folder.
    func run(_ item: PhotosPickerItem, in context: ModelContext) async -> RecommendationFolder? {
        await BackgroundRun.requestNotificationPermission()
        let background = BackgroundRun { [weak self] in self?.runTask?.cancel() }
        func step(_ number: Int64, _ description: String) {
            state = .working(description)
            background.step(number, description)
        }
        do {
            step(0, "Loading video…")
            guard let movie = try await item.loadTransferable(type: Movie.self) else {
                state = .failed("Couldn't load that video.")
                return nil
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }

            step(1, "Listening and reading the screen…")
            async let speech = VideoReader.transcript(of: movie.url)
            async let screen = VideoReader.screen(of: movie.url)
            let (onScreenText, covers) = try await screen
            // Keep going with just the on-screen text if transcription isn't possible.
            var transcript = ""
            var speechNote: String?
            do {
                transcript = try await speech
            } catch {
                speechNote = error.localizedDescription
            }

            step(2, "Finding the albums…")
            let (title, mentions) = try await AlbumExtractor.albums(transcript: transcript, onScreenText: onScreenText)

            step(3, "Looking them up in Apple Music…")
            // A lookup that still fails after retrying leaves that album unmatched rather than failing the run.
            var matches: [AlbumMatch] = []
            for mention in mentions {
                matches.append((try? await AppleMusicSearch.match(mention)) ?? AlbumMatch(mention: mention, album: nil))
            }
            // The model sometimes skips an album in a long list, so also look up any "Title - Artist"
            // overlay it didn't list, keeping it only if Apple Music has it. Overlay names are clean, so
            // a quick lookup each way round is enough and saves searches.
            let screenPairs = AlbumExtractor.screenPairs(onScreenText, transcript: transcript)
            var listed = mentions
            for pair in screenPairs where !listed.contains(where: { $0.overlaps(pair) }) {
                var match = (try? await AppleMusicSearch.match(pair, quick: true)) ?? AlbumMatch(mention: pair, album: nil)
                if match.album == nil,
                   let swapped = try? await AppleMusicSearch.match(AlbumMention(artist: pair.album, album: pair.artist), quick: true) {
                    match = swapped
                }
                if match.album != nil {
                    matches.append(match)
                    listed.append(pair)
                }
            }

            // Covers are extra evidence, so a failed download or comparison never fails the run.
            step(4, "Checking album covers…")
            var albums: [SavedAlbum] = []
            for var match in matches {
                var coverSeen = false
                if let album = match.album {
                    coverSeen = (try? await CoverMatcher.wasShown(album, in: covers)) ?? false
                } else if !match.mention.artist.isEmpty,
                          let releases = try? await AppleMusicSearch.releases(by: match.mention.artist),
                          let shown = try? await CoverMatcher.pick(from: releases, shown: covers) {
                    // The title didn't match anything, but one of the artist's covers was on screen.
                    match = AlbumMatch(mention: match.mention, album: shown)
                    coverSeen = true
                }
                // An unmatched entry whose names appear nowhere in the video was made up by the model.
                if match.album == nil,
                   !AlbumExtractor.appears(match.mention, in: transcript + "\n" + onScreenText.joined(separator: "\n")) {
                    continue
                }
                albums.append(SavedAlbum(position: albums.count, match: match, coverSeen: coverSeen))
            }

            let folder = RecommendationFolder(
                title: title, transcript: transcript, onScreenText: onScreenText, speechNote: speechNote, albums: albums)
            context.insert(folder)
            state = .idle
            background.finish(title: "Albums found", message: "\(albums.count) album\(albums.count == 1 ? "" : "s") from “\(title)”", success: true)
            return folder
        } catch {
            let message = error is CancellationError
                ? "iOS stopped the run before it finished. Open Album Finder and try again."
                : error.localizedDescription
            state = .failed(message)
            background.finish(title: "Couldn't find the albums", message: message, success: false)
            return nil
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecommendationFolder.createdAt, order: .reverse) private var folders: [RecommendationFolder]
    @State private var finder = Finder()
    @State private var selection: PhotosPickerItem?
    @State private var path: [RecommendationFolder] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    FindCard(state: finder.state, selection: $selection)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if folders.isEmpty {
                    ContentUnavailableView(
                        "No recommendations yet", systemImage: "square.stack",
                        description: Text("Albums from every video you analyze are saved here."))
                        .listRowBackground(Color.clear)
                } else {
                    Section("Past recommendations") {
                        ForEach(folders) { folder in
                            NavigationLink(value: folder) {
                                FolderRow(folder: folder)
                            }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    context.delete(folder)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                context.delete(folders[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Album Finder")
            .navigationDestination(for: RecommendationFolder.self) { folder in
                FolderDetailView(folder: folder) {
                    // Leave the folder's screen before deleting what it shows.
                    path.removeAll { $0 == folder }
                    context.delete(folder)
                }
            }
            .onChange(of: selection) { _, item in
                guard let item else { return }
                selection = nil
                finder.runTask = Task {
                    if let folder = await finder.run(item, in: context) {
                        path.append(folder)
                    }
                }
            }
        }
    }
}

/// The card at the top of the library for analyzing a new video.
struct FindCard: View {
    let state: Finder.State
    @Binding var selection: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.title)
            Text("Find the albums in a video")
                .font(.title2.bold())
            Text("Save a TikTok or Instagram video to Photos, then pick it here.")
                .font(.subheadline)
                .opacity(0.85)

            switch state {
            case .working(let step):
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(step).font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.white.opacity(0.2), in: .capsule)
            case .idle, .failed:
                PhotosPicker(selection: $selection, matching: .videos) {
                    Label("Choose a video", systemImage: "video.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.pink)
                        .background(.white, in: .capsule)
                }
            }

            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 24))
    }
}

struct FolderRow: View {
    let folder: RecommendationFolder

    var body: some View {
        HStack(spacing: 14) {
            ArtworkMosaic(urls: folder.sortedAlbums.prefix(4).map(\.artworkURL))
                .frame(width: 60, height: 60)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(folder.createdAt.formatted(date: .abbreviated, time: .omitted)) · ^[\(folder.albums.count) album](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Up to four album covers in a 2×2 grid, like a playlist cover.
struct ArtworkMosaic: View {
    let urls: [URL?]

    var body: some View {
        if urls.count < 4 {
            Artwork(url: urls.first ?? nil)
        } else {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Artwork(url: urls[0])
                    Artwork(url: urls[1])
                }
                GridRow {
                    Artwork(url: urls[2])
                    Artwork(url: urls[3])
                }
            }
        }
    }
}

struct Artwork: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.secondary.opacity(0.15)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
        .clipped()
    }
}
