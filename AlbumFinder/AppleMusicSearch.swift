import Foundation

nonisolated struct AlbumMatch {
    let mention: AlbumMention
    /// nil when the iTunes catalog had nothing that looked like this album.
    let album: CatalogAlbum?
    /// For a band recommendation: the artist's page.
    var artistPage: URL? = nil
    /// Whether `album` was found through one of its songs, so the mention named a song.
    var viaSong = false

    /// The album or artist page in Apple Music, or an Apple Music search when there was no confident match.
    var link: URL {
        if let album { return album.url }
        if let artistPage { return artistPage }
        var search = URLComponents(string: "https://music.apple.com/search")!
        search.queryItems = [URLQueryItem(name: "term", value: "\(mention.artist) \(mention.album)")]
        return search.url!
    }
}

nonisolated struct CatalogAlbum: Decodable {
    let artistName: String
    let collectionName: String
    let collectionViewUrl: URL
    let artworkUrl100: URL?
    /// Set on song results: the track, which `collectionName` is the album of.
    let trackName: String?

    /// The API returns 100px artwork; the same URL serves larger sizes.
    var largeArtworkURL: URL? {
        artworkUrl100.flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: "100x100bb", with: "600x600bb")) }
    }

    /// Song results link to their album with "?i=<track>" appended; drop it to open the album itself.
    var url: URL {
        var components = URLComponents(url: collectionViewUrl, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url ?? collectionViewUrl
    }
}

/// Looks albums up with the public iTunes Search and Lookup APIs (no key or developer account needed).
/// Apple allows only about 20 requests a minute, so each request runs only if the ones before it
/// didn't settle the match.
nonisolated enum AppleMusicSearch {
    private struct Artist: Decodable {
        let artistId: Int
        let artistName: String
        let artistLinkUrl: URL?
    }

    /// Whether two matches are the same release: the same page, or the same title by a shared artist.
    /// Apple sometimes lists one album twice under different credits (Promises, with and without Sam Shepherd).
    static func sameRelease(_ a: AlbumMatch, _ b: AlbumMatch) -> Bool {
        if a.link == b.link { return true }
        guard let first = a.album, let second = b.album else { return false }
        return similarity(first.collectionName, second.collectionName) == 2 && artistSimilarity(first, second.artistName) > 0
    }

    /// The Apple Music page of the artist closest to that name.
    static func artistPage(named name: String) async throws -> URL? {
        try await artists(named: name).first?.artistLinkUrl
    }

    /// With `quick`, the last-resort search by title alone is skipped.
    static func match(_ mention: AlbumMention, quick: Bool = false) async throws -> AlbumMatch {
        // The artist's full catalog has albums the search index misses (e.g. Death Grips' "The Money
        // Store"), and every album of theirs in the video reuses it.
        // Several artists can share a name (Noname and four "No Name"s), so try each match in turn.
        var catalogs: [[CatalogAlbum]] = []
        for artist in try await artists(named: mention.artist) {
            let catalog = try await releases(of: artist)
            catalogs.append(catalog)
            if let best = best(in: catalog, for: mention) {
                return AlbumMatch(mention: mention, album: albumInstead(of: best, in: catalogs))
            }
        }
        // Recommendations are often songs shown with their album's cover ("Cicada Season" is on
        // Fuubutsushi's "Fuubutsushi"), so a song by the artist links to its album. Song results also
        // find releases whose artist is unknown or named differently.
        let term = "\(mention.artist) \(mention.album)".trimmingCharacters(in: .whitespaces)
        if let found = best(in: try await search(term, entity: "song", limit: 25), for: mention, matchingTracks: true) {
            let best = albumInstead(of: found, in: catalogs)
            return AlbumMatch(mention: mention, album: best, viaSong: similarity(best.collectionName, mention.album) == 0)
        }
        // Only now accept a loosely similar title within the artist's releases, which catches foreign
        // titles heard as English words ("Desire Disaster" for "Désir des astres"). Before checking
        // songs, the song "Marginalia #60" would have matched the single "Marginalia #204".
        for catalog in catalogs {
            if let best = best(in: catalog, for: mention, looseTitles: true) {
                return AlbumMatch(mention: mention, album: albumInstead(of: best, in: catalogs))
            }
        }
        if quick {
            return AlbumMatch(mention: mention, album: nil)
        }
        // Search isn't forgiving about spelling, so a misheard artist ("Poppy Akroyd" for Ackroyd)
        // finds nothing. Searching the title alone still turns it up, and scoring tolerates the artist.
        let byTitle = try await search(mention.album, entity: "song", limit: 50)
        let found = best(in: byTitle, for: mention, lastResort: true).map { albumInstead(of: $0, in: catalogs) }
        return AlbumMatch(mention: mention, album: found, viaSong: found.map { similarity($0.collectionName, mention.album) == 0 } ?? false)
    }

    /// A single often shares its title with the album it comes from ("Come In, Thank You - Single" and
    /// the album "Come In, Thank You"), and the album is what gets recommended.
    private static func albumInstead(of found: CatalogAlbum, in catalogs: [[CatalogAlbum]]) -> CatalogAlbum {
        let suffix = " - Single"
        guard found.collectionName.hasSuffix(suffix) else { return found }
        let title = String(found.collectionName.dropLast(suffix.count))
        return catalogs.joined().first {
            !$0.collectionName.hasSuffix(suffix) && similarity($0.collectionName, title) == 2
        } ?? found
    }

    /// The artist's one album, if they have only one besides singles and EPs.
    static func onlyAlbum(in releases: [CatalogAlbum]) -> CatalogAlbum? {
        let albums = releases.filter { !$0.collectionName.hasSuffix(" - Single") && !$0.collectionName.hasSuffix(" - EP") }
        return albums.count == 1 ? albums[0] : nil
    }

    /// The releases of the artist closest to that name, or none if Apple Music has no such artist.
    static func releases(by artist: String) async throws -> [CatalogAlbum] {
        guard let closest = try await artists(named: artist).first else { return [] }
        return try await releases(of: closest)
    }

    /// Artists with that name, exact ones first, then misheard ones ("Gaspar Klaus" for Gaspar Claus).
    private static func artists(named name: String) async throws -> [Artist] {
        guard !name.isEmpty else { return [] }
        let found = try await fetch(Artist.self, "search", ["term": name, "entity": "musicArtist", "limit": "5"])
        return found.filter { similarity($0.artistName, name) == 2 } + found.filter { similarity($0.artistName, name) == 1 }
    }

    private static func releases(of artist: Artist) async throws -> [CatalogAlbum] {
        try await fetch(CatalogAlbum.self, "lookup", ["id": "\(artist.artistId)", "entity": "album", "limit": "200"])
    }

    /// Search results include tribute albums, karaoke versions and other artists' albums,
    /// so only accept a result whose artist and title both resemble what was mentioned.
    /// On a tie, the earlier result wins: it's ranked higher by Apple.
    private static func best(
        in results: [CatalogAlbum], for mention: AlbumMention,
        matchingTracks: Bool = false, lastResort: Bool = false, looseTitles: Bool = false
    ) -> CatalogAlbum? {
        var best: (album: CatalogAlbum, score: Int)?
        for album in results {
            let score = score(
                album, against: mention, matchingTracks: matchingTracks || lastResort, lastResort: lastResort, looseTitles: looseTitles)
            if score >= 2, score > (best?.score ?? 0) {
                best = (album, score)
            }
        }
        return best?.album
    }

    /// Spaces out network searches. Apple allows about 20 a minute, answers 429 past that, and blocks
    /// the device for a while (403) if it keeps getting too many. So requests go out right away until
    /// 18 have gone out in the last minute, and then each waits for the oldest of those to age out.
    private actor Pacer {
        private static let perMinute = 18
        private var turns: [ContinuousClock.Instant] = []
        private(set) var sent = 0

        func waitForTurn() async throws {
            let now = ContinuousClock.now
            turns.removeAll { $0 < now - .seconds(60) }
            var turn = max(now, turns.last ?? now)
            if turns.count >= Self.perMinute {
                turn = max(turn, turns[turns.count - Self.perMinute] + .seconds(60))
            }
            turns.append(turn)
            sent += 1
            try await Task.sleep(until: turn)
        }
    }

    private static let pacer = Pacer()

    /// How many requests have gone to Apple since the app started (cached answers don't count).
    static func requestsSent() async -> Int {
        await pacer.sent
    }

    /// Lookups mix in other kinds of result (e.g. the artist itself), so skip what doesn't decode.
    private struct Results<Item: Decodable>: Decodable {
        let results: [Item]

        private enum CodingKeys: String, CodingKey { case results }
        private struct Skipped: Decodable {}

        init(from decoder: any Decoder) throws {
            var list = try decoder.container(keyedBy: CodingKeys.self).nestedUnkeyedContainer(forKey: .results)
            var items: [Item] = []
            while !list.isAtEnd {
                if let item = try? list.decode(Item.self) {
                    items.append(item)
                } else {
                    _ = try list.decode(Skipped.self)
                }
            }
            results = items
        }
    }

    private static func search(_ term: String, entity: String, limit: Int) async throws -> [CatalogAlbum] {
        try await fetch(CatalogAlbum.self, "search", ["term": term, "entity": entity, "limit": "\(limit)"])
    }

    private static func fetch<Item: Decodable>(_ item: Item.Type, _ endpoint: String, _ query: [String: String]) async throws -> [Item] {
        var components = URLComponents(string: "https://itunes.apple.com/\(endpoint)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US")]
        let request = URLRequest(url: components.url!)
        // Results are cacheable for a day, and only network requests count against Apple's limit.
        if let cached = URLCache.shared.cachedResponse(for: request) {
            return try JSONDecoder().decode(Results<Item>.self, from: cached.data).results
        }
        for attempt in 1...3 {
            try await pacer.waitForTurn()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return try JSONDecoder().decode(Results<Item>.self, from: data).results
            }
            // 429 means slow down: wait and retry. Anything else (e.g. a 403 block) won't clear soon.
            guard status == 429 else { throw URLError(.badServerResponse) }
            try await Task.sleep(for: .seconds(5 * attempt))
        }
        throw URLError(.resourceUnavailable)
    }

    /// 2 points per field for an exact match, 1 when they're close, and a bonus point when the
    /// title matches word for word, so "Rumours" beats "Rumours (Live)". With no artist, the title
    /// alone decides and Apple's ranking breaks ties.
    /// With `matchingTracks`, a recommended song (e.g. Poppy Ackroyd's "Continuum") matches the album it's
    /// on, scoring below an album of that name. Only after the artist's albums were checked, or "Pink
    /// Moon" would match a compilation with that song.
    /// As a `lastResort`, an exact title of five or more words matches whoever the artist is, since the
    /// person may be named instead of their project (Mark Nelson for Pan•American). Shorter titles aren't
    /// distinctive enough ("Good Kid, Mad City" is also someone else's single).
    /// `looseTitles` accepts titles up to about a third different.
    private static func score(
        _ album: CatalogAlbum, against mention: AlbumMention, matchingTracks: Bool, lastResort: Bool, looseTitles: Bool
    ) -> Int {
        let trackTitle = matchingTracks ? album.trackName.map { min(1, similarity($0, mention.album)) } ?? 0 : 0
        var title = max(similarity(album.collectionName, mention.album), trackTitle)
        if title == 0, looseTitles, isClose(album.collectionName, mention.album, tolerance: 3) {
            title = 1
        }
        var artist = mention.artist.isEmpty ? 1 : artistSimilarity(album, mention.artist)
        if artist == 0, lastResort, title == 2, mention.album.split(separator: " ").count >= 5 {
            artist = 1
        }
        // With the exact title, allow a more misheard artist, e.g. "Cocktail Twins" for "Cocteau Twins".
        if artist == 0, title == 2, isClose(album.artistName, mention.artist, tolerance: 3) {
            artist = 1
        }
        guard artist > 0, title > 0 else { return 0 }
        let verbatim = album.collectionName.lowercased() == mention.album.lowercased() ? 1 : 0
        return artist + title + verbatim
    }

    /// Credits like "Fabiano do Nascimento & Vittor Santos e Orquestra" are compared per artist too, on
    /// both sides ("Pharaoh Sanders & The London Symphony Orchestra" is on Promises).
    private static func artistSimilarity(_ album: CatalogAlbum, _ artist: String) -> Int {
        func names(_ credit: String) -> [String] {
            [credit] + credit.split(separator: #/\s*(?:&|,|\bfeat\.|\bft\.|\bwith\b|\band\b|\be\b|\bx\b)\s*/#).map(String.init)
        }
        let mentioned = names(artist)
        return names(album.artistName).flatMap { credited in mentioned.map { similarity(credited, $0) } }.max() ?? 0
    }

    private static func similarity(_ a: String, _ b: String) -> Int {
        let a = normalized(a), b = normalized(b)
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 2 }
        // Numbers are distinctive: "Marginalia #60" is neither "Marginalia" nor "Marginalia #204".
        guard a.filter(\.isNumber) == b.filter(\.isNumber) else { return 0 }
        // One name inside the other only counts if it's most of it: "clipping" isn't "Grass clippings".
        if (a.contains(b) || b.contains(a)), min(a.count, b.count) * 10 >= max(a.count, b.count) * 6 { return 1 }
        // Tolerate a misheard letter or two, e.g. "Fortet" for "Four Tet".
        return isClose(a, b, tolerance: 5) ? 1 : 0
    }

    /// At most one edit per `tolerance` characters (and at least one) apart, with the same numbers.
    private static func isClose(_ a: String, _ b: String, tolerance: Int) -> Bool {
        let a = normalized(a), b = normalized(b)
        guard !a.isEmpty, !b.isEmpty, a.filter(\.isNumber) == b.filter(\.isNumber) else { return false }
        return editDistance(a, b) <= max(1, min(a.count, b.count) / tolerance)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let b = Array(b)
        var previous = Array(0...b.count)
        for (i, charA) in a.enumerated() {
            var current = [i + 1]
            for (j, charB) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (charA == charB ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Lowercase, drop accents, "(Deluxe Edition)" and " - Single"-style suffixes, a leading "the", and punctuation.
    private static func normalized(_ s: String) -> String {
        var s = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let bracket = s.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            s = String(s[..<bracket])
        }
        for suffix in [" - single", " - ep"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        s = s.filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("the ") { s.removeFirst(4) }
        return s.replacingOccurrences(of: " ", with: "")
    }
}
