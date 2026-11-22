import AppKit
import CryptoKit
import Foundation
import Network

public struct SpotifyPlaylist: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let uri: String
    public let imageURL: String?
    public let trackCount: Int
    public let ownerName: String

    public init(id: String, name: String, uri: String, imageURL: String?, trackCount: Int, ownerName: String) {
        self.id = id
        self.name = name
        self.uri = uri
        self.imageURL = imageURL
        self.trackCount = trackCount
        self.ownerName = ownerName
    }
}

public struct SpotifyTrackItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let artist: String
    public let album: String
    public let uri: String
    public let imageURL: String?
    public let durationMs: Int

    public init(id: String, name: String, artist: String, album: String, uri: String, imageURL: String?, durationMs: Int) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
        self.uri = uri
        self.imageURL = imageURL
        self.durationMs = durationMs
    }
}

public struct SpotifySearchResults: Sendable {
    public let tracks: [SpotifyTrackItem]
    public let playlists: [SpotifyPlaylist]

    public static let empty = SpotifySearchResults(tracks: [], playlists: [])

    public init(tracks: [SpotifyTrackItem], playlists: [SpotifyPlaylist]) {
        self.tracks = tracks
        self.playlists = playlists
    }
}

public enum SpotifyAPIError: LocalizedError, Sendable {
    case missingClientID
    case notAuthenticated
    case authCancelledOrTimedOut
    case callbackServerFailed(String)
    case tokenExchangeFailed(String)
    case httpError(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Lütfen önce Spotify Developer Dashboard'dan aldığınız Client ID'yi girin."
        case .notAuthenticated:
            return "Spotify hesabınız bağlı değil. Lütfen Spotify ile bağlanın."
        case .authCancelledOrTimedOut:
            return "Spotify girişi zaman aşımına uğradı veya iptal edildi."
        case .callbackServerFailed(let detail):
            return "Yerel giriş dinleyicisi başlatılamadı: \(detail)"
        case .tokenExchangeFailed(let detail):
            return "Spotify oturum anahtarı alınamadı: \(detail)"
        case .httpError(let code, let detail):
            if code == 401 {
                return "Spotify oturumunuzun süresi doldu. Lütfen tekrar bağlanın."
            }
            return "Spotify API hatası (\(code)): \(detail)"
        }
    }
}

@MainActor
public final class SpotifyWebAPIService {
    public static let redirectPort: UInt16 = 43821
    public static let redirectURI: String = "http://127.0.0.1:43821/callback"
    private static let scopes = "playlist-read-private playlist-read-collaborative user-library-read user-read-playback-state user-modify-playback-state"

    private let defaults: UserDefaults
    private let clientIDKey = "graphe.spotify.clientID.v1"
    private let accessTokenKey = "graphe.spotify.accessToken.v1"
    private let refreshTokenKey = "graphe.spotify.refreshToken.v1"
    private let expiresAtKey = "graphe.spotify.expiresAt.v1"

    public var clientID: String {
        get { defaults.string(forKey: clientIDKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey) }
    }

    public var isAuthenticated: Bool {
        let access = defaults.string(forKey: accessTokenKey) ?? ""
        let refresh = defaults.string(forKey: refreshTokenKey) ?? ""
        return !access.isEmpty || !refresh.isEmpty
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func disconnect() {
        defaults.removeObject(forKey: accessTokenKey)
        defaults.removeObject(forKey: refreshTokenKey)
        defaults.removeObject(forKey: expiresAtKey)
    }

    // MARK: - PKCE OAuth Flow (127.0.0.1 Loopback)

    public func authenticate(clientID rawClientID: String) async throws {
        let trimmedID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw SpotifyAPIError.missingClientID }
        self.clientID = trimmedID

        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(for: codeVerifier)
        let stateToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: stateToken),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge)
        ]
        guard let authURL = components.url else {
            throw SpotifyAPIError.tokenExchangeFailed("Geçersiz yetkilendirme adresi.")
        }

        let callbackServer = LoopbackOAuthServer(port: Self.redirectPort, expectedState: stateToken)
        try callbackServer.start()
        defer { callbackServer.stop() }

        NSWorkspace.shared.open(authURL)

        let authCode = try await callbackServer.waitForCode(timeoutSeconds: 180)
        try await exchangeCodeForTokens(code: authCode, codeVerifier: codeVerifier, clientID: trimmedID)
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String, clientID: String) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyPairs: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", Self.redirectURI),
            ("client_id", clientID),
            ("code_verifier", codeVerifier)
        ]
        req.httpBody = Self.formEncodedBody(bodyPairs)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw SpotifyAPIError.tokenExchangeFailed(msg)
        }
        try saveTokenResponse(data)
    }

    private func ensureValidAccessToken() async throws -> String {
        let now = Date().timeIntervalSince1970
        let access = defaults.string(forKey: accessTokenKey) ?? ""
        let expiresAt = defaults.double(forKey: expiresAtKey)

        if !access.isEmpty && expiresAt > now + 60 {
            return access
        }

        guard let refresh = defaults.string(forKey: refreshTokenKey), !refresh.isEmpty else {
            throw SpotifyAPIError.notAuthenticated
        }
        let cid = self.clientID
        guard !cid.isEmpty else { throw SpotifyAPIError.missingClientID }

        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncodedBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
            ("client_id", cid)
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 400 || status == 401 {
                disconnect()
            }
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw SpotifyAPIError.tokenExchangeFailed(msg)
        }
        try saveTokenResponse(data)
        guard let refreshedAccess = defaults.string(forKey: accessTokenKey), !refreshedAccess.isEmpty else {
            throw SpotifyAPIError.notAuthenticated
        }
        return refreshedAccess
    }

    private func saveTokenResponse(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw SpotifyAPIError.tokenExchangeFailed("Yanıt çözümlenemedi.")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        defaults.set(access, forKey: accessTokenKey)
        defaults.set(Date().timeIntervalSince1970 + expiresIn, forKey: expiresAtKey)
        if let refresh = json["refresh_token"] as? String, !refresh.isEmpty {
            defaults.set(refresh, forKey: refreshTokenKey)
        }
    }

    // MARK: - Web API Endpoints

    public func fetchCurrentUserPlaylists(limit: Int = 50) async throws -> [SpotifyPlaylist] {
        let json = try await authorizedGetJSON(path: "/v1/me/playlists", query: [
            URLQueryItem(name: "limit", value: "\(min(50, max(1, limit)))")
        ])
        guard let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap(Self.parsePlaylist)
    }

    public func fetchPlaylistTracks(playlistID: String, limit: Int = 50) async throws -> [SpotifyTrackItem] {
        let encodedID = playlistID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlistID
        // Spotify February 2026 Web API replaced `/playlists/{id}/tracks` with `/playlists/{id}/items`
        let json = try await authorizedGetJSON(path: "/v1/playlists/\(encodedID)/items", query: [
            URLQueryItem(name: "limit", value: "\(min(50, max(1, limit)))"),
            URLQueryItem(name: "additional_types", value: "track")
        ])
        guard let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { entry in
            guard let trackObj = (entry["item"] as? [String: Any]) ?? (entry["track"] as? [String: Any]) else {
                return nil
            }
            return Self.parseTrack(trackObj)
        }
    }

    public func search(query: String, limit: Int = 10) async throws -> SpotifySearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let json = try await authorizedGetJSON(path: "/v1/search", query: [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "type", value: "track,playlist"),
            URLQueryItem(name: "limit", value: "\(min(10, max(1, limit)))")
        ])

        var tracks: [SpotifyTrackItem] = []
        if let tracksObj = json["tracks"] as? [String: Any],
           let items = tracksObj["items"] as? [[String: Any]] {
            tracks = items.compactMap(Self.parseTrack)
        }

        var playlists: [SpotifyPlaylist] = []
        if let plObj = json["playlists"] as? [String: Any],
           let items = plObj["items"] as? [Any] {
            for raw in items {
                if let dict = raw as? [String: Any], let pl = Self.parsePlaylist(dict) {
                    playlists.append(pl)
                }
            }
        }
        return SpotifySearchResults(tracks: tracks, playlists: playlists)
    }

    /// Starts playback silently via Web API so the macOS Spotify window never steals focus.
    /// Returns `true` if Spotify accepted the command; returns `false` if unavailable (e.g. Free account or missing scope) so caller can fall back to AppleScript.
    public func startPlayback(uri: String, contextURI: String? = nil) async -> Bool {
        guard let token = try? await ensureValidAccessToken() else { return false }
        guard let url = URL(string: "https://api.spotify.com/v1/me/player/play") else { return false }

        var payload: [String: Any] = [:]
        if let ctx = contextURI, !ctx.isEmpty {
            payload["context_uri"] = ctx
            payload["offset"] = ["uri": uri]
        } else if uri.contains(":playlist:") || uri.contains(":album:") {
            payload["context_uri"] = uri
        } else {
            payload["uris"] = [uri]
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status >= 200 && status < 300
        } catch {
            return false
        }
    }

    private func authorizedGetJSON(path: String, query: [URLQueryItem]) async throws -> [String: Any] {
        let token = try await ensureValidAccessToken()
        var components = URLComponents(string: "https://api.spotify.com\(path)")!
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw SpotifyAPIError.httpError(0, "Geçersiz URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status >= 200 && status < 300 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyAPIError.httpError(status, msg)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    // MARK: - JSON Parsing

    private static func parsePlaylist(_ dict: [String: Any]) -> SpotifyPlaylist? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let uri = dict["uri"] as? String else { return nil }
        let images = dict["images"] as? [[String: Any]]
        let imageURL = (images?.last?["url"] as? String) ?? (images?.first?["url"] as? String)
        let tracksObj = (dict["items"] as? [String: Any]) ?? (dict["tracks"] as? [String: Any])
        let total = (tracksObj?["total"] as? Int) ?? 0
        let ownerObj = dict["owner"] as? [String: Any]
        let owner = (ownerObj?["display_name"] as? String) ?? ""
        return SpotifyPlaylist(id: id, name: name, uri: uri, imageURL: imageURL, trackCount: total, ownerName: owner)
    }

    private static func parseTrack(_ dict: [String: Any]) -> SpotifyTrackItem? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let uri = dict["uri"] as? String else { return nil }
        let artistsArr = dict["artists"] as? [[String: Any]] ?? []
        let artistNames = artistsArr.compactMap { $0["name"] as? String }.joined(separator: ", ")
        let albumObj = dict["album"] as? [String: Any]
        let albumName = (albumObj?["name"] as? String) ?? ""
        let images = albumObj?["images"] as? [[String: Any]]
        let imageURL = (images?.last?["url"] as? String) ?? (images?.first?["url"] as? String)
        let durationMs = (dict["duration_ms"] as? Int) ?? 0
        return SpotifyTrackItem(
            id: id,
            name: name,
            artist: artistNames,
            album: albumName,
            uri: uri,
            imageURL: imageURL,
            durationMs: durationMs
        )
    }

    // MARK: - PKCE Helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func generateCodeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncodedBody(_ pairs: [(String, String)]) -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = pairs.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
        return body.data(using: .utf8)
    }
}

// MARK: - Ephemeral 127.0.0.1 OAuth Callback Listener

private final class LoopbackOAuthServer: @unchecked Sendable {
    private let port: UInt16
    private let expectedState: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.graphe.spotify.oauth.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var completed = false

    init(port: UInt16, expectedState: String) {
        self.port = port
        self.expectedState = expectedState
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SpotifyAPIError.callbackServerFailed("Geçersiz port")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                self?.finish(with: .failure(SpotifyAPIError.callbackServerFailed(err.localizedDescription)))
            }
        }
        self.listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func waitForCode(timeoutSeconds: UInt64) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if completed {
                lock.unlock()
                cont.resume(throwing: SpotifyAPIError.authCancelledOrTimedOut)
                return
            }
            self.continuation = cont
            lock.unlock()

            queue.asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak self] in
                self?.finish(with: .failure(SpotifyAPIError.authCancelledOrTimedOut))
            }
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let pathAndQuery = parts.count >= 2 ? String(parts[1]) : "/"

            var parsedCode: String?
            var parsedError: String?
            var parsedState: String?

            if let comps = URLComponents(string: "http://127.0.0.1\(pathAndQuery)") {
                for item in comps.queryItems ?? [] {
                    if item.name == "code" { parsedCode = item.value }
                    if item.name == "error" { parsedError = item.value }
                    if item.name == "state" { parsedState = item.value }
                }
            }

            let html: String
            if let code = parsedCode, !code.isEmpty, parsedState == self.expectedState {
                html = """
                <html><head><meta charset="utf-8"><title>Graphe · Spotify</title>
                <style>body{font-family:-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f7f5f0;color:#222;}
                .card{padding:28px 34px;border-radius:14px;background:#fff;box-shadow:0 8px 30px rgba(0,0,0,.08);text-align:center;}
                h2{margin:0 0 8px 0;font-size:18px;}p{margin:0;color:#666;font-size:13px;}</style></head>
                <body><div class="card"><h2>Spotify Bağlantısı Tamamlandı</h2><p>Bu sekmeyi kapatıp Graphe'ye dönebilirsiniz.</p></div></body></html>
                """
                self.sendHTTPResponse(html, on: connection) {
                    self.finish(with: .success(code))
                }
            } else {
                let errText = parsedError ?? "Yetkilendirme reddedildi"
                html = """
                <html><head><meta charset="utf-8"><title>Graphe · Spotify</title></head>
                <body style="font-family:-apple-system,sans-serif;padding:40px;text-align:center;">
                <h3>Spotify bağlantısı başarısız</h3><p>\(errText)</p></body></html>
                """
                self.sendHTTPResponse(html, on: connection) {
                    self.finish(with: .failure(SpotifyAPIError.tokenExchangeFailed(errText)))
                }
            }
        }
    }

    private func sendHTTPResponse(_ html: String, on connection: NWConnection, completion: @escaping @Sendable () -> Void) {
        let bodyData = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
            completion()
        })
    }

    private func finish(with result: Result<String, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let cont = continuation
        continuation = nil
        lock.unlock()

        stop()
        cont?.resume(with: result)
    }
}
