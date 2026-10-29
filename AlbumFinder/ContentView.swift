import PhotosUI
import SwiftData
import SwiftUI
import Vision

/// What was heard and seen in a video, kept so a run that stops at Claude can carry on without
/// reading the video again.
struct ReadVideo {
    let transcript: String
    let speechNote: String?
    let onScreenText: [String]
    let moments: [ScreenMoment]
    let covers: [FeaturePrintObservation]
    /// How long reading took, to save with the folder.
    let timings: [String]
}

@Observable
final class Finder {
    enum State {
        case idle
        case working(String)
        case failed(String)
        /// Claude couldn't be used, so the user picks whether to retry it or use the on-device model.
        case claudeFailed(String)
    }

    var state = State.idle
    /// The run in progress, so iOS can stop it if it has to.
    var runTask: Task<Void, Never>?
    /// The video of a run that stopped at Claude.
    private var pending: ReadVideo?

    /// Reports a run's progress to the screen and to iOS, and times each step.
    private final class Progress {
        let background: BackgroundRun
        private(set) var timings: [String]
        private var current: (description: String, started: Date)?
        private let show: (String) -> Void

        init(timings: [String] = [], show: @escaping (String) -> Void, onExpire: @escaping @MainActor () -> Void) {
            self.timings = timings
            self.show = show
            background = BackgroundRun(onExpire: onExpire)
        }

        /// Starts a step that covers `start` to `end` of the run; report the step's own progress (0 to 1)
        /// with the returned function, so iOS sees the run moving and doesn't stop it as stalled.
        func step(_ description: String, from start: Double, to end: Double) -> @MainActor (Double) -> Void {
            endStep()
            current = (description, .now)
            show(description)
            background.update(description, done: start)
            return { [background] in background.update(description, done: start + (end - start) * $0) }
        }

        func endStep() {
            if let current {
                timings.append("\(current.description.replacing("…", with: "")) \(Int(Date.now.timeIntervalSince(current.started).rounded())) s")
            }
            current = nil
        }
    }

    private func progress(timings: [String] = []) -> Progress {
        Progress(timings: timings, show: { [weak self] in self?.state = .working($0) }, onExpire: { [weak self] in self?.runTask?.cancel() })
    }

    /// Analyzes the video and saves the result as a new folder, using Claude or the on-device model.
    func run(_ item: PhotosPickerItem, claude: Bool, in context: ModelContext) async -> RecommendationFolder? {
        await BackgroundRun.requestNotificationPermission()
        let progress = progress()
        do {
            _ = progress.step("Loading video…", from: 0, to: 0.05)
            guard let movie = try await item.loadTransferable(type: Movie.self) else {
                state = .failed("Couldn't load that video.")
                return nil
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }

            let reading = progress.step("Listening and reading the screen…", from: 0.05, to: 0.4)
            async let speech = VideoReader.transcript(of: movie.url)
            async let screen = VideoReader.screen(of: movie.url, onProgress: reading)
            let (onScreenText, moments, covers) = try await screen
            // Keep going with just the on-screen text if transcription isn't possible.
            var transcript = ""
            var speechNote: String?
            do {
                transcript = try await speech
            } catch {
                speechNote = error.localizedDescription
            }
            progress.endStep()
            let video = ReadVideo(
                transcript: transcript, speechNote: speechNote, onScreenText: onScreenText,
                moments: moments, covers: covers, timings: progress.timings)
            return try await analyze(video, claude: claude, progress: progress, in: context)
        } catch {
            fail(error, progress: progress)
            return nil
        }
    }

    /// Carries on a run that stopped at Claude, with Claude again or with the on-device model.
    func resume(claude: Bool, in context: ModelContext, onSaved: @escaping (RecommendationFolder) -> Void) {
        guard let video = pending else { return }
        pending = nil
        let progress = progress(timings: video.timings)
        runTask = Task {
            do {
                if let folder = try await analyze(video, claude: claude, progress: progress, in: context) {
                    onSaved(folder)
                }
            } catch {
                fail(error, progress: progress)
            }
        }
    }

    func dropPending() {
        pending = nil
        state = .idle
    }

    private func fail(_ error: any Error, progress: Progress) {
        let stopped = error is CancellationError || (error as? URLError)?.code == .cancelled
        let message = stopped
            ? "iOS stopped the run before it finished. Open Album Finder and try again."
            : error.localizedDescription
        state = .failed(message)
        progress.background.finish(title: "Couldn't find the albums", message: message, success: false)
    }

    /// Finds the albums in what was read from the video, looks them up and saves the folder. Returns nil
    /// when Claude couldn't be used, leaving the video pending for the user to decide.
    private func analyze(
        _ video: ReadVideo, claude: Bool, progress: Progress, in context: ModelContext
    ) async throws -> RecommendationFolder? {
        let (transcript, onScreenText, covers) = (video.transcript, video.onScreenText, video.covers)
        let requestsBefore = await AppleMusicSearch.requestsSent()
        let finding = progress.step("Finding the albums…", from: 0.4, to: 0.5)
        let model = UserDefaults.standard.string(forKey: FinderSettings.modelKey).flatMap(ClaudeExtractor.Model.init) ?? .haiku
        let title: String
        let mentions: [AlbumMention]
        // How the person describes each recommendation; only Claude writes these.
        var descriptions: [AlbumMention: String] = [:]
        if claude {
            do {
                (title, mentions, descriptions) = try await ClaudeExtractor.albums(
                    transcript: transcript, screen: video.moments, model: model, apiKey: APIKeyStore.key, onProgress: finding)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                pending = video
                state = .claudeFailed("\(model.name) couldn't be used: \(error.localizedDescription)")
                progress.background.finish(
                    title: "Claude couldn't be used",
                    message: "Open Album Finder to try again or use the on-device model.", success: false)
                return nil
            }
        } else {
            (title, mentions) = try await AlbumExtractor.albums(transcript: transcript, screen: video.moments, onProgress: finding)
        }
        let lookingUp = progress.step("Looking them up in Apple Music…", from: 0.5, to: 0.85)
        let screenPairs = AlbumExtractor.screenPairs(onScreenText, transcript: transcript)
        let lookups = Double(mentions.count + screenPairs.count)
        // A lookup that still fails after retrying leaves that album unmatched rather than failing the run.
        var matches: [AlbumMatch] = []
        for (index, mention) in mentions.enumerated() {
            if mention.kind == .artist, mention.album.isEmpty {
                let page = try? await AppleMusicSearch.artistPage(named: mention.artist)
                matches.append(AlbumMatch(mention: mention, album: nil, artistPage: page ?? nil))
            } else {
                matches.append((try? await AppleMusicSearch.match(mention)) ?? AlbumMatch(mention: mention, album: nil))
            }
            lookingUp(Double(index + 1) / lookups)
        }
        // The model sometimes skips an album in a long list, so also look up any "Title - Artist"
        // overlay it didn't list, keeping it only if Apple Music has it. Overlay names are clean, so
        // a quick lookup each way round is enough and saves searches.
        var listed = mentions
        for (index, pair) in screenPairs.enumerated() {
            lookingUp(Double(mentions.count + index + 1) / lookups)
            // The model sometimes keeps the transcript's misheard artist ("Lamboth" for the overlay's
            // "Lammoth") and finds nothing, so retry an unmatched title with the overlay's spelling.
            if let earlier = matches.firstIndex(where: {
                $0.album == nil && $0.artistPage == nil
                    && $0.mention.album.lowercased() == pair.album.lowercased()
                    && $0.mention.artist.lowercased() != pair.artist.lowercased()
            }) {
                let mention = AlbumMention(artist: pair.artist, album: pair.album, kind: matches[earlier].mention.kind)
                descriptions[mention] = descriptions[matches[earlier].mention]
                matches[earlier] = (try? await AppleMusicSearch.match(mention, quick: true)) ?? AlbumMatch(mention: mention, album: nil)
                continue
            }
            guard !listed.contains(where: { $0.overlaps(pair) }) else { continue }
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
        let checkingCovers = progress.step("Checking album covers…", from: 0.85, to: 1)
        var results: [(match: AlbumMatch, coverSeen: Bool, kind: RecommendationKind, summary: String)] = []
        for (index, var match) in matches.enumerated() {
            checkingCovers(Double(index) / Double(matches.count))
            var coverSeen = false
            if let album = match.album {
                coverSeen = (try? await CoverMatcher.wasShown(album, in: covers)) ?? false
            } else if match.artistPage == nil, !match.mention.artist.isEmpty,
                      let releases = try? await AppleMusicSearch.releases(by: match.mention.artist),
                      let shown = try? await CoverMatcher.pick(from: releases, shown: covers) {
                // The title didn't match anything, but one of the artist's covers was on screen.
                match = AlbumMatch(mention: match.mention, album: shown)
                coverSeen = true
            }
            // An unmatched entry whose names appear nowhere in the video was made up by the model.
            if match.album == nil, match.artistPage == nil,
               !AlbumExtractor.appears(match.mention, in: transcript + "\n" + onScreenText.joined(separator: "\n")) {
                continue
            }
            // Overlays the safety net adds don't say whether they're a song; a match through one does.
            let kind: RecommendationKind = match.viaSong && match.mention.kind == .album ? .song : match.mention.kind
            // The same album can come up twice under different names: keep it once, as the stronger kind.
            let summary = descriptions[match.mention] ?? ""
            if let earlier = results.firstIndex(where: { AppleMusicSearch.sameRelease($0.match, match) }) {
                let kept = results[earlier]
                if kind.rank < kept.kind.rank {
                    results[earlier] = (kept.match, kept.coverSeen || coverSeen, kind, kept.summary.isEmpty ? summary : kept.summary)
                }
                continue
            }
            results.append((match, coverSeen, kind, summary))
        }
        let albums = results.enumerated().map { index, result in
            SavedAlbum(position: index, match: result.match, coverSeen: result.coverSeen, kind: result.kind, summary: result.summary)
        }

        let folder = RecommendationFolder(
            title: title, transcript: transcript, onScreenText: onScreenText, speechNote: video.speechNote, albums: albums)
        progress.endStep()
        let requests = await AppleMusicSearch.requestsSent() - requestsBefore
        folder.timings = (progress.timings + ["\(requests) Apple Music requests"]).joined(separator: "\n")
        folder.foundBy = claude ? model.name : "the on-device model"
        context.insert(folder)
        state = .idle
        progress.background.finish(
            title: "Albums found", message: "\(albums.count) album\(albums.count == 1 ? "" : "s") from “\(title)”", success: true)
        return folder
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RecommendationFolder.createdAt, order: .reverse) private var folders: [RecommendationFolder]
    @State private var finder = Finder()
    @State private var selection: PhotosPickerItem?
    @State private var path: [RecommendationFolder] = []
    @State private var showingSettings = false
    @AppStorage(FinderSettings.useClaudeKey) private var useClaude = false

    /// Shown while a run waits for the user to decide what to do after Claude failed. Each button
    /// moves the run on, so closing the alert itself changes nothing.
    private var claudeFailed: Binding<Bool> {
        Binding(get: { if case .claudeFailed = finder.state { true } else { false } }, set: { _ in })
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    FindCard(state: finder.state, selection: $selection, useClaude: $useClaude)
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
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .alert("Claude couldn't be used", isPresented: claudeFailed) {
                Button("Try again") { finder.resume(claude: true, in: context) { path.append($0) } }
                Button("Use on-device model") { finder.resume(claude: false, in: context) { path.append($0) } }
                Button("Cancel", role: .cancel) { finder.dropPending() }
            } message: {
                if case .claudeFailed(let reason) = finder.state { Text(reason) }
            }
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
                    if let folder = await finder.run(item, claude: useClaude, in: context) {
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
    @Binding var useClaude: Bool

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
            case .idle, .failed, .claudeFailed:
                Picker("Find albums with", selection: $useClaude) {
                    Text("On device").tag(false)
                    Text("Claude").tag(true)
                }
                .pickerStyle(.segmented)
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
