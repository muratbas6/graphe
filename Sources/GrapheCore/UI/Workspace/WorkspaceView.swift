import AppKit
import SwiftUI
import UniformTypeIdentifiers

public extension Notification.Name {
    static let grapheShowToast = Notification.Name("graphe.showToast")
    static let grapheFormatRichText = Notification.Name("graphe.formatRichText")
}

public struct WorkspaceView: View {
    @Bindable public var state: WorkspaceState
    @FocusState private var isSearchFieldFocused: Bool
    @State private var isExportingSearchablePDF: Bool = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    public init(state: WorkspaceState) {
        self.state = state
    }

    public var body: some View {
        HSplitView {
            if state.showLeftSidebar {
                LibrarySidebarView(
                    state: state,
                    onRequestOpenPDF: { presentOpenPanel(forSecondary: false) },
                    onRequestOpenSecondaryPDF: { presentOpenPanel(forSecondary: true) }
                )
            }

            centerArea
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

            if state.showRightInspector && state.activeStandaloneNotebook == nil {
                InspectorPanelView(state: state)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(state.theme.windowBackground)
        .preferredColorScheme(state.theme.preferredColorScheme)
        .toolbarBackground(state.theme.chromeBackground, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.toggleLeftSidebar()
                    }
                } label: {
                    Label("Sol Panel", systemImage: "sidebar.leading")
                }
                .help("Sol Paneli Göster/Gizle (⌥⌘1)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    presentOpenPanel(forSecondary: false)
                } label: {
                    Label("PDF Aç", systemImage: "plus")
                }
                .help("PDF Dosyası Aç (⌘O)")

                Button {
                    state.openSearch()
                } label: {
                    Label("Ara", systemImage: "magnifyingglass")
                }
                .disabled(state.activeTab == nil)
                .help("Belgede Ara (⌘F)")

                Picker("Tema", selection: Binding(
                    get: { state.theme },
                    set: { state.setTheme($0) }
                )) {
                    ForEach(ReadingTheme.allCases) { theme in
                        Label(theme.displayName, systemImage: theme.systemImage)
                            .tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .help("Okuma Teması")

                Menu {
                    Section("Bölünmüş Görünüm") {
                        Button {
                            presentOpenPanel(forSecondary: true)
                        } label: {
                            Label("Yan Yana 2. PDF Aç", systemImage: "rectangle.split.2x1")
                        }

                        Button {
                            state.splitCurrentDocumentSelf()
                        } label: {
                            Label("Aynı PDF'i Böl", systemImage: "doc.on.doc")
                        }

                        if let tab = state.activeTab, tab.isSplit {
                            Button {
                                state.toggleSyncScroll()
                            } label: {
                                Label(
                                    tab.syncScrollEnabled ? "Senkron Kaydırmayı Kapat" : "Senkron Kaydırmayı Aç",
                                    systemImage: tab.syncScrollEnabled ? "link.circle.fill" : "link.circle"
                                )
                            }
                        }
                    }

                    Section("Sayfa & OCR") {
                        Button {
                            state.toggleTwoUpBookMode()
                        } label: {
                            Label(
                                state.isTwoUpBookMode ? "Tek Sayfa Görünümü" : "Çift Sayfa Kitap Görünümü (⇧⌘2)",
                                systemImage: state.isTwoUpBookMode ? "doc" : "book"
                            )
                        }

                        Button {
                            state.toggleAutoCropForActiveDocument()
                        } label: {
                            Label(
                                state.isActiveDocumentAutoCropped ? "Otomatik Kenar Kırpmayı Kapat" : "Otomatik Kenar Kırp (⇧⌘C)",
                                systemImage: "crop"
                            )
                        }

                        Button {
                            state.toggleReadingRuler()
                        } label: {
                            Label(
                                state.isReadingRulerEnabled ? "Okuma Cetvelini Kapat (⇧⌘R)" : "Okuma Cetvelini Aç (⇧⌘R)",
                                systemImage: "line.3.horizontal.decrease"
                            )
                        }

                        Button {
                            state.runOCROnCurrentPage()
                        } label: {
                            Label("Bu Sayfayı OCR Yap (⌥⌘O)", systemImage: "text.viewfinder")
                        }

                        Button {
                            state.runOCROnEntireDocument()
                        } label: {
                            Label("Tüm Kitabı Arka Planda OCR Yap", systemImage: "doc.text.viewfinder")
                        }

                        if state.currentPageOCRResult != nil {
                            Button {
                                state.showOCRTextSheet = true
                            } label: {
                                Label("Bu Sayfanın OCR Metnini Göster", systemImage: "doc.plaintext")
                            }
                        }

                        Button {
                            presentSearchablePDFExportPanel()
                        } label: {
                            Label("Aranabilir PDF Olarak Dışa Aktar...", systemImage: "square.and.arrow.up")
                        }
                        .disabled(state.activeDocumentOCRCount == 0)
                    }

                    Section("Kitap & Atıf") {
                        Button {
                            state.openMetadataEditorForActiveDocument()
                        } label: {
                            Label("Kitap Metadata & Adlandırma...", systemImage: "info.circle")
                        }

                        Menu {
                            ForEach(CitationStyle.allCases) { style in
                                Button(style.rawValue) {
                                    state.copyActiveDocumentCitation(style: style, includeQuote: state.activeSelection != nil)
                                    showToast("Atıf panoya kopyalandı (\(style.rawValue)).")
                                }
                            }
                        } label: {
                            Label("Atıf Kopyala", systemImage: "text.quote")
                        }
                    }
                } label: {
                    Label("Araçlar", systemImage: "slider.horizontal.3")
                }
                .disabled(state.activeTab == nil)
                .help("Bölünmüş Görünüm, Kenar Kırpma ve OCR Araçları")

                Button {
                    state.toggleSnapshotMode()
                } label: {
                    Label("Bölge Kırp", systemImage: "camera.viewfinder")
                        .foregroundStyle(state.isSnapshotMode ? state.theme.accentColor : state.theme.primaryInk)
                }
                .disabled(state.activeTab == nil)
                .help(state.isSnapshotMode ? "Bölge Kırpmayı İptal Et (⇧⌘X)" : "PDF'ten Bölge Kırp ve Deftere Gönder (⇧⌘X)")

                if !state.showLeftSidebar {
                    SpotifyToolbarButtonView(spotify: state.spotify, theme: state.theme)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.toggleRightInspector()
                    }
                } label: {
                    Label("Sağ Panel", systemImage: "sidebar.trailing")
                }
                .help("Sağ Paneli Göster/Gizle (⌥⌘2)")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .alert("İşlem Hatası", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("Tamam", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .sheet(isPresented: $state.showOCRTextSheet) {
            ocrTextSheet
        }
        .sheet(item: $state.editingMetadataDocument) { doc in
            MetadataEditorSheet(document: doc, state: state)
        }
        .background {
            // ⌘1–⌘9 tab switching shortcuts
            Group {
                ForEach(0..<9, id: \.self) { idx in
                    Button("") {
                        if idx < state.tabs.count {
                            state.selectTab(id: state.tabs[idx].id)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: [.command])
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .overlay {
            if state.showCommandPalette {
                CommandPaletteView(
                    state: state,
                    onDismiss: { state.showCommandPalette = false },
                    onTriggerLatexExport: {
                        presentLatexPDFExportPanel()
                    }
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(state.theme.accentColor)
                    Text(toastMessage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(state.theme.primaryInk)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(state.theme.cardBackground, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(state.theme.subtleBorder, lineWidth: 1)
                )
                .shadow(color: state.theme.cardShadowColor, radius: 12, y: 4)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .grapheShowToast)) { notification in
            if let message = notification.userInfo?["message"] as? String {
                showToast(message)
            }
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            toastMessage = message
        }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                toastMessage = nil
            }
        }
    }

    private var ocrTextSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    "Apple Vision OCR Metni — Sayfa \((state.currentPageOCRResult?.pageIndex ?? 0) + 1)",
                    systemImage: "text.viewfinder"
                )
                .font(.headline)
                Spacer()
                Button("Panoya Kopyala") {
                    if let text = state.currentPageOCRResult?.fullText {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Kapat") {
                    state.showOCRTextSheet = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let ocr = state.currentPageOCRResult {
                ScrollView {
                    Text(ocr.fullText)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(state.theme.primaryInk)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(state.theme.subtleBorder, lineWidth: 1)
                )
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
        .background(state.theme.chromeBackground)
        .preferredColorScheme(state.theme.preferredColorScheme)
    }

    private func presentSearchablePDFExportPanel() {
        guard let pane = state.activeTab?.activePane else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(pane.metadata.title) (OCR).pdf"
        panel.title = "Aranabilir PDF Olarak Dışa Aktar"
        if panel.runModal() == .OK, let url = panel.url {
            let sourceURL = pane.url
            let docHash = pane.documentHash
            guard !docHash.isEmpty else {
                state.errorMessage = VisionOCRError.documentOpenFailed.localizedDescription
                return
            }
            let libraryDatabase = state.libraryDatabase
            let ocrService = state.ocrService
            let workspaceState = state
            isExportingSearchablePDF = true
            Task.detached(priority: .userInitiated) {
                do {
                    let ocrPages = libraryDatabase.fetchAllOCRPages(docHash: docHash)
                    try ocrService.exportSearchablePDF(
                        sourceURL: sourceURL,
                        ocrPages: ocrPages,
                        destinationURL: url
                    )
                    await MainActor.run {
                        isExportingSearchablePDF = false
                        NotificationCenter.default.post(
                            name: .grapheShowToast,
                            object: nil,
                            userInfo: ["message": "Aranabilir PDF başarıyla dışa aktarıldı."]
                        )
                    }
                } catch {
                    await MainActor.run {
                        isExportingSearchablePDF = false
                        workspaceState.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private var centerArea: some View {
        let totalTabs = state.tabs.count + state.openStandaloneNotebooks.count
        return VStack(spacing: 0) {
            if totalTabs > 1 || !state.openStandaloneNotebooks.isEmpty {
                tabBar
                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)
            }

            if state.isSearchVisible, state.activeTab != nil, state.activeStandaloneNotebook == nil {
                searchBar
                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)
            }

            if let progress = state.ocrProgress {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 140)
                    Text("Apple Vision OCR: \(progress.completedPages) / \(progress.totalPages) sayfa (\(progress.documentTitle))")
                        .font(.caption)
                        .foregroundStyle(state.theme.primaryInk)
                        .lineLimit(1)
                    Spacer()
                    Button("İptal") {
                        state.cancelOCR()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(state.theme.chromeBackground)
                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)
            }

            if isExportingSearchablePDF {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Aranabilir PDF dışa aktarılıyor...")
                        .font(.caption)
                        .foregroundStyle(state.theme.primaryInk)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(state.theme.chromeBackground)
                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)
            }

            if state.activeStandaloneNotebook != nil {
                OneNoteWorkspaceView(state: state, isFullCanvasMode: true)
            } else if let tab = state.activeTab {
                if let secondary = tab.secondaryPane {
                    HSplitView {
                        paneView(for: tab.primaryPane, side: .primary, tab: tab)
                        paneView(for: secondary, side: .secondary, tab: tab)
                    }
                } else {
                    paneView(for: tab.primaryPane, side: .primary, tab: tab)
                }
            } else {
                emptyWorkspaceView
            }
        }
        .background(state.theme.windowBackground)
        .onChange(of: state.isSearchVisible) { _, visible in
            if visible {
                isSearchFieldFocused = true
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(state.theme.secondaryInk)
                    .font(.caption)

                TextField("Belgede ara...", text: Binding(
                    get: { state.searchQuery },
                    set: { state.scheduleSearch($0) }
                ))
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(state.theme.primaryInk)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    state.nextSearchMatch()
                }
                .onExitCommand {
                    state.closeSearch()
                }

                if !state.searchQuery.isEmpty {
                    if state.searchMatches.isEmpty {
                        Text("Sonuç yok")
                            .font(.caption2)
                            .foregroundStyle(state.theme.secondaryInk)
                    } else {
                        Text("\(state.currentMatchIndex + 1) / \(state.searchMatches.count)")
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(state.theme.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(state.theme.accentSoftBackground, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(state.theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(state.theme.subtleBorder, lineWidth: 1)
            )

            HStack(spacing: 4) {
                Button {
                    state.previousSearchMatch()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(state.searchMatches.isEmpty ? state.theme.secondaryInk.opacity(0.45) : state.theme.primaryInk)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.searchMatches.isEmpty)
                .help("Önceki Eşleşme (⇧⌘G)")

                Button {
                    state.nextSearchMatch()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(state.searchMatches.isEmpty ? state.theme.secondaryInk.opacity(0.45) : state.theme.primaryInk)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(state.searchMatches.isEmpty)
                .help("Sonraki Eşleşme (⌘G)")
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(state.theme.cardBackground.opacity(0.75), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(state.theme.subtleBorder, lineWidth: 1)
            )

            Button {
                state.closeSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(state.theme.secondaryInk)
            }
            .buttonStyle(.borderless)
            .help("Aramayı Kapat (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(state.theme.chromeBackground)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.tabs) { tab in
                    let isSelected = (state.activeStandaloneNotebookID == nil && tab.id == state.activeTab?.id)
                    WorkspaceTabPill(
                        title: tab.displayTitle,
                        isSelected: isSelected,
                        theme: state.theme,
                        leadingIcon: tab.isSplit ? "rectangle.split.2x1" : nil,
                        leadingDotColor: nil,
                        closeHelp: "Sekmeyi Kapat",
                        onSelect: { state.selectTab(id: tab.id) },
                        onClose: { state.closeTab(id: tab.id) }
                    )
                    .contextMenu {
                        Button("Sekmeyi Kapat") {
                            state.closeTab(id: tab.id)
                        }
                        if state.tabs.count > 1 {
                            Button("Diğer Sekmeleri Kapat") {
                                let others = state.tabs.filter { $0.id != tab.id }.map(\.id)
                                for otherID in others {
                                    state.closeTab(id: otherID)
                                }
                            }
                        }
                    }
                }

                ForEach(state.openStandaloneNotebooks) { nb in
                    let isSelected = (state.activeStandaloneNotebookID == nb.id)
                    WorkspaceTabPill(
                        title: nb.title,
                        isSelected: isSelected,
                        theme: state.theme,
                        leadingIcon: nil,
                        leadingDotColor: nb.color.swiftUIColor,
                        closeHelp: "Defter Sekmesini Kapat",
                        onSelect: { state.openStandaloneNotebook(id: nb.id) },
                        onClose: { state.closeStandaloneNotebookTab(id: nb.id) }
                    )
                    .contextMenu {
                        Button("Sekmeyi Kapat") {
                            state.closeStandaloneNotebookTab(id: nb.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(state.theme.chromeBackground)
    }

    private func paneView(for pane: ReaderPaneState, side: PaneSide, tab: TabSession) -> some View {
        ReaderPaneView(
            pane: pane,
            side: side,
            isActive: tab.activeSide == side,
            isSplit: tab.isSplit,
            isBookmarked: state.isPageBookmarked(pane.currentPageIndex, forDocumentHash: pane.documentHash),
            theme: state.theme,
            syncScrollSignal: tab.syncScrollEnabled ? state.syncScrollSignal : nil,
            footnoteResolver: state.footnoteResolver,
            annotations: state.annotations(forDocumentHash: pane.documentHash),
            layoutRefreshToken: state.layoutRefreshToken,
            isTwoUpBookMode: state.isTwoUpBookMode,
            isSnapshotMode: state.isSnapshotMode,
            isReadingRulerEnabled: state.isReadingRulerEnabled,
            ocrPageProvider: { pageIndex in
                guard !pane.documentHash.isEmpty else { return nil }
                return state.libraryDatabase.fetchOCRPage(docHash: pane.documentHash, pageIndex: pageIndex)
            },
            onActivate: {
                state.setActiveSide(side)
            },
            onPositionChanged: { pageIndex, scaleFactor in
                state.updatePosition(side: side, pageIndex: pageIndex, scaleFactor: scaleFactor)
            },
            onSelectionChanged: { text in
                state.lookupManualTerm(text)
                state.showRightInspector = true
            },
            onSelectionCaptured: { capture in
                state.updateSelectionCapture(capture)
            },
            onQuickHighlight: { capture, color, _ in
                state.createHighlight(
                    capture: capture,
                    color: color,
                    forDocumentHash: pane.documentHash
                )
            },
            onSendToNotebook: { capture in
                _ = state.sendQuoteToNotebook(
                    quote: capture.text,
                    sourcePageIndex: capture.pageIndex,
                    color: .yellow
                )
            },
            onCopyWithCitation: { capture in
                state.copyCitationToPasteboard(
                    forDocumentHash: pane.documentHash,
                    pageIndex: capture.pageIndex,
                    quote: capture.text,
                    style: .chicago
                )
                showToast("Atıf panoya kopyalandı (Chicago).")
            },
            onScrollNormalized: { normalizedY in
                state.broadcastScroll(from: side, normalizedY: normalizedY)
            },
            onJumpToPage: { pageIndex in
                state.jumpToPage(pageIndex, side: side)
            },
            onGoBack: {
                state.goBack(side: side)
            },
            onGoForward: {
                state.goForward(side: side)
            },
            onZoom: { action in
                state.sendZoom(action, side: side)
            },
            onFootnoteJumpToPage: { targetPage in
                state.jumpToPage(targetPage, side: side, recordHistory: true)
            },
            onFootnoteOpenInSplit: { targetPage in
                state.openFootnoteInSecondarySplit(targetPageIndex: targetPage)
            },
            onFootnotePin: { preview in
                state.pinFootnote(preview)
                state.rightPanelTab = .footnotes
                state.showRightInspector = true
            },
            onToggleBookmark: {
                state.toggleBookmark(pageIndex: pane.currentPageIndex, forDocumentHash: pane.documentHash)
            },
            onCloseSecondary: side == .secondary ? { state.closeSecondarySplit() } : nil,
            onSnapshotCaptured: { image in
                state.handleCapturedSnapshot(image)
            },
            onCancelSnapshotMode: {
                state.isSnapshotMode = false
            },
            onHighlightClicked: { annotation in
                state.focusNotebookCard(for: annotation)
            }
        )
    }

    private var emptyWorkspaceView: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(state.theme.cardBackground)
                    .frame(width: 72, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(state.theme.subtleBorder, lineWidth: 1)
                    )
                    .shadow(color: state.theme.cardShadowColor, radius: state.theme.cardShadowRadius, y: state.theme.cardShadowY)

                Image(systemName: "book.closed.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(state.theme.accentColor)
            }

            VStack(spacing: 6) {
                Text("Graphe")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(state.theme.primaryInk)
                Text("Okumaya başlamak için bir PDF dosyası açın, sürükleyip bırakın veya bağımsız bir defter oluşturun.")
                    .font(.callout)
                    .foregroundStyle(state.theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button {
                    presentOpenPanel(forSecondary: false)
                } label: {
                    Label("PDF Dosyası Aç", systemImage: "folder")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    _ = state.createStandaloneNotebook()
                    state.leftPanelTab = .notebooks
                } label: {
                    Label("Yeni Defter", systemImage: "book.pages")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(state.theme.windowBackground)
    }

    public func presentOpenPanel(forSecondary: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = !forSecondary
        panel.canChooseDirectories = false
        panel.title = forSecondary ? "Yan Yana Açılacak 2. PDF'i Seçin" : "PDF Dosyası Aç"

        if panel.runModal() == .OK {
            if forSecondary, let first = panel.urls.first {
                state.openInSecondarySplit(url: first)
            } else {
                for url in panel.urls {
                    state.openDocument(at: url, inNewTab: true)
                }
            }
        }
    }

    private func presentLatexPDFExportPanel() {
        guard let ownerTitle = state.activeNotebookOwnerTitle else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "\(ownerTitle) - Notlar.pdf"
        panel.title = "Notları LaTeX PDF Olarak Dışa Aktar"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        showToast("LaTeX PDF hazırlanıyor…")
        Task { @MainActor in
            do {
                try await state.exportActiveNotesLatexPDF(to: url, scope: .fullNotebook)
                showToast("LaTeX PDF oluşturuldu: \(url.lastPathComponent)")
                NSWorkspace.shared.open(url)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.pathExtension.lowercased() == "pdf" else { return }
                    Task { @MainActor in
                        state.openDocument(at: url, inNewTab: true)
                    }
                }
            }
        }
        return handled
    }
}

private struct WorkspaceTabPill: View {
    let title: String
    let isSelected: Bool
    let theme: ReadingTheme
    let leadingIcon: String?
    let leadingDotColor: Color?
    let closeHelp: String
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered: Bool = false
    @State private var isCloseHovered: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            if let dotColor = leadingDotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            } else if let icon = leadingIcon {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? theme.accentColor : theme.secondaryInk)
            }

            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? theme.primaryInk : (isHovered ? theme.primaryInk.opacity(0.88) : theme.secondaryInk))
                .lineLimit(1)
                .frame(maxWidth: 210, alignment: .leading)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isCloseHovered ? theme.primaryInk : theme.secondaryInk.opacity(isSelected || isHovered ? 0.85 : 0.45))
                    .frame(width: 16, height: 16)
                    .background(
                        Circle()
                            .fill(isCloseHovered ? theme.hoverFill : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isCloseHovered = hovering
            }
            .help(closeHelp)
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? theme.cardBackground : (isHovered ? theme.hoverFill : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? theme.subtleBorder : Color.clear, lineWidth: 1)
        )
        .shadow(
            color: isSelected ? theme.cardShadowColor : .clear,
            radius: isSelected ? 4 : 0,
            y: isSelected ? 1 : 0
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}
