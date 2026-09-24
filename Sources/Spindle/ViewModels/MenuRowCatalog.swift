import Foundation

/// The rows that never come from the library.
///
/// Pulled out of `MenuViewModel` so the view model is about navigation rather
/// than about which words are on which screen.
enum MenuRowCatalog {

    /// `libraryName` is whichever player the menu is browsing — Music, or
    /// Spotify while Spotify is the one playing.
    static func main(
        libraryName: String = "Music",
        shuffleLabel: String,
        repeatLabel: String
    ) -> [MenuRow] {
        [
            MenuRow(id: MenuRowID.music, title: libraryName),
            MenuRow(id: MenuRowID.shuffle, title: "Shuffle", accessory: .value(shuffleLabel)),
            MenuRow(id: MenuRowID.repeatMode, title: "Repeat", accessory: .value(repeatLabel)),
            MenuRow(id: MenuRowID.settings, title: "Settings", accessory: .none),
            MenuRow(id: MenuRowID.nowPlaying, title: "Now Playing")
        ]
    }

    static let music: [MenuRow] = [
        MenuRow(id: MenuRowID.playlists, title: "Playlists"),
        MenuRow(id: MenuRowID.artists, title: "Artists"),
        MenuRow(id: MenuRowID.albums, title: "Albums"),
        MenuRow(id: MenuRowID.songs, title: "Songs")
    ]
}
