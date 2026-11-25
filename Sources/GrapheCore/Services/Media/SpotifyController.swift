#if os(macOS)
import AppKit
import Foundation
import Observation

@Observable
@MainActor
public final class SpotifyController {
    // Live playback state (local Spotify app via DistributedNotificationCenter + AppleScript)
    public var isRunning: Bool = false
    public var isPlaying: Bool = false
    public var trackName: String = ""
    public var artistName: String = ""
    public var artworkURL: String = ""
    public var durationSeconds: Double = 0
    public var positionSeconds: Double = 0
    public var volume: Double = 70
    public var isShuffling: Bool = false
    public var isRepeating: Bool = false
    public var isScrubbing: Bool = false

    // Spotify Web API (PKCE OAuth) state
    public let webAPI = SpotifyWebAPIService()
    public var isWebAPIConnected: Bool = false
    public var isAuthenticating: Bool = false
    public var webAPIError: String?
    public var playlists: [SpotifyPlaylist] = []
    public var isLoadingPlaylists: Bool = false
    public var selectedPlaylist: SpotifyPlaylist?
    public var selectedPlaylistTracks: [SpotifyTrackItem] = []
    public var isLoadingPlaylistTracks: Bool = false
    public var searchQuery: String = ""
    public var searchResults: SpotifySearchResults = .empty
    public var isSearching: Bool = false

    private var distributedObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var progressTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var didInitialFetch: Bool = false

    public init() {
        self.isWebAPIConnected = webAPI.isAuthenticated
    }

    public func startObserving() {
        guard distributedObserver == nil else { return }

        // 1) Instant updates via Spotify's native macOS DistributedNotificationCenter broadcasts
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let userInfo = notification.userInfo
            let stateStr = (userInfo?["Player State"] as? String)?.lowercased()
            let name = userInfo?["Name"] as? String
            let artist = userInfo?["Artist"] as? String
            let durationMs = userInfo?["Duration"] as? Double
            let playbackPosition = userInfo?["Playback Position"] as? Double

            Task { @MainActor [weak self] in
                guard let self else { return }
                if stateStr == "stopped" {
                    self.isPlaying = false
                    self.checkRunningState()
                    return
                }
                self.isRunning = true
                if let stateStr {
                    self.isPlaying = (stateStr == "playing")
                }
                if let name, !name.isEmpty {
                    let trackChanged = (name != self.trackName)
                    self.trackName = name
                    if trackChanged {
                        self.refreshStateFromSpotify()
                    }
                }
                if let artist {
                    self.artistName = artist
                }
                if let durationMs, durationMs > 0 {
                    self.durationSeconds = durationMs / 1000.0
                }
                if let playbackPosition, !self.isScrubbing {
                    self.positionSeconds = max(0, playbackPosition)
                }
            }
        }

        // 2) Observe Spotify launch & termination via NSWorkspace (zero permission prompts when Spotify is closed)
        let wsCenter = NSWorkspace.shared.notificationCenter
        launchObserver = wsCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.spotify.client" else { return }
            Task { @MainActor [weak self] in
                self?.isRunning = true
                try? await Task.sleep(for: .milliseconds(700))
                self?.refreshStateFromSpotify()
            }
        }

        terminateObserver = wsCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.spotify.client" else { return }
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.isPlaying = false
                self?.trackName = ""
                self?.artistName = ""
                self?.artworkURL = ""
                self?.positionSeconds = 0
                self?.durationSeconds = 0
            }
        }

        // 3) Lightweight 1-second local ticker for smooth progress bar (resyncs with Spotify every 15s while playing)
        progressTask = Task { @MainActor [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { break }
                if self.isRunning && self.isPlaying && !self.isScrubbing {
                    if self.durationSeconds > 0 {
                        self.positionSeconds = min(self.durationSeconds, self.positionSeconds + 1.0)
                    }
                    tickCount += 1
                    if tickCount >= 15 {
                        tickCount = 0
                        self.refreshStateFromSpotify()
                    }
                } else {
                    tickCount = 0
                }
            }
        }

        checkRunningState()
        if isRunning && !didInitialFetch {
            didInitialFetch = true
            refreshStateFromSpotify()
        }
    }

    public func stopObserving() {
        progressTask?.cancel()
        progressTask = nil
        searchTask?.cancel()
        searchTask = nil
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let launchObserver {
            wsCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let terminateObserver {
            wsCenter.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
    }

    public func checkRunningState() {
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.spotify.client"
        }
        isRunning = running
        if !running {
            isPlaying = false
            trackName = ""
            artistName = ""
            artworkURL = ""
            positionSeconds = 0
            durationSeconds = 0
        }
    }

    public func refreshStateFromSpotify() {
        checkRunningState()
        guard isRunning else { return }
        let script = """
        tell application "Spotify"
            set pState to player state as string
            set pVol to sound volume as integer
            set pPos to player position as real
            set pShuf to shuffling as boolean
            set pRep to repeating as boolean
            set tName to ""
            set tArtist to ""
            set tArt to ""
            set tDur to 0
            try
                set tName to name of current track
                set tArtist to artist of current track
                set tArt to artwork url of current track
                set tDur to duration of current track
            end try
            return pState & "|||" & tName & "|||" & tArtist & "|||" & tArt & "|||" & (tDur as string) & "|||" & (pPos as string) & "|||" & (pVol as string) & "|||" & (pShuf as string) & "|||" & (pRep as string)
        end tell
        """
        Task.detached(priority: .utility) { [weak self] in
            guard let output = Self.runAppleScript(script) else { return }
            let parts = output.components(separatedBy: "|||")
            guard parts.count >= 9 else { return }
            let playing = (parts[0].lowercased() == "playing")
            let name = parts[1]
            let artist = parts[2]
            let art = parts[3]
            let durMs = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
            let posSec = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
            let vol = Double(parts[6].replacingOccurrences(of: ",", with: ".")) ?? 70
            let shuf = (parts[7].lowercased() == "true")
            let rep = (parts[8].lowercased() == "true")

            await MainActor.run { [weak self] in
                guard let self, self.isRunning else { return }
                self.isPlaying = playing
                if !name.isEmpty { self.trackName = name }
                self.artistName = artist
                if !art.isEmpty { self.artworkURL = art }
                if durMs > 0 { self.durationSeconds = durMs / 1000.0 }
                if !self.isScrubbing {
                    self.positionSeconds = max(0, posSec)
                }
                self.volume = min(100, max(0, vol))
                self.isShuffling = shuf
                self.isRepeating = rep
            }
        }
    }

    // MARK: - Playback Controls (Local Spotify)

    public func playPause() {
        guard isRunning else {
            openSpotify()
            return
        }
        isPlaying.toggle()
        runCommand("tell application \"Spotify\" to playpause")
    }

    public func nextTrack() {
        guard isRunning else { return }
        runCommand("tell application \"Spotify\" to next track")
    }

    public func previousTrack() {
        guard isRunning else { return }
        runCommand("tell application \"Spotify\" to previous track")
    }

    public func seek(to seconds: Double) {
        guard isRunning else { return }
        let clamped = max(0, min(durationSeconds > 0 ? durationSeconds : seconds, seconds))
        positionSeconds = clamped
        let formatted = String(format: "%.2f", clamped)
        runCommand("tell application \"Spotify\" to set player position to \(formatted)", refreshAfter: false)
    }

    public func setVolume(_ percent: Double) {
        guard isRunning else { return }
        let clamped = Int(round(min(100, max(0, percent))))
        volume = Double(clamped)
        runCommand("tell application \"Spotify\" to set sound volume to \(clamped)", refreshAfter: false)
    }

    public func toggleShuffle() {
        guard isRunning else { return }
        isShuffling.toggle()
        let val = isShuffling ? "true" : "false"
        runCommand("tell application \"Spotify\" to set shuffling to \(val)", refreshAfter: false)
    }

    public func toggleRepeat() {
        guard isRunning else { return }
        isRepeating.toggle()
        let val = isRepeating ? "true" : "false"
        runCommand("tell application \"Spotify\" to set repeating to \(val)", refreshAfter: false)
    }

    public func playURI(_ uri: String, inContext contextURI: String? = nil) {
        let escapedURI = uri.replacingOccurrences(of: "\"", with: "")
        let script: String
        if let ctx = contextURI, !ctx.isEmpty {
            let escapedCtx = ctx.replacingOccurrences(of: "\"", with: "")
            script = "tell application \"Spotify\" to play track \"\(escapedURI)\" in context \"\(escapedCtx)\""
        } else {
            script = "tell application \"Spotify\" to play track \"\(escapedURI)\""
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // 1) Try silent Web API playback first (never brings Spotify window to front)
            if self.isWebAPIConnected && self.isRunning {
                let ok = await self.webAPI.startPlayback(uri: escapedURI, contextURI: contextURI)
                if ok {
                    try? await Task.sleep(for: .milliseconds(250))
                    self.refreshStateFromSpotify()
                    return
                }
            }

            // 2) Fallback to local AppleScript, immediately restoring Graphe's focus so Spotify doesn't steal the screen
            if !self.isRunning {
                self.openSpotify(activate: false)
                try? await Task.sleep(for: .milliseconds(1600))
                self.isRunning = true
            }
            await Task.detached(priority: .userInitiated) {
                _ = Self.runAppleScript(script)
            }.value

            // Keep Graphe in front if Spotify tried to surface itself on `play track`
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(250))
            NSApp.activate(ignoringOtherApps: true)
            self.refreshStateFromSpotify()
        }
    }

    public func openSpotify(activate: Bool = true) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = activate
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }

    // MARK: - Spotify Web API (Playlists & Search)

    public func connectWebAPI(clientID: String) {
        webAPIError = nil
        isAuthenticating = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAuthenticating = false }
            do {
                try await self.webAPI.authenticate(clientID: clientID)
                self.isWebAPIConnected = true
                self.webAPIError = nil
                await self.loadPlaylistsAsync()
            } catch {
                self.webAPIError = error.localizedDescription
            }
        }
    }

    public func disconnectWebAPI() {
        webAPI.disconnect()
        isWebAPIConnected = false
        playlists = []
        selectedPlaylist = nil
        selectedPlaylistTracks = []
        searchResults = .empty
        searchQuery = ""
        webAPIError = nil
    }

    public func loadPlaylistsIfNeeded() {
        guard isWebAPIConnected, playlists.isEmpty, !isLoadingPlaylists else { return }
        Task { @MainActor [weak self] in
            await self?.loadPlaylistsAsync()
        }
    }

    public func reloadPlaylists() {
        guard isWebAPIConnected, !isLoadingPlaylists else { return }
        Task { @MainActor [weak self] in
            await self?.loadPlaylistsAsync()
        }
    }

    private func loadPlaylistsAsync() async {
        isLoadingPlaylists = true
        webAPIError = nil
        defer { isLoadingPlaylists = false }
        do {
            playlists = try await webAPI.fetchCurrentUserPlaylists(limit: 50)
        } catch {
            webAPIError = error.localizedDescription
            if !webAPI.isAuthenticated {
                isWebAPIConnected = false
            }
        }
    }

    public func openPlaylist(_ playlist: SpotifyPlaylist) {
        selectedPlaylist = playlist
        selectedPlaylistTracks = []
        isLoadingPlaylistTracks = true
        webAPIError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingPlaylistTracks = false }
            do {
                self.selectedPlaylistTracks = try await self.webAPI.fetchPlaylistTracks(playlistID: playlist.id)
            } catch {
                self.webAPIError = error.localizedDescription
            }
        }
    }

    public func scheduleSearch(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = .empty
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self else { return }
            do {
                let res = try await self.webAPI.search(query: trimmed, limit: 10)
                if !Task.isCancelled {
                    self.searchResults = res
                    self.webAPIError = nil
                }
            } catch {
                if !Task.isCancelled {
                    self.webAPIError = error.localizedDescription
                }
            }
            self.isSearching = false
        }
    }

    private func runCommand(_ script: String, refreshAfter: Bool = true) {
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = Self.runAppleScript(script)
            if refreshAfter {
                try? await Task.sleep(for: .milliseconds(250))
                await MainActor.run { [weak self] in
                    self?.refreshStateFromSpotify()
                }
            }
        }
    }

    private nonisolated static func runAppleScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
#endif
