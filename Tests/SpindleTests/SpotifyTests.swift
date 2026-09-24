import Foundation
import Testing
@testable import Spindle

/// A stub that names itself and, like Spotify's Liked Songs, may have no
/// container the player can start from the top.
private func namedStub(_ name: String, playsWholeLibrary: Bool = true) -> StubLibrary {
    let library = StubLibrary()
    library.displayName = name
    library.playsWholeLibrary = playsWholeLibrary
    return library
}

@Suite("Library follows the active player")
@MainActor
struct LibraryRouterTests {

    private func makeRouter(spotifyReady: Bool = true) -> (LibraryRouter, StubLibrary, StubLibrary) {
        let music = namedStub("Music")
        let spotify = namedStub("Spotify", playsWholeLibrary: false)
        let router = LibraryRouter(music: music, spotify: spotify, isSpotifyReady: { spotifyReady })
        return (router, music, spotify)
    }

    @Test("Browses Music until Spotify is heard")
    func defaultsToMusic() {
        let (router, _, _) = makeRouter()
        router.beginBrowsing()
        #expect(router.displayName == "Music")
    }

    @Test("Browses Spotify once Spotify owns the audio")
    func followsSpotify() {
        let (router, _, spotify) = makeRouter()
        router.follow(sourceBundleID: LibraryRouter.spotifyBundleIdentifier)
        router.beginBrowsing()

        #expect(router.displayName == "Spotify")
        #expect(router.playsWholeLibrary == false)
        router.playAll(playlistIndex: 2, completion: nil)
        #expect(spotify.playedAll == [2])
    }

    @Test("Stays on Music when Spotify has not been connected")
    func needsConnection() {
        let (router, _, _) = makeRouter(spotifyReady: false)
        router.follow(sourceBundleID: LibraryRouter.spotifyBundleIdentifier)
        router.beginBrowsing()
        #expect(router.displayName == "Music")
    }

    @Test("Holds its choice until the menu opens again")
    func locksWhileBrowsing() {
        let (router, music, _) = makeRouter()
        router.beginBrowsing()
        router.follow(sourceBundleID: LibraryRouter.spotifyBundleIdentifier)

        router.play(playlistIndex: 1, trackIndex: 3, completion: nil)
        #expect(music.playedPlaylistTracks == [.init(playlist: 1, track: 3)])

        router.follow(sourceBundleID: "com.apple.Safari")
        router.beginBrowsing()
        #expect(router.displayName == "Music", "anything else falls back to Music")
    }

    @Test("The menu names the library row and title after the library")
    func menuShowsLibraryName() {
        let (router, _, _) = makeRouter()
        router.follow(sourceBundleID: LibraryRouter.spotifyBundleIdentifier)
        let model = MenuViewModel(library: router)

        #expect(model.rows.first?.title == "Spotify")
        _ = model.activateSelection()
        #expect(model.level == .music)
        #expect(model.title == "Spotify")
    }

    @Test("Play All without a playable container queues the list itself")
    func queuesWholeLibrary() {
        let name = "nl.jopmors.Spindle.spotifyPlayAll"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }
        let settings = AppSettings(defaults: defaults)
        settings.isWheelClickEnabled = false
        settings.shuffleMode = .off
        let library = namedStub("Spotify", playsWholeLibrary: false)
        let device = SpindleViewModel(settings: settings, library: library, modes: SilentModes())

        device.showMenu()
        for title in ["Spotify", "Songs", "Play All"] {
            let index = device.menu.rows.firstIndex { $0.title == title } ?? 0
            device.menu.moveSelection(by: index - device.menu.selection)
            device.centerButtonPressed { _ in }
        }

        #expect(library.playedAll.isEmpty)
        #expect(library.playedLibraryTracks == [.init(playlist: nil, track: 1)])
        #expect(device.queuePosition == QueuePosition(cursor: 0, count: 3))
        #expect(device.mode == .nowPlaying)
    }
}

@Suite("Spotify Web API")
struct SpotifyWebAPITests {

    private func page(_ json: String) throws -> SpotifyWebAPI.Page<SpotifyWebAPI.PlaylistItem> {
        try JSONDecoder().decode(
            SpotifyWebAPI.Page<SpotifyWebAPI.PlaylistItem>.self, from: Data(json.utf8)
        )
    }

    @Test("Keeps tracks, drops episodes, local files and nulls")
    func filtersUnplayable() throws {
        let json = """
        {"next": null, "items": [
          {"track": {"uri": "spotify:track:abc123", "name": "One", "type": "track",
                     "artists": [{"name": "A"}, {"name": "B"}],
                     "album": {"name": "LP", "images": [
                        {"url": "https://i.scdn.co/640", "width": 640},
                        {"url": "https://i.scdn.co/300", "width": 300},
                        {"url": "https://i.scdn.co/64", "width": 64}]}}},
          {"item": {"uri": "spotify:track:def456", "name": "Two", "type": "track",
                    "artists": [{"name": "C"}], "album": {"name": "EP"}}},
          {"track": {"uri": "spotify:episode:xyz", "name": "Pod", "type": "episode"}},
          {"track": {"uri": "spotify:local:a:b:c:1", "name": "Rip", "type": "track", "is_local": true}},
          {"track": null},
          null
        ]}
        """
        let tracks = SpotifyWebAPI.tracks(from: [try page(json)])

        #expect(tracks.map(\.name) == ["One", "Two"])
        #expect(tracks[0].artist == "A, B")
        #expect(tracks[0].artworkURL?.absoluteString == "https://i.scdn.co/300")
        #expect(tracks[1].album == "EP")
        #expect(tracks[1].artworkURL == nil)
    }

    @Test("Only well-formed URIs reach AppleScript")
    func validatesURIs() {
        #expect(SpotifyWebAPI.isPlayableURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC"))
        #expect(SpotifyWebAPI.isPlayableURI("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"))
        #expect(!SpotifyWebAPI.isPlayableURI("spotify:track:abc\" & do shell script \"x"))
        #expect(!SpotifyWebAPI.isPlayableURI("spotify:local:a:b:c:1"))
        #expect(!SpotifyWebAPI.isPlayableURI("spotify:episode:abc"))
        #expect(!SpotifyWebAPI.isPlayableURI("spotify:track:"))
    }
}

@Suite("Spotify login")
struct SpotifyLoginTests {

    @Test("PKCE challenge matches RFC 7636's worked example")
    func pkceChallenge() {
        #expect(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
        let verifier = PKCE.makeVerifier()
        #expect(verifier.count == 64)
    }

    @Test("The redirect hands back the code only with the right state")
    func parsesRedirect() {
        let good = "GET /callback?code=AQB-x_1&state=s1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(LoopbackRedirect.parse(request: good, expectedState: "s1") == .code("AQB-x_1"))

        let forged = "GET /callback?code=AQB&state=other HTTP/1.1\r\n\r\n"
        guard case .failure = LoopbackRedirect.parse(request: forged, expectedState: "s1") else {
            Issue.record("a mismatched state must not complete the login")
            return
        }

        let denied = "GET /callback?error=access_denied&state=s1 HTTP/1.1\r\n\r\n"
        #expect(LoopbackRedirect.parse(request: denied, expectedState: "s1")
            == .failure("Spotify access was declined."))

        let favicon = "GET /favicon.ico HTTP/1.1\r\n\r\n"
        #expect(LoopbackRedirect.parse(request: favicon, expectedState: "s1") == .ignore)
    }

    @Test("The listener answers a real browser redirect on loopback")
    func listenerRoundTrip() async throws {
        let redirect = LoopbackRedirect(port: 43_822)
        try redirect.start(expectingState: "s1")
        defer { redirect.stop() }
        // Give the listener a moment to bind before the request goes out.
        try await Task.sleep(for: .milliseconds(200))

        async let code = redirect.waitForCode(timeout: 5)
        let url = URL(string: "http://127.0.0.1:43822/callback?code=abc&state=s1")!
        let (_, response) = try await URLSession.shared.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await code == "abc")
    }

    @Test("Form bodies escape everything but unreserved characters")
    func formEncoding() {
        #expect(FormEncoding.encode([("redirect_uri", "http://127.0.0.1:1/cb"), ("a", "b c+d")])
            == "redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcb&a=b%20c%2Bd")
    }
}
