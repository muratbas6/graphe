import AppKit
import GrapheCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class GrapheAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []

    var onOpenURLs: (([URL]) -> Void)? {
        didSet {
            guard let handler = onOpenURLs, !pendingURLs.isEmpty else { return }
            let urls = pendingURLs
            pendingURLs.removeAll()
            handler(urls)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpenURLs {
            onOpenURLs(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}

@main
struct GrapheApp: App {
    @NSApplicationDelegateAdaptor(GrapheAppDelegate.self) private var appDelegate
    @State private var state = WorkspaceState()

    var body: some Scene {
        WindowGroup("Graphe") {
            WorkspaceView(state: state)
                .onAppear {
                    appDelegate.onOpenURLs = { urls in
                        for url in urls where url.pathExtension.lowercased() == "pdf" {
                            state.openDocument(at: url, inNewTab: true)
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Yeni Bağımsız Defter") {
                    _ = state.createStandaloneNotebook()
                    state.leftPanelTab = .notebooks
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("PDF Aç...") {
                    openPDFDialog(forSecondary: false)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Yan Yana 2. PDF Aç...") {
                    openPDFDialog(forSecondary: true)
                }
                .keyboardShortcut("\\", modifiers: [.command])
                .disabled(state.activeTab == nil)

                Button("Aynı PDF'i Yan Yana Böl") {
                    state.splitCurrentDocumentSelf()
                }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(state.activeTab == nil)

                Divider()

                Button("Aktif Sekmeyi Kapat") {
                    if let nbID = state.activeStandaloneNotebookID {
                        state.closeStandaloneNotebookTab(id: nbID)
                    } else if let id = state.activeTab?.id {
                        state.closeTab(id: id)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(state.activeTab == nil && state.activeStandaloneNotebookID == nil)

                Divider()

                Button("Tüm Veriyi Yedekle (.graphebackup)...") {
                    exportBackupArchive()
                }

                Button("Yedekten Geri Yükle...") {
                    importBackupArchive()
                }
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Geri Al") {
                    performUndo()
                }
                .keyboardShortcut("z", modifiers: [.command])

                Button("Yinele") {
                    performRedo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(after: .textEditing) {
                Button("Belgede Ara...") {
                    state.openSearch()
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(state.activeTab == nil)

                Button("Sonraki Eşleşme") {
                    state.nextSearchMatch()
                }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(state.searchMatches.isEmpty)

                Button("Önceki Eşleşme") {
                    state.previousSearchMatch()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(state.searchMatches.isEmpty)
            }

            CommandMenu("Görünüm") {
                Button("Önceki Konuma Dön") {
                    state.goBack()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!(state.activeTab?.activePane.canGoBack ?? false))

                Button("Sonraki Konuma İleri Git") {
                    state.goForward()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(!(state.activeTab?.activePane.canGoForward ?? false))

                Button(state.isCurrentPageBookmarked ? "Yer İmini Kaldır" : "Bu Sayfaya Yer İmi Ekle") {
                    state.toggleBookmarkForCurrentPage()
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(state.activeTab == nil)

                Divider()

                Button("Sol Paneli Göster/Gizle") {
                    state.toggleLeftSidebar()
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Sağ Paneli Göster/Gizle") {
                    state.toggleRightInspector()
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Button("Odak Modu (Panelleri Aç/Kapat)") {
                    state.toggleFocusMode()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Hızlı Komut Paleti…") {
                    state.showCommandPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button(state.isReadingRulerEnabled ? "Okuma Cetvelini Kapat" : "Okuma Cetvelini Aç") {
                    state.toggleReadingRuler()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.activeTab == nil)

                Divider()

                Button("Yakınlaştır") {
                    state.sendZoom(.zoomIn)
                }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(state.activeTab == nil)

                Button("Uzaklaştır") {
                    state.sendZoom(.zoomOut)
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(state.activeTab == nil)

                Button("Genişliğe Sığdır") {
                    state.sendZoom(.fitWidth)
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(state.activeTab == nil)

                Divider()

                Button("Senkron Kaydırmayı Aç/Kapat") {
                    state.toggleSyncScroll()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!(state.activeTab?.isSplit ?? false))

                Button("Otomatik Kenar Kırpmayı Aç/Kapat") {
                    state.toggleAutoCropForActiveDocument()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(state.activeTab == nil)

                Button(state.isTwoUpBookMode ? "Tek Sayfa Görünümü" : "Çift Sayfa Kitap Görünümü") {
                    state.toggleTwoUpBookMode()
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])
                .disabled(state.activeTab == nil)

                Divider()

                Button("Bu Sayfayı OCR Yap (Apple Vision)") {
                    state.runOCROnCurrentPage()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(state.activeTab == nil)

                Button("Tüm Kitabı Arka Planda OCR Yap") {
                    state.runOCROnEntireDocument()
                }
                .disabled(state.activeTab == nil)

                Divider()

                ForEach(ReadingTheme.allCases) { theme in
                    Button("Tema: \(theme.displayName)") {
                        state.setTheme(theme)
                    }
                }
            }

            CommandMenu("Notlar") {
                Button("Seçili Metni Vurgula (Ana Fikir)") {
                    state.createHighlightFromActiveSelection(color: .yellow)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(state.activeSelection == nil)

                Button(state.isSnapshotMode ? "Bölge Kırpmayı İptal Et" : "Bölge Kırp (Snapshot)") {
                    state.toggleSnapshotMode()
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(state.activeTab == nil)

                Divider()

                ForEach(HighlightColor.allCases) { color in
                    Button("Vurgula: \(color.fullLabel)") {
                        state.createHighlightFromActiveSelection(color: color)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(color.shortcutDigit)), modifiers: [.option])
                    .disabled(state.activeSelection == nil)
                }

                Divider()

                Button("Kalın (OneNote)") {
                    NotificationCenter.default.post(name: .grapheFormatRichText, object: nil, userInfo: ["action": "bold"])
                }
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(state.activeNotebookOwnerHash == nil)

                Button("İtalik (OneNote)") {
                    NotificationCenter.default.post(name: .grapheFormatRichText, object: nil, userInfo: ["action": "italic"])
                }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(state.activeNotebookOwnerHash == nil)

                Button("Altı Çizili (OneNote)") {
                    NotificationCenter.default.post(name: .grapheFormatRichText, object: nil, userInfo: ["action": "underline"])
                }
                .keyboardShortcut("u", modifiers: [.command])
                .disabled(state.activeNotebookOwnerHash == nil)

                Divider()

                Button("Notları PDF Olarak Dışa Aktar (LaTeX)...") {
                    exportActiveNotesLatexPDF(scope: .fullNotebook)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(state.activeNotebookOwnerHash == nil || state.isExportingLatexPDF)

                Menu("Diğer Dışa Aktarma Seçenekleri") {
                    if let pageID = state.activeNotebookPageID {
                        Button("Sadece Bu Sayfayı PDF Olarak Dışa Aktar (LaTeX)...") {
                            exportActiveNotesLatexPDF(scope: .singlePage(pageID))
                        }
                        .disabled(state.isExportingLatexPDF)
                    }

                    Button("LaTeX Kaynağını (.tex) Kaydet...") {
                        exportActiveNotesLatexSource(scope: .fullNotebook)
                    }

                    Divider()

                    Button("Notları Markdown (.md) Olarak Dışa Aktar...") {
                        exportActiveNotesMarkdown()
                    }
                    .disabled(state.activeDocumentAnnotations.isEmpty && state.activePageContainers.isEmpty)

                    Button("OneNote Defterini Markdown (.md) Olarak Dışa Aktar...") {
                        exportActiveNotebookMarkdown()
                    }
                }
                .disabled(state.activeNotebookOwnerHash == nil)

                Button("Kitap Metadatasını Düzenle...") {
                    state.openMetadataEditorForActiveDocument()
                }
                .disabled(state.activeTab == nil)

                Divider()

                Button("Atıf Kopyala (Chicago)") {
                    state.copyActiveDocumentCitation(style: .chicago, includeQuote: state.activeSelection != nil)
                    NotificationCenter.default.post(
                        name: .grapheShowToast,
                        object: nil,
                        userInfo: ["message": "Atıf panoya kopyalandı (Chicago)."]
                    )
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(state.activeTab == nil)

                Menu("Diğer Atıf Stilleri") {
                    ForEach(CitationStyle.allCases) { style in
                        Button(style.rawValue) {
                            state.copyActiveDocumentCitation(style: style, includeQuote: state.activeSelection != nil)
                            NotificationCenter.default.post(
                                name: .grapheShowToast,
                                object: nil,
                                userInfo: ["message": "Atıf panoya kopyalandı (\(style.rawValue))."]
                            )
                        }
                    }
                }
                .disabled(state.activeTab == nil)
            }
        }
    }

    private func performUndo() {
        // 1) Odak bir metin alanındaysa: yalnızca o alanın kendi geçmişi kullanılır.
        //    Kutu yeni/boşsa bile Graphe'nin PDF vurgu geçmişine düşüp yanlışlıkla vurgu silme!
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextView {
            if let um = responder.undoManager, um.canUndo, !um.isUndoing, !um.isRedoing {
                um.undo()
            }
            return
        }
        // 2) Aksi halde yalnızca Graphe'nin kendi (highlight / OneNote kutu) geçmişi.
        if state.canUndo {
            state.undo()
        }
    }

    private func performRedo() {
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextView {
            if let um = responder.undoManager, um.canRedo, !um.isUndoing, !um.isRedoing {
                um.redo()
            }
            return
        }
        if state.canRedo {
            state.redo()
        }
    }

    private func exportBackupArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "graphebackup") ?? .zip]
        panel.allowsOtherFileTypes = true
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate]
        panel.nameFieldStringValue = "Graphe-Yedek-\(df.string(from: Date())).graphebackup"
        panel.title = "Tüm Graphe Verisini Yedekle"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try state.createBackupArchive(to: url)
                NotificationCenter.default.post(
                    name: .grapheShowToast,
                    object: nil,
                    userInfo: ["message": "Yedek başarıyla kaydedildi."]
                )
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func importBackupArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "graphebackup") ?? .zip, .zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Graphe Yedeğinden Geri Yükle"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try state.restoreBackupArchive(from: url)
                NotificationCenter.default.post(
                    name: .grapheShowToast,
                    object: nil,
                    userInfo: ["message": "Yedek başarıyla geri yüklendi."]
                )
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func exportActiveNotesLatexPDF(scope: LatexExportScope) {
        guard let ownerTitle = state.activeNotebookOwnerTitle else { return }
        let suffix: String
        if case .singlePage = scope, let pageTitle = state.activeNotebookPage?.title, !pageTitle.isEmpty {
            suffix = " - \(pageTitle).pdf"
        } else {
            suffix = " - Notlar.pdf"
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "\(ownerTitle)\(suffix)"
        panel.title = "Notları LaTeX PDF Olarak Dışa Aktar"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        NotificationCenter.default.post(
            name: .grapheShowToast,
            object: nil,
            userInfo: ["message": "LaTeX PDF hazırlanıyor…"]
        )
        Task { @MainActor in
            do {
                try await state.exportActiveNotesLatexPDF(to: url, scope: scope)
                NotificationCenter.default.post(
                    name: .grapheShowToast,
                    object: nil,
                    userInfo: ["message": "LaTeX PDF oluşturuldu: \(url.lastPathComponent)"]
                )
                NSWorkspace.shared.open(url)
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private func exportActiveNotesLatexSource(scope: LatexExportScope) {
        guard let artifact = state.buildActiveLatexArtifact(scope: scope),
              let ownerTitle = state.activeNotebookOwnerTitle else { return }
        let panel = NSSavePanel()
        let texType = UTType(filenameExtension: "tex") ?? .plainText
        panel.allowedContentTypes = [texType]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "\(ownerTitle) - Notlar.tex"
        panel.title = "LaTeX Kaynağını (.tex) Kaydet"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try artifact.texSource.write(to: url, atomically: true, encoding: .utf8)
                NotificationCenter.default.post(
                    name: .grapheShowToast,
                    object: nil,
                    userInfo: ["message": "LaTeX kaynağı (.tex) kaydedildi."]
                )
            } catch {
                state.errorMessage = "LaTeX kaynağı kaydedilemedi: \(error.localizedDescription)"
            }
        }
    }

    private func exportActiveNotesMarkdown() {
        if state.activeDocumentAnnotations.isEmpty {
            exportActiveNotebookMarkdown()
            return
        }
        guard let markdown = state.exportActiveDocumentMarkdown(),
              let pane = state.activeTab?.activePane else { return }
        let panel = NSSavePanel()
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [markdownType]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "\(pane.metadata.title) - Notlar.md"
        panel.title = "Notları Markdown Olarak Dışa Aktar"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                NotificationCenter.default.post(
                    name: .grapheShowToast,
                    object: nil,
                    userInfo: ["message": "Notlar Markdown olarak dışa aktarıldı."]
                )
            } catch {
                state.errorMessage = "Notlar dışa aktarılamadı: \(error.localizedDescription)"
            }
        }
    }

    private func exportActiveNotebookMarkdown() {
        guard let markdown = state.exportActiveNotebookMarkdown(),
              let pane = state.activeTab?.activePane else { return }
        let panel = NSSavePanel()
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [markdownType]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "\(pane.metadata.title) - Defter.md"
        panel.title = "OneNote Defterini Markdown Olarak Dışa Aktar"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                NotificationCenter.default.post(
                    name: .grapheShowToast,
                    object: nil,
                    userInfo: ["message": "OneNote defteri Markdown olarak dışa aktarıldı."]
                )
            } catch {
                state.errorMessage = "Defter dışa aktarılamadı: \(error.localizedDescription)"
            }
        }
    }

    private func openPDFDialog(forSecondary: Bool) {
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
}
