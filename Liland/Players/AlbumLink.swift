import Foundation

/// Finds the link that opens the playing song's album inside its app.
enum AlbumLink {
    case spotify
    case appleMusic

    /// Long enough for a quick answer, short enough that a click isn't left hanging.
    private static let timeout: TimeInterval = 4

    /// Calls `completion` on the main queue, with nil when the album can't be found.
    func url(for track: NowPlayingTrack, completion: @escaping (URL?) -> Void) {
        let done: (URL?) -> Void = { url in DispatchQueue.main.async { completion(url) } }
        switch self {
        case .spotify: Self.spotifyAlbum(for: track, completion: done)
        case .appleMusic: Self.appleMusicAlbum(for: track, completion: done)
        }
    }

    /// Spotify's AppleScript doesn't name the album, but the song's public page links to it.
    /// Local files and podcasts have no such page.
    private static func spotifyAlbum(for track: NowPlayingTrack, completion: @escaping (URL?) -> Void) {
        let prefix = "spotify:track:"
        guard track.id.hasPrefix(prefix),
              let page = URL(string: "https://open.spotify.com/track/\(track.id.dropFirst(prefix.count))")
        else { return completion(nil) }
        fetch(page) { data in
            let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // The link may name a language, e.g. open.spotify.com/intl-pt/album/<id>.
            let albumID = html.firstMatch(of: #/name="music:album" content="[^"]*/album/(\w+)"/#)?.1
            completion(albumID.flatMap { URL(string: "spotify:album:\($0)") })
        }
    }

    /// Looks the song up in the Apple Music catalog of the user's country. The music://
    /// scheme opens the album in the Music app rather than in the browser. Songs that are
    /// only in the user's library, such as imported CDs, aren't found.
    private static func appleMusicAlbum(for track: NowPlayingTrack, completion: @escaping (URL?) -> Void) {
        guard !track.title.isEmpty else { return completion(nil) }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(track.title) \(track.artist)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components?.url else { return completion(nil) }
        fetch(url) { data in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let results = json?["results"] as? [[String: Any]] ?? []
            // The same song is on several albums (the original, a remaster, a compilation…).
            let byArtist = results.filter { result in
                guard let artist = result["artistName"] as? String else { return false }
                return track.artist.isEmpty || track.artist.localizedCaseInsensitiveContains(artist)
                    || artist.localizedCaseInsensitiveContains(track.artist)
            }
            let match = byArtist.first { ($0["collectionName"] as? String)?.caseInsensitiveCompare(track.album) == .orderedSame }
                ?? byArtist.first
            // The link points at the song within the album; without its query it's the album itself.
            guard let link = match?["collectionViewUrl"] as? String,
                  var album = URLComponents(string: link)
            else { return completion(nil) }
            album.scheme = "music"
            album.query = nil
            completion(album.url)
        }
    }

    private static func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        let request = URLRequest(url: url, timeoutInterval: timeout)
        URLSession.shared.dataTask(with: request) { data, _, _ in completion(data) }.resume()
    }
}
