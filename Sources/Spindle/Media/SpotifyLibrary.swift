import Foundation

/// Browses Spotify through the Web API and plays through the Spotify app.
///
/// The menu and the widget's queue address everything by one-based position,
/// the way Music does. Spotify addresses by URI, so this keeps the lists it
/// last fetched and translates a position back into a URI when asked to play.
/// Positions are only handed out from those lists, so they always resolve.
///
/// Playback goes over AppleScript to the local app, not the Web API: the Web
/// API's player needs Premium and an active device, AppleScript needs neither.
/// Called on the main thread, and answers on it.
final class SpotifyLibrary: MusicLibraryProviding {

    private enum Container: Hashable {
        case playlist(Int)
        case liked
    }

    private let api: SpotifyWebAPI
    private let isConnected: () -> Bool
    private let queue = DispatchQueue(label: "nl.jopmors.spindle.spotify-playback")
    private var playlistsByIndex: [Int: SpotifyPlaylist] = [:]
    private var tracksByContainer: [Container: [SpotifyTrack]] = [:]

    init(api: SpotifyWebAPI, isConnected: @escaping () -> Bool) {
        self.api = api
        self.isConnected = isConnected
    }

    var displayName: String { "Spotify" }

    /// Liked Songs has no URI the app can be told to play from the top, so
    /// "Play All" there runs through the widget's own queue instead.
    var playsWholeLibrary: Bool { false }

    // MARK: - Reads

    func playlists(completion: @escaping (Result<[LibraryPlaylist], MusicLibraryError>) -> Void) {
        load(completion: completion) { [api] in try await api.playlists() } map: { playlists in
            self.playlistsByIndex = [:]
            return playlists.enumerated().map { offset, playlist in
                self.playlistsByIndex[offset + 1] = playlist
                return LibraryPlaylist(index: offset + 1, name: playlist.name)
            }
        }
    }

    /// A playlist's tracks, or Liked Songs when `playlistIndex` is nil. Liked
    /// Songs is what Artists, Albums and Songs group, as the whole library does
    /// for Music.
    func tracks(
        playlistIndex: Int?,
        completion: @escaping (Result<[LibraryTrack], MusicLibraryError>) -> Void
    ) {
        let container: Container
        let fetch: () async throws -> [SpotifyTrack]
        if let playlistIndex {
            guard let playlist = playlistsByIndex[playlistIndex] else {
                completion(.failure(.failed("Playlist not found")))
                return
            }
            container = .playlist(playlistIndex)
            fetch = { [api] in try await api.playlistTracks(id: playlist.id) }
        } else {
            container = .liked
            fetch = { [api] in try await api.savedTracks() }
        }
        load(completion: completion, fetch: fetch) { tracks in
            self.tracksByContainer[container] = tracks
            return tracks.enumerated().map { offset, track in
                LibraryTrack(
                    index: offset + 1, name: track.name, artist: track.artist, album: track.album
                )
            }
        }
    }

    func artwork(playlistIndex: Int?, trackIndex: Int, completion: @escaping (Data?) -> Void) {
        guard let url = track(trackIndex, in: container(for: playlistIndex))?.artworkURL else {
            completion(nil)
            return
        }
        Task { @MainActor [api] in
            completion(await api.artwork(at: url))
        }
    }

    // MARK: - Playback

    /// One track on its own. Continuing through the list is the widget queue's
    /// job, exactly as with Music, so shuffle and repeat mean the same thing
    /// whichever app is playing.
    func play(playlistIndex: Int, trackIndex: Int, completion: ((MusicLibraryError?) -> Void)?) {
        play(uri: track(trackIndex, in: .playlist(playlistIndex))?.uri, completion: completion)
    }

    func playFromLibrary(trackIndex: Int, completion: ((MusicLibraryError?) -> Void)?) {
        play(uri: track(trackIndex, in: .liked)?.uri, completion: completion)
    }

    /// A playlist goes to Spotify whole, so Spotify owns the queue from there.
    func playAll(playlistIndex: Int?, completion: ((MusicLibraryError?) -> Void)?) {
        let uri = playlistIndex.flatMap { playlistsByIndex[$0] }.map { "spotify:playlist:\($0.id)" }
        play(uri: uri, completion: completion)
    }

    private func play(uri: String?, completion: ((MusicLibraryError?) -> Void)?) {
        // Every URI reaching AppleScript source has been checked to be
        // `spotify:<kind>:<base62>`, so there is nothing in it to escape.
        guard let uri, SpotifyWebAPI.isPlayableURI(uri) else {
            completion?(.failed("Nothing to play"))
            return
        }
        let source = "tell application \"Spotify\" to play track \"\(uri)\""
        queue.async {
            let error = Self.execute(source)
            DispatchQueue.main.async { completion?(error) }
        }
    }

    // MARK: - Plumbing

    private func container(for playlistIndex: Int?) -> Container {
        playlistIndex.map(Container.playlist) ?? .liked
    }

    private func track(_ index: Int, in container: Container) -> SpotifyTrack? {
        guard let tracks = tracksByContainer[container], tracks.indices.contains(index - 1) else {
            return nil
        }
        return tracks[index - 1]
    }

    private func load<Fetched, Output>(
        completion: @escaping (Result<Output, MusicLibraryError>) -> Void,
        fetch: @escaping () async throws -> Fetched,
        map: @escaping (Fetched) -> Output
    ) {
        guard isConnected() else {
            completion(.failure(.spotifyNotConnected))
            return
        }
        Task { @MainActor in
            do {
                completion(.success(map(try await fetch())))
            } catch {
                completion(.failure(Self.libraryError(from: error)))
            }
        }
    }

    private static func libraryError(from error: Error) -> MusicLibraryError {
        switch error {
        case SpotifyError.notConnected:
            return .spotifyNotConnected
        case SpotifyError.http(429):
            return .failed("Spotify is busy, try again")
        case SpotifyError.http:
            return .failed("Spotify is unavailable")
        case let error as URLError where error.code == .notConnectedToInternet:
            return .failed("No internet connection")
        default:
            return .failed("Could not reach Spotify")
        }
    }

    private static func execute(_ source: String) -> MusicLibraryError? {
        guard let script = NSAppleScript(source: source) else {
            return .failed("Could not compile the command")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        switch code {
        case -1743, -1744: return .spotifyNotAuthorised
        case -600, -609, -1728: return .failed("Spotify is unavailable")
        default: return .failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "Spotify failed")
        }
    }
}
