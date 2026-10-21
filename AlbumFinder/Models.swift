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

    init(position: Int, match: AlbumMatch, coverSeen: Bool) {
        self.position = position
        self.artist = match.album?.artistName ?? match.mention.artist
        self.title = match.album?.collectionName ?? match.mention.album
        self.link = match.link
        self.artworkURL = match.album?.largeArtworkURL
        self.matched = match.album != nil
        self.coverSeen = coverSeen
    }
}
