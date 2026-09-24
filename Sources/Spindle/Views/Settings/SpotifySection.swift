import AppKit
import SwiftUI

/// Connecting a Spotify account, so the menu can browse it.
struct SpotifySection: View {
    @ObservedObject var account: SpotifyAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Spotify")
            Text("""
            While Spotify is what's playing, the menu browses your Spotify \
            playlists and Liked Songs instead of Music. Playback stays in the \
            Spotify app.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if account.isConnected {
                connected
            } else {
                setup
            }
        }
    }

    private var connected: some View {
        HStack {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Spacer()
            Button("Disconnect") { account.disconnect() }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            step("1.", Text("Create an app in the ")
                + Text("[Spotify Developer Dashboard](\(SpotifyAccount.dashboardURL.absoluteString))")
                + Text(" and tick Web API."))
            step("2.", Text("Add this Redirect URI to it:"))
            HStack {
                Text(SpotifyAccount.redirectURI)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpotifyAccount.redirectURI, forType: .string)
                }
                .controlSize(.small)
            }
            .padding(.leading, 16)
            step("3.", Text("Paste its Client ID and connect:"))
            HStack {
                TextField("Client ID", text: $account.clientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .disabled(account.state == .connecting)
                connectButton
            }
            .padding(.leading, 16)
            status
        }
    }

    @ViewBuilder
    private var connectButton: some View {
        if account.state == .connecting {
            Button("Cancel") { account.cancelConnect() }
        } else {
            Button("Connect") { account.connect() }
                .disabled(account.clientID.isEmpty)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch account.state {
        case .connecting:
            Text("Finish signing in in your browser…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .connected, .disconnected:
            EmptyView()
        }
    }

    private func step(_ number: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(number).monospacedDigit()
            text
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}
