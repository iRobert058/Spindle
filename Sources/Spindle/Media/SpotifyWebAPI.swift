import Foundation

/// A playlist as the menu needs it.
struct SpotifyPlaylist: Equatable {
    let id: String
    let name: String
}

/// A playable track, with what the menu shows and what Spotify needs to play it.
struct SpotifyTrack: Equatable {
    let uri: String
    let name: String
    let artist: String
    let album: String
    let artworkURL: URL?
}

/// The few read-only Web API calls the menu uses.
///
/// Every list is paged at 50; this follows `next` until the list ends, and
/// never sends the bearer token to anything but api.spotify.com.
final class SpotifyWebAPI {

    private static let host = "api.spotify.com"
    private static let pageSize = 50
    /// Retry-After can be minutes long. Past this the menu shows an error
    /// rather than sitting on a spinner.
    private static let maxRetryWait: TimeInterval = 5

    private let account: SpotifyAccount
    private let session: URLSession
    /// Spotify renamed a playlist's `/tracks` to `/items`. Remembered once
    /// either answers, so every later playlist costs one request, not two.
    private var playlistItemsPath = "items"

    init(account: SpotifyAccount, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    // MARK: - Calls

    func playlists() async throws -> [SpotifyPlaylist] {
        let pages: [Page<PlaylistObject>] = try await allPages(
            from: "/v1/me/playlists?limit=\(Self.pageSize)"
        )
        return pages.flatMap { $0.items.compactMap(\.value) }.compactMap { playlist in
            guard Self.isSpotifyID(playlist.id) else { return nil }
            return SpotifyPlaylist(id: playlist.id, name: playlist.name)
        }
    }

    /// The account's Liked Songs, newest first as Spotify lists them.
    func savedTracks() async throws -> [SpotifyTrack] {
        let pages: [Page<PlaylistItem>] = try await allPages(
            from: "/v1/me/tracks?limit=\(Self.pageSize)"
        )
        return Self.tracks(from: pages)
    }

    func playlistTracks(id: String) async throws -> [SpotifyTrack] {
        guard Self.isSpotifyID(id) else { return [] }
        do {
            let pages: [Page<PlaylistItem>] = try await allPages(
                from: "/v1/playlists/\(id)/\(playlistItemsPath)?limit=\(Self.pageSize)"
            )
            return Self.tracks(from: pages)
        } catch SpotifyError.http(404) where playlistItemsPath == "items" {
            playlistItemsPath = "tracks"
            return try await playlistTracks(id: id)
        }
    }

    func artwork(at url: URL) async -> Data? {
        // Covers come off Spotify's image CDN and need no token.
        guard url.scheme == "https",
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Decoding

    /// Episodes, local files and tracks removed from the catalogue come back in
    /// the same lists. None of them can be played by URI, so they are dropped.
    static func tracks(from pages: [Page<PlaylistItem>]) -> [SpotifyTrack] {
        pages.flatMap { $0.items.compactMap(\.value) }.compactMap { item in
            guard let track = item.item ?? item.track,
                  track.type ?? "track" == "track",
                  track.isLocal != true,
                  isPlayableURI(track.uri) else { return nil }
            return SpotifyTrack(
                uri: track.uri,
                name: track.name,
                artist: (track.artists ?? []).map(\.name).joined(separator: ", "),
                album: track.album?.name ?? "",
                artworkURL: bestImage(track.album?.images ?? [])
            )
        }
    }

    /// The smallest cover that still fills the widget's screen at 2x. Spotify
    /// lists them largest first, typically 640, 300 and 64 pixels.
    static func bestImage(_ images: [Image]) -> URL? {
        let usable = images.filter { ($0.width ?? 0) >= 300 }
        let pick = usable.min { ($0.width ?? 0) < ($1.width ?? 0) } ?? images.first
        return pick.flatMap { URL(string: $0.url) }
    }

    /// Spotify IDs are base62. Checked before an ID goes into a URL path.
    static func isSpotifyID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// URIs are quoted into AppleScript source to play them, so only the two
    /// shapes the menu produces are ever allowed through.
    static func isPlayableURI(_ uri: String) -> Bool {
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify",
              parts[1] == "track" || parts[1] == "playlist" else { return false }
        return isSpotifyID(String(parts[2]))
    }

    // MARK: - Transport

    private func allPages<Item: Decodable>(from path: String) async throws -> [Page<Item>] {
        var pages: [Page<Item>] = []
        var next = URL(string: "https://\(Self.host)\(path)")
        while let url = next {
            try Task.checkCancellation()
            let page: Page<Item> = try await get(url)
            pages.append(page)
            next = page.next.flatMap(URL.init(string:)).flatMap { $0.host == Self.host ? $0 : nil }
        }
        return pages
    }

    private func get<T: Decodable>(_ url: URL, attempt: Int = 0) async throws -> T {
        let token = try await account.validAccessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            return try JSONDecoder().decode(T.self, from: data)
        case 401 where attempt == 0:
            await account.invalidateAccessToken()
            return try await get(url, attempt: attempt + 1)
        case 429 where attempt < 3:
            let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 1
            guard wait <= Self.maxRetryWait else { throw SpotifyError.http(429) }
            try await Task.sleep(for: .seconds(max(wait, 0.5)))
            return try await get(url, attempt: attempt + 1)
        case let status:
            throw SpotifyError.http(status)
        }
    }

    // MARK: - Wire types

    struct Page<Item: Decodable>: Decodable {
        let items: [Lossy<Item>]
        let next: String?
    }

    /// One malformed entry — a null, an episode, a shape we have not seen —
    /// drops that entry rather than the whole list.
    struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Value.self)
        }
    }

    struct PlaylistObject: Decodable {
        let id: String
        let name: String
    }

    /// A playlist entry or a saved track. Playlists moved the object from
    /// `track` to `item`; both are read.
    struct PlaylistItem: Decodable {
        let track: TrackObject?
        let item: TrackObject?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            track = try? container.decodeIfPresent(TrackObject.self, forKey: .track)
            item = try? container.decodeIfPresent(TrackObject.self, forKey: .item)
        }

        enum CodingKeys: String, CodingKey { case track, item }
    }

    struct TrackObject: Decodable {
        let uri: String
        let name: String
        let type: String?
        let isLocal: Bool?
        let artists: [Named]?
        let album: Album?

        enum CodingKeys: String, CodingKey {
            case uri, name, type, artists, album
            case isLocal = "is_local"
        }
    }

    struct Named: Decodable {
        let name: String
    }

    struct Album: Decodable {
        let name: String
        let images: [Image]?
    }

    struct Image: Decodable, Equatable {
        let url: String
        let width: Int?
    }
}
