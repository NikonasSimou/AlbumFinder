import Foundation
import SwiftData

/// One analyzed video: its title, when it was analyzed, and the albums found in it.
@Model
final class RecommendationFolder {
    var title: String
    var createdAt: Date
    var transcript: String
    var onScreenText: [String]
    /// Why only on-screen text was used, when transcription failed.
    var speechNote: String?
    /// How long each step of the run took, one per line; empty for folders saved before timing existed.
    var timings: String = ""
    /// Which model picked out the albums, e.g. "Claude Haiku 5.5"; empty for older folders.
    var foundBy: String = ""
    @Relationship(deleteRule: .cascade) var albums: [SavedAlbum]

    init(title: String, transcript: String, onScreenText: [String], speechNote: String?, albums: [SavedAlbum]) {
        self.title = title
        self.createdAt = .now
        self.transcript = transcript
        self.onScreenText = onScreenText
        self.speechNote = speechNote
        self.albums = albums
    }

    /// The folder's name: the video's title plus the date it was analyzed.
    var name: String {
        "\(title) – \(createdAt.formatted(date: .abbreviated, time: .omitted))"
    }

    var sortedAlbums: [SavedAlbum] {
        albums.sorted { $0.position < $1.position }
    }
}

@Model
final class SavedAlbum {
    var position: Int
    var artist: String
    var title: String
    var link: URL
    var artworkURL: URL?
    /// false when Apple Music had no confident match and `link` is a search instead.
    var matched: Bool
    /// Whether this album's cover appeared in the video.
    var coverSeen: Bool = false
    /// A `RecommendationKind` raw value; empty for folders saved before kinds existed.
    var kind: String = ""
    /// For a song recommendation, the song (`title` is its album).
    var song: String = ""
    /// How the person in the video describes this recommendation; only Claude writes these.
    var summary: String = ""

    init(position: Int, match: AlbumMatch, coverSeen: Bool, kind: RecommendationKind, summary: String) {
        self.position = position
        if match.album == nil, match.artistPage != nil {
            // A band recommendation: the artist is the title, and the link opens their page.
            self.artist = ""
            self.title = match.mention.artist
        } else {
            self.artist = match.album?.artistName ?? match.mention.artist
            self.title = match.album?.collectionName ?? match.mention.album
        }
        self.link = match.link
        self.artworkURL = match.album?.largeArtworkURL
        self.matched = match.album != nil || match.artistPage != nil
        self.coverSeen = coverSeen
        self.kind = kind.rawValue
        self.song = kind == .song ? match.mention.album : ""
        self.summary = summary
    }

    var isMention: Bool { kind == RecommendationKind.mention.rawValue }
}
