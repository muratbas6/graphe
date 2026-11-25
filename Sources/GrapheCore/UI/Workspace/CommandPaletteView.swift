#if os(macOS)
import SwiftUI

public struct CommandPaletteItem: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let icon: String
    public let shortcut: String?
    public let category: String
    public let action: @MainActor () -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: String,
        shortcut: String? = nil,
        category: String,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.shortcut = shortcut
        self.category = category
        self.action = action
    }
}

public struct CommandPaletteView: View {
    @Bindable public var state: WorkspaceState
    public let onDismiss: () -> Void
    public let onTriggerLatexExport: () -> Void

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    public init(
        state: WorkspaceState,
        onDismiss: @escaping () -> Void,
        onTriggerLatexExport: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onDismiss = onDismiss
        self.onTriggerLatexExport = onTriggerLatexExport
    }

    private var filteredItems: [CommandPaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        var results: [CommandPaletteItem] = []

        // 1) Direct page jump if user typed a number (e.g. "42")
        if let pane = state.activeTab?.activePane,
           let pageNum = Int(trimmed),
           pageNum >= 1 && pageNum <= pane.metadata.pageCount {
            results.append(
                CommandPaletteItem(
                    id: "jump-page-\(pageNum)",
                    title: "Sayfa \(pageNum)'e Git",
                    subtitle: "\(pane.metadata.title) (Toplam \(pane.metadata.pageCount) sayfa)",
                    icon: "arrow.right.circle",
                    shortcut: "↵",
                    category: "Gezinme"
                ) {
                    state.jumpToPage(pageNum - 1, recordHistory: true)
                }
            )
        }

        // 2) Core commands
        let commands = buildActionCommands()
        if lower.isEmpty {
            results.append(contentsOf: commands)
        } else {
            results.append(contentsOf: commands.filter {
                $0.title.lowercased().contains(lower)
                    || ($0.subtitle?.lowercased().contains(lower) ?? false)
                    || $0.category.lowercased().contains(lower)
            })
        }

        // 2b) Standalone Notebooks
        let matchingNotebooks = state.standaloneNotebooks.filter { nb in
            lower.isEmpty || nb.title.lowercased().contains(lower)
        }.prefix(lower.isEmpty ? 4 : 10)

        for nb in matchingNotebooks {
            results.append(
                CommandPaletteItem(
                    id: "standalone-nb-\(nb.id.uuidString)",
                    title: nb.title,
                    subtitle: "Bağımsız Defter",
                    icon: "book.pages",
                    shortcut: nil,
                    category: "Defterler"
                ) {
                    state.openStandaloneNotebook(id: nb.id)
                }
            )
        }

        // 3) Library books
        let matchingBooks = state.libraryDocuments.filter { doc in
            if lower.isEmpty { return true }
            return doc.title.lowercased().contains(lower)
                || (doc.author?.lowercased().contains(lower) ?? false)
        }.prefix(lower.isEmpty ? 5 : 12)

        for doc in matchingBooks {
            results.append(
                CommandPaletteItem(
                    id: "book-\(doc.hash)",
                    title: doc.title,
                    subtitle: [doc.author, doc.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                    icon: "book.closed",
                    shortcut: nil,
                    category: "Kütüphane"
                ) {
                    state.openDocument(at: URL(fileURLWithPath: doc.path), inNewTab: true)
                }
            )
        }

        // 4) Active document outline (TOC) when searching
        if !lower.isEmpty, let pane = state.activeTab?.activePane {
            let flatTOC = flattenOutline(pane.metadata.outline)
            for node in flatTOC.filter({ $0.title.lowercased().contains(lower) }).prefix(8) {
                results.append(
                    CommandPaletteItem(
                        id: "toc-\(node.id.uuidString)",
                        title: node.title,
                        subtitle: "İçindekiler · Sayfa \(node.pageIndex + 1)",
                        icon: "list.bullet.indent",
                        shortcut: nil,
                        category: "İçindekiler"
                    ) {
                        state.jumpToPage(node.pageIndex, recordHistory: true)
                    }
                )
            }
        }

        return Array(results.prefix(24))
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(state.theme.secondaryInk)

                    TextField("Komut, kitap, bölüm veya sayfa numarası yazın…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(state.theme.primaryInk)
                        .focused($isSearchFocused)
                        .onSubmit {
                            executeSelected()
                        }

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(state.theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("ESC")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(state.theme.secondaryInk)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(state.theme.subtleBorder.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(state.theme.chromeBackground)

                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)

                // Results list
                let items = filteredItems
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(state.theme.secondaryInk.opacity(0.5))
                        Text("Eşleşen komut veya kitap bulunamadı.")
                            .font(.caption)
                            .foregroundStyle(state.theme.secondaryInk)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                    let isSelected = (idx == selectedIndex)
                                    Button {
                                        execute(item)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: item.icon)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(isSelected ? Color.accentColor : state.theme.secondaryInk)
                                                .frame(width: 18)

                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(item.title)
                                                    .font(.system(size: 12.5, weight: .medium))
                                                    .foregroundStyle(state.theme.primaryInk)
                                                    .lineLimit(1)
                                                if let sub = item.subtitle, !sub.isEmpty {
                                                    Text(sub)
                                                        .font(.caption2)
                                                        .foregroundStyle(state.theme.secondaryInk)
                                                        .lineLimit(1)
                                                }
                                            }

                                            Spacer(minLength: 8)

                                            Text(item.category)
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(state.theme.secondaryInk.opacity(0.75))

                                            if let sc = item.shortcut {
                                                Text(sc)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(state.theme.secondaryInk)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(state.theme.subtleBorder.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7)
                                                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(idx)
                                    .onHover { hovering in
                                        if hovering { selectedIndex = idx }
                                    }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: selectedIndex) { _, newIdx in
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(newIdx, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 520)
            .background(state.theme.surfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(state.theme.subtleBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 24, y: 10)
            .padding(.top, 70)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            selectedIndex = 0
            isSearchFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            let count = filteredItems.count
            if count > 0 {
                selectedIndex = (selectedIndex - 1 + count) % count
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            let count = filteredItems.count
            if count > 0 {
                selectedIndex = (selectedIndex + 1) % count
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private func executeSelected() {
        let items = filteredItems
        guard items.indices.contains(selectedIndex) else { return }
        execute(items[selectedIndex])
    }

    private func execute(_ item: CommandPaletteItem) {
        onDismiss()
        item.action()
    }

    private func flattenOutline(_ nodes: [OutlineItem]) -> [OutlineItem] {
        var acc: [OutlineItem] = []
        for n in nodes {
            acc.append(n)
            acc.append(contentsOf: flattenOutline(n.children))
        }
        return acc
    }

    private func buildActionCommands() -> [CommandPaletteItem] {
        var cmds: [CommandPaletteItem] = []

        cmds.append(CommandPaletteItem(
            id: "cmd-new-standalone-notebook",
            title: "Yeni Bağımsız Defter Oluştur",
            subtitle: "PDF'ten bağımsız tam ekran not defteri aç",
            icon: "book.pages",
            shortcut: "⌘N",
            category: "Defter"
        ) {
            _ = state.createStandaloneNotebook()
            state.leftPanelTab = .notebooks
        })

        if state.activeTab != nil {
            cmds.append(CommandPaletteItem(
                id: "cmd-snapshot",
                title: state.isSnapshotMode ? "Bölge Kırpmayı (Snapshot) Kapat" : "Bölge Kırp (Snapshot)",
                subtitle: "PDF'ten formül veya şekil kırpıp deftere gönder",
                icon: "camera.viewfinder",
                shortcut: "⇧⌘X",
                category: "Araç"
            ) { state.toggleSnapshotMode() })

            cmds.append(CommandPaletteItem(
                id: "cmd-ruler",
                title: state.isReadingRulerEnabled ? "Okuma Cetvelini Kapat" : "Okuma Cetvelini Aç",
                subtitle: "Fareyi takip eden hafif odak satırı",
                icon: "line.3.horizontal.decrease",
                shortcut: "⇧⌘R",
                category: "Görünüm"
            ) { state.toggleReadingRuler() })

            cmds.append(CommandPaletteItem(
                id: "cmd-twoup",
                title: state.isTwoUpBookMode ? "Tek Sayfa Moduna Geç" : "Çift Sayfa Kitap Modu (2-Up)",
                subtitle: "Yan yana iki sayfa görünümü",
                icon: "book",
                shortcut: "⇧⌘2",
                category: "Görünüm"
            ) { state.toggleTwoUpBookMode() })

            cmds.append(CommandPaletteItem(
                id: "cmd-autocrop",
                title: state.isActiveDocumentAutoCropped ? "Otomatik Kenar Kırpmayı Kapat" : "Otomatik Kenar Kırp",
                subtitle: "Boş kenar boşluklarını temizle",
                icon: "crop",
                shortcut: "⇧⌘C",
                category: "Görünüm"
            ) { state.toggleAutoCropForActiveDocument() })

            cmds.append(CommandPaletteItem(
                id: "cmd-bookmark",
                title: state.isCurrentPageBookmarked ? "Bu Sayfanın Yer İmini Kaldır" : "Bu Sayfaya Yer İmi Ekle",
                subtitle: "Hızlı yer imi",
                icon: state.isCurrentPageBookmarked ? "bookmark.slash" : "bookmark",
                shortcut: "⌘D",
                category: "Gezinme"
            ) { state.toggleBookmarkForCurrentPage() })

            cmds.append(CommandPaletteItem(
                id: "cmd-latex-export",
                title: "Notları LaTeX PDF Olarak Dışa Aktar",
                subtitle: "Klasik akademik sade PDF üret",
                icon: "doc.richtext",
                shortcut: "⇧⌘E",
                category: "Dışa Aktar"
            ) { onTriggerLatexExport() })

            cmds.append(CommandPaletteItem(
                id: "cmd-move-folder",
                title: "Aktif PDF'i Klasöre Taşı...",
                subtitle: "Bağlı okuma klasörlerinden veya alt kategorilerden birine taşı",
                icon: "folder.badge.arrow.up",
                shortcut: "⇧⌘M",
                category: "Kitap"
            ) { state.presentMoveToFolder() })

            cmds.append(CommandPaletteItem(
                id: "cmd-metadata",
                title: "Kitap Metadatasını Düzenle & Yeniden Adlandır",
                subtitle: "Başlık, yazar, yıl, yayınevi, ISBN",
                icon: "info.circle",
                shortcut: nil,
                category: "Kitap"
            ) { state.openMetadataEditorForActiveDocument() })

            cmds.append(CommandPaletteItem(
                id: "cmd-cite",
                title: "Atıf Kopyala (Chicago)",
                subtitle: "Aktif sayfa için akademik atıf",
                icon: "text.quote",
                shortcut: "⇧⌘Y",
                category: "Kitap"
            ) {
                state.copyActiveDocumentCitation(style: .chicago, includeQuote: state.activeSelection != nil)
                NotificationCenter.default.post(name: .grapheShowToast, object: nil, userInfo: ["message": "Atıf panoya kopyalandı (Chicago)."])
            })

            cmds.append(CommandPaletteItem(
                id: "cmd-split",
                title: "Aynı Belgeyi Yan Yana Aç (Split)",
                subtitle: "İki farklı sayfayı aynı anda oku",
                icon: "rectangle.split.2x1",
                shortcut: "⌘\\",
                category: "Görünüm"
            ) { state.splitCurrentDocumentSelf() })
        }

        cmds.append(CommandPaletteItem(
            id: "cmd-focus",
            title: "Odak Modu (Panelleri Aç/Kapat)",
            subtitle: "Sol ve sağ panelleri tek tuşla gizle",
            icon: "arrow.up.left.and.arrow.down.right",
            shortcut: "⇧⌘F",
            category: "Görünüm"
        ) { state.toggleFocusMode() })

        for theme in ReadingTheme.allCases {
            cmds.append(CommandPaletteItem(
                id: "cmd-theme-\(theme.rawValue)",
                title: "Tema: \(theme.displayName)",
                subtitle: state.theme == theme ? "Aktif tema" : "Okuma temasını değiştir",
                icon: theme.systemImage,
                shortcut: nil,
                category: "Tema"
            ) { state.setTheme(theme) })
        }

        if state.spotify.isRunning {
            cmds.append(CommandPaletteItem(
                id: "cmd-spotify-toggle",
                title: state.spotify.isPlaying ? "Spotify: Duraklat" : "Spotify: Oynat",
                subtitle: state.spotify.trackName.isEmpty ? nil : "\(state.spotify.trackName) — \(state.spotify.artistName)",
                icon: state.spotify.isPlaying ? "pause.fill" : "play.fill",
                shortcut: nil,
                category: "Spotify"
            ) { state.spotify.playPause() })

            cmds.append(CommandPaletteItem(
                id: "cmd-spotify-next",
                title: "Spotify: Sonraki Parça",
                subtitle: nil,
                icon: "forward.fill",
                shortcut: nil,
                category: "Spotify"
            ) { state.spotify.nextTrack() })
        }

        return cmds
    }
}
#endif
