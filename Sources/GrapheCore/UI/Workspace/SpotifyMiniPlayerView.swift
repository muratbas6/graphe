import AppKit
import SwiftUI

// MARK: - 1. Sidebar Bottom Compact & Rich Mini Card

public struct SpotifySidebarCardView: View {
    @Bindable public var spotify: SpotifyController
    public let theme: ReadingTheme

    @State private var showPopover: Bool = false
    @State private var lastNonZeroVolume: Double = 70

    public init(spotify: SpotifyController, theme: ReadingTheme) {
        self.spotify = spotify
        self.theme = theme
    }

    public var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.subtleBorder)
                .frame(height: 1)

            if spotify.isRunning {
                VStack(spacing: 7) {
                    // Top row: 38x38 artwork + Track/Artist + Inline Volume + Popover trigger
                    HStack(spacing: 8) {
                        SpotifyArtworkThumbnail(urlString: spotify.artworkURL, size: 38, theme: theme)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(spotify.trackName.isEmpty ? "Spotify Hazır" : spotify.trackName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.primaryInk)
                                .lineLimit(1)

                            Text(spotify.artistName.isEmpty ? "Çalan parça yok" : spotify.artistName)
                                .font(.caption2)
                                .foregroundStyle(theme.secondaryInk)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            showPopover.toggle()
                        } label: {
                            Image(systemName: "music.note.list")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(showPopover ? Color.accentColor : theme.secondaryInk)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(showPopover ? Color.accentColor.opacity(0.14) : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Playlistlerim ve Spotify Arama")
                        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
                            SpotifyPopoverView(spotify: spotify, theme: theme)
                        }
                    }

                    // Slim interactive progress bar
                    if spotify.durationSeconds > 0 {
                        VStack(spacing: 2) {
                            GeometryReader { geo in
                                let fraction = max(0, min(1, spotify.positionSeconds / max(1, spotify.durationSeconds)))
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(theme.subtleBorder.opacity(0.9))
                                        .frame(height: 3.5)
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.85))
                                        .frame(width: max(3, geo.size.width * fraction), height: 3.5)
                                }
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { val in
                                            spotify.isScrubbing = true
                                            let ratio = max(0, min(1, val.location.x / max(1, geo.size.width)))
                                            spotify.positionSeconds = ratio * spotify.durationSeconds
                                        }
                                        .onEnded { val in
                                            let ratio = max(0, min(1, val.location.x / max(1, geo.size.width)))
                                            spotify.isScrubbing = false
                                            spotify.seek(to: ratio * spotify.durationSeconds)
                                        }
                                )
                            }
                            .frame(height: 10)

                            HStack {
                                Text(Self.formatTime(spotify.positionSeconds))
                                Spacer()
                                Text(Self.formatTime(spotify.durationSeconds))
                            }
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(theme.secondaryInk.opacity(0.75))
                        }
                    }

                    // Clean bottom row: Prev · Play/Pause · Next on the left, always-visible slim volume bar on the right
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                spotify.previousTrack()
                            } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.primaryInk.opacity(0.85))
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Önceki Parça")

                            Button {
                                spotify.playPause()
                            } label: {
                                Image(systemName: spotify.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 21))
                                    .foregroundStyle(theme.primaryInk)
                            }
                            .buttonStyle(.plain)
                            .help(spotify.isPlaying ? "Duraklat" : "Oynat")

                            Button {
                                spotify.nextTrack()
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.primaryInk.opacity(0.85))
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Sonraki Parça")
                        }

                        Spacer(minLength: 6)

                        HStack(spacing: 5) {
                            Button {
                                if spotify.volume > 1 {
                                    lastNonZeroVolume = spotify.volume
                                    spotify.setVolume(0)
                                } else {
                                    spotify.setVolume(max(25, lastNonZeroVolume))
                                }
                            } label: {
                                Image(systemName: spotify.volume <= 1 ? "speaker.slash.fill" : (spotify.volume < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.secondaryInk.opacity(0.85))
                                    .frame(width: 14, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(spotify.volume <= 1 ? "Sesi Aç" : "Sessize Al (%\(Int(round(spotify.volume))))")

                            GeometryReader { geo in
                                let ratio = max(0, min(1, spotify.volume / 100.0))
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(theme.subtleBorder.opacity(0.95))
                                        .frame(height: 3.5)
                                    Capsule()
                                        .fill(theme.secondaryInk.opacity(0.85))
                                        .frame(width: max(3, geo.size.width * ratio), height: 3.5)
                                }
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { val in
                                            let pct = max(0, min(100, (val.location.x / max(1, geo.size.width)) * 100.0))
                                            spotify.setVolume(pct)
                                        }
                                )
                            }
                            .frame(width: 56, height: 16)
                            .help("Ses: %\(Int(round(spotify.volume)))")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(theme.chromeBackground)
            } else {
                // Ultra-clean slim bar when Spotify is closed
                HStack(spacing: 8) {
                    Button {
                        spotify.openSpotify()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryInk)
                            Text("Spotify'ı Başlat")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(theme.secondaryInk)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showPopover.toggle()
                    } label: {
                        Image(systemName: "music.note.list")
                            .font(.caption)
                            .foregroundStyle(showPopover ? Color.accentColor : theme.secondaryInk)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Playlistlerim ve Spotify Arama")
                    .popover(isPresented: $showPopover, arrowEdge: .trailing) {
                        SpotifyPopoverView(spotify: spotify, theme: theme)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.chromeBackground)
            }
        }
        .onAppear {
            spotify.startObserving()
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - 2. Compact Toolbar Icon (Shown Only When Left Sidebar Is Hidden)

public struct SpotifyToolbarButtonView: View {
    @Bindable public var spotify: SpotifyController
    public let theme: ReadingTheme

    @State private var showPopover: Bool = false
    @State private var lastNonZeroVolume: Double = 70

    public init(spotify: SpotifyController, theme: ReadingTheme) {
        self.spotify = spotify
        self.theme = theme
    }

    public var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Image(systemName: spotify.isPlaying ? "waveform" : "music.note")
                .foregroundStyle(spotify.isPlaying ? Color.accentColor : theme.secondaryInk)
                .symbolEffect(.variableColor.iterative, isActive: spotify.isPlaying)
        }
        .help(spotify.trackName.isEmpty ? "Spotify" : "\(spotify.trackName) — \(spotify.artistName)")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            SpotifyPopoverView(spotify: spotify, theme: theme)
        }
        .onAppear {
            spotify.startObserving()
        }
    }
}

// MARK: - 3. Two-Tab Spotify Popover (Playlistlerim | Ara + Volume + PKCE Setup)

private enum SpotifyPopoverTab: String, CaseIterable, Identifiable {
    case playlists = "Playlistlerim"
    case search = "Ara"
    var id: String { rawValue }
}

private struct SpotifyPopoverView: View {
    @Bindable var spotify: SpotifyController
    let theme: ReadingTheme

    @State private var activeTab: SpotifyPopoverTab = .playlists
    @State private var showSettings: Bool = false
    @State private var clientIDDraft: String = ""
    @State private var copiedRedirectURI: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Clean popover header: Spotify title + Refresh + Account/Settings
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Spotify")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.primaryInk)

                Spacer()

                if spotify.isRunning {
                    Button {
                        spotify.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(spotify.isShuffling ? Color.accentColor : theme.secondaryInk)
                    }
                    .buttonStyle(.borderless)
                    .help(spotify.isShuffling ? "Karıştırma Açık" : "Karıştır")

                    Button {
                        spotify.toggleRepeat()
                    } label: {
                        Image(systemName: "repeat")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(spotify.isRepeating ? Color.accentColor : theme.secondaryInk)
                    }
                    .buttonStyle(.borderless)
                    .help(spotify.isRepeating ? "Tekrarlama Açık" : "Tekrarla")
                }

                if spotify.isWebAPIConnected {
                    Button {
                        spotify.reloadPlaylists()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryInk)
                    }
                    .buttonStyle(.borderless)
                    .help("Playlistleri Yenile")

                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.caption2)
                            .foregroundStyle(showSettings ? Color.accentColor : theme.secondaryInk)
                    }
                    .buttonStyle(.borderless)
                    .help("Spotify Bağlantı Ayarları")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.chromeBackground)

            Rectangle()
                .fill(theme.subtleBorder)
                .frame(height: 1)

            if !spotify.isWebAPIConnected || showSettings {
                setupView
            } else {
                // Segmented tabs: Playlistlerim | Ara
                Picker("", selection: $activeTab) {
                    ForEach(SpotifyPopoverTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if let err = spotify.webAPIError, !err.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(theme.primaryInk)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            spotify.webAPIError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }

                switch activeTab {
                case .playlists:
                    playlistsView
                case .search:
                    searchView
                }
            }
        }
        .frame(width: 320, height: 390)
        .background(theme.surfaceBackground)
        .preferredColorScheme(theme.preferredColorScheme)
        .onAppear {
            clientIDDraft = spotify.webAPI.clientID
            if spotify.isWebAPIConnected {
                spotify.loadPlaylistsIfNeeded()
            }
            if spotify.isRunning {
                spotify.refreshStateFromSpotify()
            }
        }
    }

    // MARK: - Playlists Tab

    private var playlistsView: some View {
        Group {
            if let playlist = spotify.selectedPlaylist {
                VStack(spacing: 0) {
                    // Playlist detail header
                    HStack(spacing: 8) {
                        Button {
                            spotify.selectedPlaylist = nil
                            spotify.selectedPlaylistTracks = []
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Tüm Playlistlere Dön")

                        Text(playlist.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.primaryInk)
                            .lineLimit(1)

                        Spacer()

                        Button {
                            spotify.playURI(playlist.uri)
                        } label: {
                            Label("Çal", systemImage: "play.fill")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                    Rectangle()
                        .fill(theme.subtleBorder)
                        .frame(height: 1)

                    if spotify.isLoadingPlaylistTracks {
                        Spacer()
                        ProgressView("Şarkılar yükleniyor…")
                            .controlSize(.small)
                            .font(.caption)
                        Spacer()
                    } else if spotify.selectedPlaylistTracks.isEmpty {
                        Spacer()
                        Text("Bu playlistte gösterilecek şarkı bulunamadı.")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryInk)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(spotify.selectedPlaylistTracks) { track in
                                    Button {
                                        spotify.playURI(track.uri, inContext: playlist.uri)
                                    } label: {
                                        HStack(spacing: 8) {
                                            SpotifyArtworkThumbnail(urlString: track.imageURL ?? "", size: 28, theme: theme)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(track.name)
                                                    .font(.caption.weight(.medium))
                                                    .foregroundStyle(theme.primaryInk)
                                                    .lineLimit(1)
                                                Text(track.artist)
                                                    .font(.caption2)
                                                    .foregroundStyle(theme.secondaryInk)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Text(SpotifySidebarCardView.formatTime(Double(track.durationMs) / 1000.0))
                                                .font(.system(size: 9).monospacedDigit())
                                                .foregroundStyle(theme.secondaryInk.opacity(0.75))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            } else if spotify.isLoadingPlaylists {
                Spacer()
                ProgressView("Playlistler yükleniyor…")
                    .controlSize(.small)
                    .font(.caption)
                Spacer()
            } else if spotify.playlists.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.title3)
                        .foregroundStyle(theme.secondaryInk.opacity(0.6))
                    Text("Playlist bulunamadı")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                    Button("Yenile") { spotify.reloadPlaylists() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(spotify.playlists) { pl in
                            HStack(spacing: 8) {
                                Button {
                                    spotify.openPlaylist(pl)
                                } label: {
                                    HStack(spacing: 8) {
                                        SpotifyArtworkThumbnail(urlString: pl.imageURL ?? "", size: 32, theme: theme)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(pl.name)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(theme.primaryInk)
                                                .lineLimit(1)
                                            Text("\(pl.trackCount) parça")
                                                .font(.caption2)
                                                .foregroundStyle(theme.secondaryInk)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    spotify.playURI(pl.uri)
                                } label: {
                                    Image(systemName: "play.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 24, height: 24)
                                        .background(Color.accentColor.opacity(0.12), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Bu Playlisti Çal")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Search Tab

    private var searchView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                TextField("Şarkı, sanatçı veya playlist ara…", text: Binding(
                    get: { spotify.searchQuery },
                    set: { spotify.scheduleSearch($0) }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(theme.primaryInk)

                if !spotify.searchQuery.isEmpty {
                    Button {
                        spotify.scheduleSearch("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.chromeBackground, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.subtleBorder, lineWidth: 0.8))
            .padding(.horizontal, 12)

            if spotify.isSearching {
                Spacer()
                ProgressView("Aranıyor…")
                    .controlSize(.small)
                    .font(.caption)
                Spacer()
            } else if spotify.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(theme.secondaryInk.opacity(0.5))
                    Text("Spotify'da şarkı veya playlist arayın")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
                Spacer()
            } else if spotify.searchResults.tracks.isEmpty && spotify.searchResults.playlists.isEmpty {
                Spacer()
                Text("Sonuç bulunamadı.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !spotify.searchResults.tracks.isEmpty {
                            Text("ŞARKILAR")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.secondaryInk)
                                .padding(.horizontal, 12)
                                .padding(.top, 4)

                            ForEach(spotify.searchResults.tracks) { track in
                                Button {
                                    spotify.playURI(track.uri)
                                } label: {
                                    HStack(spacing: 8) {
                                        SpotifyArtworkThumbnail(urlString: track.imageURL ?? "", size: 28, theme: theme)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(track.name)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(theme.primaryInk)
                                                .lineLimit(1)
                                            Text(track.artist)
                                                .font(.caption2)
                                                .foregroundStyle(theme.secondaryInk)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(theme.secondaryInk)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !spotify.searchResults.playlists.isEmpty {
                            Text("PLAYLİSTLER")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.secondaryInk)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)

                            ForEach(spotify.searchResults.playlists) { pl in
                                HStack(spacing: 8) {
                                    Button {
                                        activeTab = .playlists
                                        spotify.openPlaylist(pl)
                                    } label: {
                                        HStack(spacing: 8) {
                                            SpotifyArtworkThumbnail(urlString: pl.imageURL ?? "", size: 28, theme: theme)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(pl.name)
                                                    .font(.caption.weight(.medium))
                                                    .foregroundStyle(theme.primaryInk)
                                                    .lineLimit(1)
                                                if !pl.ownerName.isEmpty {
                                                    Text(pl.ownerName)
                                                        .font(.caption2)
                                                        .foregroundStyle(theme.secondaryInk)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        spotify.playURI(pl.uri)
                                    } label: {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Free PKCE OAuth Setup View

    private var setupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(spotify.isWebAPIConnected ? "Spotify Bağlantı Ayarları" : "Spotify Hesabını Bağla")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryInk)
                    Spacer()
                    if spotify.isWebAPIConnected {
                        Button("Kapat") { showSettings = false }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }

                Text("Playlistlerini görmek ve şarkı aramak için ücretsiz bir Spotify Client ID girip tek tıkla bağlanabilirsin:")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryInk)

                VStack(alignment: .leading, spacing: 5) {
                    Text("1. developer.spotify.com/dashboard → Create App (Web API seç)")
                    Text("2. Redirect URI alanına şu adresi ekle:")
                }
                .font(.caption2)
                .foregroundStyle(theme.primaryInk)

                HStack(spacing: 6) {
                    Text(SpotifyWebAPIService.redirectURI)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.primaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(SpotifyWebAPIService.redirectURI, forType: .string)
                        copiedRedirectURI = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.8))
                            copiedRedirectURI = false
                        }
                    } label: {
                        Text(copiedRedirectURI ? "Kopyalandı" : "Kopyala")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.chromeBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.subtleBorder, lineWidth: 0.8))

                VStack(alignment: .leading, spacing: 4) {
                    Text("3. Uygulamanın Client ID'sini buraya yapıştır:")
                        .font(.caption2)
                        .foregroundStyle(theme.primaryInk)

                    TextField("Spotify Client ID", text: $clientIDDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.primaryInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(theme.chromeBackground, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.subtleBorder, lineWidth: 0.8))
                }

                if let err = spotify.webAPIError, !err.isEmpty {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 8) {
                    Button {
                        showSettings = false
                        spotify.connectWebAPI(clientID: clientIDDraft)
                    } label: {
                        if spotify.isAuthenticating {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Bağlanıyor…")
                            }
                        } else {
                            Label(spotify.isWebAPIConnected ? "Yeniden Bağlan" : "Spotify ile Bağlan", systemImage: "link")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || spotify.isAuthenticating)

                    if spotify.isWebAPIConnected {
                        Button("Bağlantıyı Kes", role: .destructive) {
                            spotify.disconnectWebAPI()
                            showSettings = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Button("Spotify Developer Dashboard'u Aç ↗") {
                    if let url = URL(string: "https://developer.spotify.com/dashboard") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
            .padding(12)
        }
    }
}

// MARK: - Artwork Helper

private struct SpotifyArtworkThumbnail: View {
    let urlString: String
    let size: CGFloat
    let theme: ReadingTheme

    var body: some View {
        Group {
            if let url = URL(string: urlString), !urlString.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.subtleBorder.opacity(0.7), lineWidth: 0.6)
        )
    }

    private var placeholder: some View {
        ZStack {
            theme.chromeBackground
            Image(systemName: "music.note")
                .font(.system(size: max(10, size * 0.4)))
                .foregroundStyle(theme.secondaryInk.opacity(0.65))
        }
    }
}
