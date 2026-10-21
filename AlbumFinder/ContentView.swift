import PhotosUI
import SwiftUI

@Observable
final class Finder {
    enum State {
        case idle
        case working(String)
        case done([AlbumMatch])
        case failed(String)
    }

    var state = State.idle
    var transcript = ""
    var onScreenText: [String] = []

    func run(_ item: PhotosPickerItem) async {
        transcript = ""
        onScreenText = []
        do {
            state = .working("Loading video…")
            guard let movie = try await item.loadTransferable(type: Movie.self) else {
                state = .failed("Couldn't load that video.")
                return
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }

            state = .working("Listening and reading the screen…")
            async let speech = VideoReader.transcript(of: movie.url)
            async let screen = VideoReader.onScreenText(of: movie.url)
            (transcript, onScreenText) = try await (speech, screen)

            state = .working("Finding the albums…")
            let mentions = try await AlbumExtractor.albums(transcript: transcript, onScreenText: onScreenText)

            state = .working("Looking them up in Apple Music…")
            var matches: [AlbumMatch] = []
            for mention in mentions {
                matches.append(try await AppleMusicSearch.match(mention))
            }
            state = .done(matches)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct ContentView: View {
    @State private var finder = Finder()
    @State private var selection: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $selection, matching: .videos) {
                        Label("Choose a video", systemImage: "video.badge.plus")
                    }
                } footer: {
                    Text("Save the TikTok or Instagram video to Photos first, then pick it here.")
                }

                switch finder.state {
                case .idle:
                    EmptyView()
                case .working(let step):
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(step).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                case .done(let matches) where matches.isEmpty:
                    Text("No albums found in this video.").foregroundStyle(.secondary)
                case .done(let matches):
                    Section("Albums") {
                        ForEach(matches) { AlbumRow(match: $0) }
                    }
                }

                if !finder.transcript.isEmpty || !finder.onScreenText.isEmpty {
                    Section {
                        DisclosureGroup("What the app heard and saw") {
                            Text(finder.transcript.isEmpty ? "(no speech)" : finder.transcript)
                                .font(.footnote)
                            Text(finder.onScreenText.joined(separator: "\n"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Album Finder")
            .onChange(of: selection) { _, item in
                guard let item else { return }
                Task { await finder.run(item) }
            }
        }
    }
}

struct AlbumRow: View {
    let match: AlbumMatch

    var body: some View {
        Link(destination: match.link) {
            HStack(spacing: 12) {
                AsyncImage(url: match.album?.artworkUrl100) { image in
                    image.resizable()
                } placeholder: {
                    Color.secondary.opacity(0.2)
                        .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
                }
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(match.album?.collectionName ?? match.mention.album)
                        .font(.headline)
                    Text(match.album?.artistName ?? match.mention.artist)
                        .foregroundStyle(.secondary)
                    if match.album == nil {
                        Text("No exact match. Tap to search Apple Music")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }
}
