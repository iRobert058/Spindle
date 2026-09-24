import Foundation

/// Points the menu at whichever player is actually in use.
///
/// The widget reads now-playing from every app, so a menu that could only ever
/// browse Music was wrong for anyone listening in Spotify. This follows the app
/// the adapter last saw owning the audio, and falls back to Music when that is
/// anything else, or when Spotify has not been connected in Settings — nobody
/// who never set Spotify up loses the Music menu they had.
///
/// The choice is made when the menu opens and held until it opens again. Rows
/// and the widget's queue address tracks by position, and a position means
/// nothing in the other library.
final class LibraryRouter: MusicLibraryProviding {

    static let spotifyBundleIdentifier = "com.spotify.client"

    private let music: MusicLibraryProviding
    private let spotify: MusicLibraryProviding
    private let isSpotifyReady: () -> Bool
    private var lastSource: String?
    private(set) var active: MusicLibraryProviding

    init(
        music: MusicLibraryProviding,
        spotify: MusicLibraryProviding,
        isSpotifyReady: @escaping () -> Bool
    ) {
        self.music = music
        self.spotify = spotify
        self.isSpotifyReady = isSpotifyReady
        self.active = music
    }

    var displayName: String { active.displayName }
    var playsWholeLibrary: Bool { active.playsWholeLibrary }

    /// Only remembered here; a player starting mid-browse must not swap the
    /// library out from under the level on screen.
    func follow(sourceBundleID: String) {
        lastSource = sourceBundleID
    }

    func beginBrowsing() {
        let wantsSpotify = lastSource == Self.spotifyBundleIdentifier && isSpotifyReady()
        active = wantsSpotify ? spotify : music
        active.beginBrowsing()
    }

    // MARK: - Forwarding

    func playlists(completion: @escaping (Result<[LibraryPlaylist], MusicLibraryError>) -> Void) {
        active.playlists(completion: completion)
    }

    func tracks(
        playlistIndex: Int?,
        completion: @escaping (Result<[LibraryTrack], MusicLibraryError>) -> Void
    ) {
        active.tracks(playlistIndex: playlistIndex, completion: completion)
    }

    func play(playlistIndex: Int, trackIndex: Int, completion: ((MusicLibraryError?) -> Void)?) {
        active.play(playlistIndex: playlistIndex, trackIndex: trackIndex, completion: completion)
    }

    func playFromLibrary(trackIndex: Int, completion: ((MusicLibraryError?) -> Void)?) {
        active.playFromLibrary(trackIndex: trackIndex, completion: completion)
    }

    func playAll(playlistIndex: Int?, completion: ((MusicLibraryError?) -> Void)?) {
        active.playAll(playlistIndex: playlistIndex, completion: completion)
    }

    func artwork(playlistIndex: Int?, trackIndex: Int, completion: @escaping (Data?) -> Void) {
        active.artwork(playlistIndex: playlistIndex, trackIndex: trackIndex, completion: completion)
    }
}
