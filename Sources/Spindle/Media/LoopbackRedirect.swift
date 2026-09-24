import Foundation
import Network

/// A one-shot HTTP listener on 127.0.0.1 that catches Spotify's redirect after
/// the user approves the login in their browser.
///
/// Bound to the loopback interface only, so nothing off this machine can reach
/// it, and it stops as soon as one callback has been answered.
///
/// Unchecked because every mutable property is confined to `queue`.
final class LoopbackRedirect: @unchecked Sendable {

    private let port: UInt16
    private let queue = DispatchQueue(label: "nl.jopmors.spindle.spotify-redirect")
    private var listener: NWListener?
    /// Touched only on `queue`.
    private var continuation: CheckedContinuation<String, Error>?
    private var expectedState = ""
    private var pending: Result<String, Error>?

    init(port: UInt16) {
        self.port = port
    }

    /// `state` is set before the browser opens, so an early callback can never
    /// be checked against an empty value.
    func start(expectingState state: String) throws {
        queue.sync { expectedState = state }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw SpotifyError.redirectFailed("Invalid redirect port.")
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw SpotifyError.redirectFailed(
                "Could not listen on port \(self.port): \(error.localizedDescription)"
            )
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.finish(.failure(SpotifyError.redirectFailed(
                    "Port \(port) is unavailable: \(error.localizedDescription)"
                )))
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Waits for the browser to arrive with `code`. The `state` check in
    /// `parse` means a stray or forged request cannot complete the login.
    func waitForCode(timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let pending = self.pending {
                        continuation.resume(with: pending)
                        return
                    }
                    self.continuation = continuation
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        self.finish(.failure(SpotifyError.timedOut))
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    // MARK: - Requests

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let outcome = Self.parse(request: request, expectedState: self.expectedState)
            switch outcome {
            case .ignore:
                Self.respond(connection, status: "404 Not Found", body: "Not found.")
            case .code(let code):
                Self.respond(connection, status: "200 OK", body: Self.page(
                    "Spindle is connected to Spotify. You can close this tab."
                ))
                self.finish(.success(code))
            case .failure(let message):
                Self.respond(connection, status: "400 Bad Request", body: Self.page(message))
                self.finish(.failure(SpotifyError.redirectFailed(message)))
            }
        }
    }

    enum Outcome: Equatable {
        case ignore
        case code(String)
        case failure(String)
    }

    /// Reads the request line of the redirect. Internal so tests can feed it.
    static func parse(request: String, expectedState: String) -> Outcome {
        let requestLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == "/callback" else { return .ignore }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard value("state") == expectedState, !expectedState.isEmpty else {
            return .failure("The login did not match the one Spindle started. Try again.")
        }
        if let error = value("error") {
            return .failure(error == "access_denied"
                ? "Spotify access was declined."
                : "Spotify reported an error: \(error)")
        }
        guard let code = value("code"), !code.isEmpty else {
            return .failure("Spotify did not send a login code.")
        }
        return .code(code)
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else {
            if pending == nil { pending = result }
            return
        }
        self.continuation = nil
        pending = result
        continuation.resume(with: result)
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(_ message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><meta charset="utf-8"><title>Spindle</title>
        <body style="font: 15px -apple-system, sans-serif; margin: 3em; text-align: center">
        <p>\(escaped)</p></body>
        """
    }
}
