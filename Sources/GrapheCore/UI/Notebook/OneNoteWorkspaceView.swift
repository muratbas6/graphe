import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct OneNoteWorkspaceView: View {
    @Bindable public var state: WorkspaceState
    public let isFullCanvasMode: Bool

    @State private var focusedContainerID: UUID?
    @State private var activeFormatCommand: RichTextFormatCommand?
    @State private var pageTitleDraft: String = ""
    @State private var renamingSection: NotebookSection?
    @State private var renamingPage: NotebookPage?
    @State private var renameDraft: String = ""
    @State private var pendingDeleteSection: NotebookSection?
    @State private var pendingDeletePage: NotebookPage?
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @State private var userInstalledFonts: [String] = []
    @State private var curatedFonts: [String] = NotebookFontCatalog.curatedBaseFamilies
    @State private var otherSystemFonts: [String] = []
    @State private var showDefaultFontPopover: Bool = false
    @State private var showSelectionFontPopover: Bool = false
    @FocusState private var isPageTitleFocused: Bool

    private static let turkishDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "tr_TR")
        df.dateStyle = .long
        df.timeStyle = .none
        return df
    }()

    public init(state: WorkspaceState, isFullCanvasMode: Bool = false) {
        self.state = state
        self.isFullCanvasMode = isFullCanvasMode
    }

    public var body: some View {
        VStack(spacing: 0) {
            if state.activeNotebookOwnerHash == nil {
                ContentUnavailableView(
                    "Açık Belge veya Defter Yok",
                    systemImage: "book.pages",
                    description: Text("Bir PDF açın veya sol paneldeki Defterler sekmesinden bağımsız bir defter oluşturun.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(state.theme.chromeBackground)
            } else {
                compactHeaderBar
                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)

                if !isFullCanvasMode && state.notesSubTab == .highlights {
                    NotesInspectorView(state: state)
                } else if isFullCanvasMode {
                    HStack(spacing: 0) {
                        fullModeNavigationRail
                        Rectangle()
                            .fill(state.theme.subtleBorder)
                            .frame(width: 1)
                        notebookBody
                    }
                } else {
                    notebookBody
                }
            }
        }
        .background(state.theme.chromeBackground)
        .onAppear {
            if state.activeNotebookOwnerHash != nil && state.notebookSections.isEmpty {
                state.loadNotebookForActiveDocument()
            }
            pageTitleDraft = state.activeNotebookPage?.title ?? ""
            installKeyMonitor()
            loadFontCatalog()
        }
        .onDisappear {
            titleSaveTask?.cancel()
            titleSaveTask = nil
            removeKeyMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .grapheFormatRichText)) { notification in
            let isNotebookActive = isFullCanvasMode || (state.showRightInspector && state.rightPanelTab == .notes && state.notesSubTab == .notebook)
            guard isNotebookActive,
                  let actionKey = notification.userInfo?["action"] as? String else { return }
            switch actionKey {
            case "bold": sendFormat(.bold)
            case "italic": sendFormat(.italic)
            case "underline": sendFormat(.underline)
            default: break
            }
        }
        .onChange(of: state.activeNotebookPageID) { _, _ in
            titleSaveTask?.cancel()
            titleSaveTask = nil
            focusedContainerID = nil
            pageTitleDraft = state.activeNotebookPage?.title ?? ""
        }
        .onChange(of: state.activeNotebookPage?.title) { _, newTitle in
            guard !isPageTitleFocused else { return }
            let title = newTitle ?? ""
            if pageTitleDraft != title {
                pageTitleDraft = title
            }
        }
        .onChange(of: isPageTitleFocused) { _, focused in
            if !focused {
                titleSaveTask?.cancel()
                titleSaveTask = nil
                commitPageTitle()
                if let current = state.activeNotebookPage?.title {
                    pageTitleDraft = current
                }
            }
        }
        .confirmationDialog(
            "Bölümü Sil",
            isPresented: Binding(
                get: { pendingDeleteSection != nil },
                set: { if !$0 { pendingDeleteSection = nil } }
            ),
            presenting: pendingDeleteSection
        ) { sec in
            Button("Bölümü ve Tüm Sayfalarını Sil", role: .destructive) {
                state.deleteNotebookSection(id: sec.id)
                pendingDeleteSection = nil
            }
            Button("İptal", role: .cancel) {
                pendingDeleteSection = nil
            }
        } message: { sec in
            Text("“\(sec.title)” bölümü ve içindeki tüm sayfalar kalıcı olarak silinecek.")
        }
        .confirmationDialog(
            "Sayfayı Sil",
            isPresented: Binding(
                get: { pendingDeletePage != nil },
                set: { if !$0 { pendingDeletePage = nil } }
            ),
            presenting: pendingDeletePage
        ) { page in
            Button("Sayfayı Sil", role: .destructive) {
                state.deleteNotebookPage(id: page.id)
                pendingDeletePage = nil
            }
            Button("İptal", role: .cancel) {
                pendingDeletePage = nil
            }
        } message: { page in
            Text("“\(page.title)” sayfası ve içindeki tüm not kutuları kalıcı olarak silinecek.")
        }
        .sheet(item: $renamingSection) { sec in
            VStack(alignment: .leading, spacing: 12) {
                Text("Bölümü Yeniden Adlandır")
                    .font(.headline)
                    .foregroundStyle(state.theme.primaryInk)
                TextField("Bölüm adı", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .foregroundStyle(state.theme.primaryInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(state.theme.subtleBorder, lineWidth: 1)
                    )
                    .onSubmit {
                        saveSectionRename(sec)
                    }
                HStack {
                    Spacer()
                    Button("İptal") { renamingSection = nil }
                        .buttonStyle(.bordered)
                    Button("Kaydet") {
                        saveSectionRename(sec)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 300)
            .background(state.theme.chromeBackground)
            .preferredColorScheme(state.theme.preferredColorScheme)
        }
        .sheet(item: $renamingPage) { page in
            VStack(alignment: .leading, spacing: 12) {
                Text("Sayfayı Yeniden Adlandır")
                    .font(.headline)
                    .foregroundStyle(state.theme.primaryInk)
                TextField("Sayfa adı", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .foregroundStyle(state.theme.primaryInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(state.theme.subtleBorder, lineWidth: 1)
                    )
                    .onSubmit {
                        savePageRename(page)
                    }
                HStack {
                    Spacer()
                    Button("İptal") { renamingPage = nil }
                        .buttonStyle(.bordered)
                    Button("Kaydet") {
                        savePageRename(page)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 300)
            .background(state.theme.chromeBackground)
            .preferredColorScheme(state.theme.preferredColorScheme)
        }
    }

    // MARK: - 1. Single Compact OneNote Header Bar

    private var activeSection: NotebookSection? {
        state.notebookSections.first(where: { $0.id == state.activeNotebookSectionID })
            ?? state.notebookSections.first
    }

    private var compactHeaderBar: some View {
        HStack(spacing: 6) {
            if state.notesSubTab == .notebook {
                // Colored Section Switcher Menu
                Menu {
                    ForEach(state.notebookSections) { sec in
                        Button {
                            state.selectNotebookSection(id: sec.id)
                        } label: {
                            Label(
                                sec.title,
                                systemImage: sec.id == state.activeNotebookSectionID ? "checkmark.circle.fill" : "circle.fill"
                            )
                        }
                    }

                    Divider()

                    Button {
                        state.addNotebookSection(title: "")
                    } label: {
                        Label("Yeni Bölüm Ekle", systemImage: "folder.badge.plus")
                    }

                    if let sec = activeSection {
                        Button {
                            renameDraft = sec.title
                            renamingSection = sec
                        } label: {
                            Label("Bölümü Yeniden Adlandır...", systemImage: "pencil")
                        }

                        Menu("Bölüm Rengi") {
                            ForEach(SectionColor.allCases) { color in
                                Button(color.displayName) {
                                    var updated = sec
                                    updated.color = color
                                    state.updateNotebookSection(updated)
                                }
                            }
                        }

                        if state.notebookSections.count > 1 {
                            Divider()
                            Button(role: .destructive) {
                                pendingDeleteSection = sec
                            } label: {
                                Label("Bölümü Sil", systemImage: "trash")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill((activeSection?.color ?? .purple).swiftUIColor)
                            .frame(width: 7, height: 7)
                        Text(activeSection?.title ?? "Genel Notlar")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background((activeSection?.color ?? .purple).swiftUIColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Bölümler")

                Text("/")
                    .font(.caption2)
                    .foregroundStyle(state.theme.secondaryInk.opacity(0.6))

                // Page Switcher Menu
                Menu {
                    ForEach(state.notebookPages) { page in
                        Button {
                            state.selectNotebookPage(id: page.id)
                        } label: {
                            Label(
                                page.title,
                                systemImage: page.id == state.activeNotebookPageID ? "checkmark" : "doc.text"
                            )
                        }
                    }

                    Divider()

                    Button {
                        state.addNotebookPage()
                    } label: {
                        Label("Yeni Sayfa Ekle", systemImage: "doc.badge.plus")
                    }

                    if let currentPage = state.activeNotebookPage {
                        Button {
                            renameDraft = currentPage.title
                            renamingPage = currentPage
                        } label: {
                            Label("Bu Sayfayı Yeniden Adlandır...", systemImage: "pencil")
                        }
                    }

                    if let currentPage = state.activeNotebookPage, state.notebookPages.count > 1 {
                        Button(role: .destructive) {
                            pendingDeletePage = currentPage
                        } label: {
                            Label("Bu Sayfayı Sil", systemImage: "trash")
                        }
                    }
                } label: {
                    Text(state.activeNotebookPage?.title ?? "Sayfa 1")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sayfalar")
            } else {
                Label("Vurgular (\(state.activeDocumentAnnotations.count))", systemImage: "highlighter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)
            }

            Spacer(minLength: 4)

            if state.notesSubTab == .notebook {
                // Default Notebook Font Picker with live font previews
                Button {
                    showDefaultFontPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("Aa")
                            .font(.caption.weight(.semibold))
                        if state.notebookFontFamily != NotebookFontCatalog.systemKey {
                            Text(state.notebookFontFamily)
                                .font(NotebookFontCatalog.swiftUIFont(family: state.notebookFontFamily, size: 11.5))
                                .lineLimit(1)
                                .frame(maxWidth: 96, alignment: .leading)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .opacity(0.65)
                    }
                    .foregroundStyle(state.theme.secondaryInk)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Defter Yazı Tipi (OneNote + LaTeX PDF)")
                .popover(isPresented: $showDefaultFontPopover, arrowEdge: .bottom) {
                    NotebookFontPickerPopover(
                        title: "Defter Yazı Tipi",
                        selectedFamily: state.notebookFontFamily,
                        userInstalledFonts: userInstalledFonts,
                        curatedFonts: curatedFonts,
                        otherSystemFonts: otherSystemFonts,
                        theme: state.theme
                    ) { fam in
                        state.setNotebookFontFamily(fam)
                        showDefaultFontPopover = false
                    }
                }

                if let activePage = state.activeNotebookPage {
                    Menu {
                        ForEach(PaperStyle.allCases) { style in
                            Button {
                                var updated = activePage
                                updated.paperStyle = style
                                state.updateNotebookPage(updated)
                            } label: {
                                Label(style.displayName, systemImage: style.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: activePage.paperStyle.systemImage)
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Kağıt Stili (Düz / Noktalı / Çizgili / Kareli)")
                }

                Button {
                    pasteImageFromClipboard()
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Panodaki Görseli Yapıştır (⌘V)")

                Menu {
                    Button {
                        exportNotebookLatexPDF(scope: .fullNotebook)
                    } label: {
                        Label("Tüm Defteri PDF Olarak Dışa Aktar (LaTeX)", systemImage: "doc.richtext")
                    }
                    .disabled(state.isExportingLatexPDF)

                    if let pageID = state.activeNotebookPageID {
                        Button {
                            exportNotebookLatexPDF(scope: .singlePage(pageID))
                        } label: {
                            Label("Sadece Bu Sayfayı PDF Olarak Dışa Aktar", systemImage: "doc.text")
                        }
                        .disabled(state.isExportingLatexPDF)
                    }

                    Divider()

                    Button {
                        exportNotebookLatexSource()
                    } label: {
                        Label("LaTeX Kaynağını (.tex) Kaydet…", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    Button {
                        exportNotebookMarkdown()
                    } label: {
                        Label("Markdown (.md) Olarak Dışa Aktar…", systemImage: "text.document")
                    }
                } label: {
                    if state.isExportingLatexPDF {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Notları Dışa Aktar (LaTeX PDF / .tex / .md)")

                if !isFullCanvasMode {
                    Rectangle()
                        .fill(state.theme.subtleBorder)
                        .frame(width: 1, height: 13)
                }
            }

            if !isFullCanvasMode {
                // Toggle between OneNote Defter and Vurgular Listesi
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.notesSubTab = (state.notesSubTab == .notebook) ? .highlights : .notebook
                    }
                } label: {
                    Image(systemName: state.notesSubTab == .notebook ? "highlighter" : "book.pages")
                        .font(.caption)
                        .foregroundStyle(state.notesSubTab == .highlights ? Color.accentColor : state.theme.secondaryInk)
                }
                .buttonStyle(.borderless)
                .help(state.notesSubTab == .notebook ? "Tüm Vurgular Listesine Geç" : "OneNote Defterine Dön")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(state.theme.chromeBackground)
    }

    // MARK: - 1b. Full-Canvas Mode Sections & Pages Navigation Rail

    private var fullModeNavigationRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sections header + list
            HStack {
                Text("BÖLÜMLER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(state.theme.secondaryInk)
                Spacer()
                Button {
                    _ = state.addNotebookSection(title: "")
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(state.theme.secondaryInk)
                }
                .buttonStyle(.borderless)
                .help("Yeni Bölüm Ekle")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(state.notebookSections) { sec in
                        let isSelected = (sec.id == state.activeNotebookSectionID)
                        Button {
                            state.selectNotebookSection(id: sec.id)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(sec.color.swiftUIColor)
                                    .frame(width: 7, height: 7)
                                Text(sec.title)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? state.theme.primaryInk : state.theme.secondaryInk)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? sec.color.swiftUIColor.opacity(0.16) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Yeniden Adlandır…") {
                                renameDraft = sec.title
                                renamingSection = sec
                            }
                            if state.notebookSections.count > 1 {
                                Button("Bölümü Sil", role: .destructive) {
                                    pendingDeleteSection = sec
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 170)

            Rectangle()
                .fill(state.theme.subtleBorder)
                .frame(height: 1)

            // Pages header + list
            HStack {
                Text("SAYFALAR")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(state.theme.secondaryInk)
                Spacer()
                Button {
                    _ = state.addNotebookPage()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(state.theme.secondaryInk)
                }
                .buttonStyle(.borderless)
                .help("Yeni Sayfa Ekle")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(state.notebookPages) { page in
                        let isSelected = (page.id == state.activeNotebookPageID)
                        Button {
                            state.selectNotebookPage(id: page.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10))
                                    .foregroundStyle(isSelected ? Color.accentColor : state.theme.secondaryInk.opacity(0.7))
                                Text(page.title)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? state.theme.primaryInk : state.theme.secondaryInk)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Yeniden Adlandır…") {
                                renameDraft = page.title
                                renamingPage = page
                            }
                            if state.notebookPages.count > 1 {
                                Button("Sayfayı Sil", role: .destructive) {
                                    pendingDeletePage = page
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 175)
        .background(state.theme.chromeBackground)
    }

    // MARK: - 2. Notebook Body

    private var notebookBody: some View {
        VStack(spacing: 0) {
            if focusedContainerID != nil {
                contextualFormattingToolbar
                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)
            }
            freeformCanvas
        }
    }

    // MARK: - 3. Contextual Rich Text Formatting Bar (Visible Only While Typing)

    private var contextualFormattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                formatBtn("H1", .heading1)
                formatBtn("H2", .heading2)
                formatBtn("H3", .heading3)
                formatBtn("T", .body)

                Button {
                    showSelectionFontPopover.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Text("Aa")
                            .font(.caption2.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .opacity(0.65)
                    }
                    .foregroundStyle(state.theme.primaryInk)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Seçili Metnin Yazı Tipini Değiştir")
                .popover(isPresented: $showSelectionFontPopover, arrowEdge: .bottom) {
                    NotebookFontPickerPopover(
                        title: "Seçili Metin Fontu",
                        selectedFamily: nil,
                        userInstalledFonts: userInstalledFonts,
                        curatedFonts: curatedFonts,
                        otherSystemFonts: otherSystemFonts,
                        theme: state.theme
                    ) { fam in
                        sendFormat(.fontFamily(fam))
                        showSelectionFontPopover = false
                    }
                }

                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(width: 1, height: 13)

                formatIconBtn("bold", .bold, help: "Kalın (⌘B)")
                formatIconBtn("italic", .italic, help: "İtalik (⌘I)")
                formatIconBtn("underline", .underline, help: "Altı Çizili (⌘U)")

                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(width: 1, height: 13)

                formatIconBtn("list.bullet", .bulletList, help: "Madde Listesi")
                formatIconBtn("list.number", .numberedList, help: "Numaralı Liste")
                formatIconBtn("checklist", .checkbox, help: "Yapılacak Kutusu (☐/☑)")

                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(width: 1, height: 13)

                Menu {
                    Button("Varsayılan") { sendFormat(.highlightColor(nil)) }
                    Button("Sarı Vurgu") { sendFormat(.highlightColor(NSColor.systemYellow.withAlphaComponent(0.35))) }
                    Button("Mavi Vurgu") { sendFormat(.highlightColor(NSColor.systemBlue.withAlphaComponent(0.25))) }
                    Button("Pembe Vurgu") { sendFormat(.highlightColor(NSColor.systemPink.withAlphaComponent(0.25))) }
                    Button("Yeşil Vurgu") { sendFormat(.highlightColor(NSColor.systemGreen.withAlphaComponent(0.28))) }
                } label: {
                    Image(systemName: "highlighter")
                        .font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Metin Vurgu Rengi")

                Menu {
                    Button("Varsayılan Metin") { sendFormat(.textColor(defaultInkNSColor)) }
                    Button("Kırmızı") { sendFormat(.textColor(.systemRed)) }
                    Button("Mavi") { sendFormat(.textColor(.systemBlue)) }
                    Button("Yeşil") { sendFormat(.textColor(.systemGreen)) }
                    Button("Mor") { sendFormat(.textColor(.systemPurple)) }
                } label: {
                    Image(systemName: "textformat.alt")
                        .font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Metin Rengi")

                Spacer(minLength: 8)

                Button {
                    cleanupEmptyTextContainers(except: nil)
                    focusedContainerID = nil
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(state.theme.secondaryInk)
                }
                .buttonStyle(.plain)
                .help("Düzenlemeyi Bitir")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(state.theme.chromeBackground)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func formatBtn(_ title: String, _ action: RichTextFormatAction) -> some View {
        Button {
            sendFormat(action)
        } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .frame(minWidth: 20)
        }
        .buttonStyle(.borderless)
    }

    private func formatIconBtn(_ systemName: String, _ action: RichTextFormatAction, help: String) -> some View {
        Button {
            sendFormat(action)
        } label: {
            Image(systemName: systemName)
                .font(.caption2)
                .frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func sendFormat(_ action: RichTextFormatAction) {
        guard let targetID = focusedContainerID else { return }
        activeFormatCommand = RichTextFormatCommand(targetContainerID: targetID, action: action)
    }

    // MARK: - 4. Freeform OneNote Paper Canvas

    private var freeformCanvas: some View {
        let paperStyle = state.activeNotebookPage?.paperStyle ?? .dotted
        let contentMaxX = (state.activePageContainers.map { $0.x + $0.width }.max() ?? 420) + 220
        let contentMaxY = (state.activePageContainers.map { $0.y + $0.height }.max() ?? 620) + 280

        return GeometryReader { geo in
            let canvasWidth = max(max(540.0, geo.size.width), contentMaxX)
            let canvasHeight = max(max(780.0, geo.size.height), contentMaxY)

            ScrollViewReader { scrollProxy in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        PaperBackgroundView(style: paperStyle, theme: state.theme)
                            .frame(width: canvasWidth, height: canvasHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                handlePaperSingleClick(at: location)
                            }

                        // Authentic OneNote Page Title + Date directly on the paper
                        onPaperPageHeader
                            .padding(.leading, 24)
                            .padding(.top, 18)

                        if state.activePageContainers.isEmpty {
                            Text("Kağıtta herhangi bir yere tıklayıp yazmaya başlayın, ⌘V ile görsel yapıştırın veya PDF'te metin vurgulayın.")
                                .font(.caption)
                                .foregroundStyle(Color(nsColor: defaultInkNSColor).opacity(0.42))
                                .frame(width: 300, alignment: .leading)
                                .offset(x: 24, y: 96)
                                .allowsHitTesting(false)
                        }

                        ForEach(state.activePageContainers) { container in
                            NoteContainerCardView(
                                container: container,
                                isFocused: focusedContainerID == container.id,
                                isHighlighted: state.highlightedContainerID == container.id,
                                theme: state.theme,
                                inkColor: defaultInkNSColor,
                                defaultFontFamily: state.notebookFontFamily,
                                formatCommand: activeFormatCommand,
                                onFocus: {
                                    cleanupEmptyTextContainers(except: container.id)
                                    focusedContainerID = container.id
                                    state.bringContainerToFront(id: container.id)
                                },
                                onUpdate: { updated, recordGeometryUndo in
                                    state.updateNoteContainer(updated, recordGeometryUndo: recordGeometryUndo)
                                },
                                onDelete: {
                                    if focusedContainerID == container.id {
                                        focusedContainerID = nil
                                    }
                                    state.deleteNoteContainer(id: container.id)
                                },
                                onJumpToSourcePage: { pageIdx in
                                    state.jumpToPage(pageIdx)
                                },
                                onPasteImage: { img in
                                    let offsetPt = CGPoint(x: container.x + 24, y: container.y + container.height + 16)
                                    _ = state.addImageContainer(image: img, at: offsetPt)
                                }
                            )
                            .id(container.id)
                        }
                    }
                    .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                    .coordinateSpace(name: "onenote-canvas")
                }
                .onChange(of: state.highlightedContainerID) { _, newID in
                    if let targetID = newID {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            scrollProxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(paperBaseColor)
    }

    private var onPaperPageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Sayfa Başlığı", text: $pageTitleDraft)
                .textFieldStyle(.plain)
                .font(NotebookFontCatalog.swiftUIFont(family: state.notebookFontFamily, size: 21, weight: .semibold))
                .foregroundStyle(Color(nsColor: defaultInkNSColor))
                .frame(width: 340, alignment: .leading)
                .focused($isPageTitleFocused)
                .onSubmit {
                    titleSaveTask?.cancel()
                    titleSaveTask = nil
                    commitPageTitle()
                    isPageTitleFocused = false
                }
                .onChange(of: pageTitleDraft) { _, newValue in
                    titleSaveTask?.cancel()
                    titleSaveTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        commitPageTitle()
                    }
                }

            Rectangle()
                .fill(Color(nsColor: defaultInkNSColor).opacity(0.18))
                .frame(width: 320, height: 1)

            if let page = state.activeNotebookPage {
                Text(Self.turkishDateFormatter.string(from: page.createdAt))
                    .font(.caption2)
                    .foregroundStyle(Color(nsColor: defaultInkNSColor).opacity(0.45))
            }
        }
    }

    // MARK: - Helpers

    private func loadFontCatalog() {
        let userFams = NotebookFontCatalog.userInstalledFamilies()
        let curated = NotebookFontCatalog.availableCuratedFamilies()
        let excluded = Set(userFams).union(Set(curated))
        userInstalledFonts = userFams
        curatedFonts = curated
        otherSystemFonts = NotebookFontCatalog.otherSystemFamilies(excluding: excluded)
    }

    private func saveSectionRename(_ section: NotebookSection) {
        var updated = section
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            updated.title = trimmed
            state.updateNotebookSection(updated)
        }
        renamingSection = nil
    }

    private func savePageRename(_ page: NotebookPage) {
        var updated = page
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            updated.title = trimmed
            state.updateNotebookPage(updated)
            if state.activeNotebookPageID == updated.id {
                pageTitleDraft = trimmed
            }
        }
        renamingPage = nil
    }

    private func handlePaperSingleClick(at location: CGPoint) {
        // Clicking in the page title header area focuses the page title instead of creating a box
        if location.y < 86 {
            isPageTitleFocused = true
            return
        }
        isPageTitleFocused = false
        // If user clicked inside (or within 8pt of) an existing container, focus it instead of creating a new one
        if let existing = state.activePageContainers.reversed().first(where: { item in
            let rect = CGRect(x: item.x, y: item.y, width: item.width, height: item.height).insetBy(dx: -8, dy: -8)
            return rect.contains(location)
        }) {
            cleanupEmptyTextContainers(except: existing.id)
            withAnimation(.easeInOut(duration: 0.12)) {
                focusedContainerID = existing.id
            }
            return
        }

        cleanupEmptyTextContainers(except: nil)
        // Keep new containers neatly below the page title header (y >= 92)
        let targetPoint = CGPoint(x: max(20, location.x), y: max(92, location.y))
        if let created = state.addTextContainer(at: targetPoint, width: 320, height: 120) {
            withAnimation(.easeInOut(duration: 0.12)) {
                focusedContainerID = created.id
            }
        }
    }

    private func cleanupEmptyTextContainers(except keepID: UUID?) {
        let empties = state.activePageContainers.filter { item in
            item.kind == .richText
                && item.id != keepID
                && item.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for empty in empties {
            state.deleteNoteContainer(id: empty.id, recordUndo: false)
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc: exit container or page title focus in OneNote
            if event.keyCode == 53, (focusedContainerID != nil || isPageTitleFocused) {
                cleanupEmptyTextContainers(except: nil)
                focusedContainerID = nil
                isPageTitleFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            }

            // ⌘V on canvas when no NSTextView is focused: paste clipboard image into notebook
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isNotebookActive = isFullCanvasMode || (state.showRightInspector && state.rightPanelTab == .notes && state.notesSubTab == .notebook)
            if flags == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v",
               isNotebookActive,
               !(NSApp.keyWindow?.firstResponder is NSTextView) {
                let pb = NSPasteboard.general
                let hasString = pb.string(forType: .string)?.isEmpty == false
                if !hasString, let image = NSImage(pasteboard: pb), image.size.width > 1, image.size.height > 1 {
                    _ = state.addImageContainer(image: image)
                    return nil
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func commitPageTitle() {
        guard var page = state.activeNotebookPage else { return }
        let trimmed = pageTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != page.title {
            page.title = trimmed
            state.updateNotebookPage(page)
        }
    }

    private var defaultInkNSColor: NSColor {
        switch state.theme {
        case .original: return .labelColor
        case .sepia: return NSColor(calibratedRed: 0.22, green: 0.17, blue: 0.11, alpha: 1.0)
        case .softDark: return NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.92, alpha: 1.0)
        }
    }

    private var paperBaseColor: Color {
        state.theme.surfaceBackground
    }

    private func pasteImageFromClipboard() {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb), image.size.width > 1, image.size.height > 1 {
            _ = state.addImageContainer(image: image)
        } else {
            state.errorMessage = "Panoda yapıştırılacak bir görsel veya ekran görüntüsü bulunamadı."
        }
    }

    private func exportNotebookLatexPDF(scope: LatexExportScope) {
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

    private func exportNotebookLatexSource() {
        guard let artifact = state.buildActiveLatexArtifact(scope: .fullNotebook),
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

    private func exportNotebookMarkdown() {
        guard let md = state.exportActiveNotebookMarkdown(),
              let ownerTitle = state.activeNotebookOwnerTitle else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "\(ownerTitle) - Defter.md"
        panel.title = "OneNote Defterini Markdown Olarak Dışa Aktar"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                state.errorMessage = "Defter kaydedilemedi: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Paper Background Renderer

private struct PaperBackgroundView: View {
    let style: PaperStyle
    let theme: ReadingTheme

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bgColor))
            guard style != .plain else { return }

            let spacing: CGFloat = 22
            switch style {
            case .plain:
                break
            case .dotted:
                var y = spacing
                while y < size.height {
                    var x = spacing
                    while x < size.width {
                        let dot = CGRect(x: x - 0.85, y: y - 0.85, width: 1.7, height: 1.7)
                        context.fill(Path(ellipseIn: dot), with: .color(patternColor))
                        x += spacing
                    }
                    y += spacing
                }
            case .lined:
                var path = Path()
                var y = spacing
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                context.stroke(path, with: .color(patternColor), lineWidth: 0.65)
            case .grid:
                var path = Path()
                var y = spacing
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                var x = spacing
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                context.stroke(path, with: .color(patternColor), lineWidth: 0.55)
            }
        }
    }

    private var bgColor: Color {
        theme.surfaceBackground
    }

    private var patternColor: Color {
        switch theme {
        case .original: return Color.secondary.opacity(0.20)
        case .sepia: return Color(red: 0.56, green: 0.45, blue: 0.30).opacity(0.20)
        case .softDark: return Color.white.opacity(0.08)
        }
    }
}

// MARK: - Borderless OneNote Note Container (Chrome Appears on Hover/Focus)

private struct NoteContainerCardView: View {
    let container: NoteContainer
    let isFocused: Bool
    let isHighlighted: Bool
    let theme: ReadingTheme
    let inkColor: NSColor
    let defaultFontFamily: String
    let formatCommand: RichTextFormatCommand?
    let onFocus: () -> Void
    let onUpdate: (NoteContainer, Bool) -> Void
    let onDelete: () -> Void
    let onJumpToSourcePage: (Int) -> Void
    let onPasteImage: (NSImage) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: CGSize = .zero
    @State private var isHovered: Bool = false
    @State private var requiredEditorHeight: CGFloat = 0

    private var showChrome: Bool {
        isFocused || isHovered || dragOffset != .zero || resizeDelta != .zero
    }

    private var currentWidth: CGFloat {
        max(160, CGFloat(container.width) + resizeDelta.width)
    }

    private var currentHeight: CGFloat {
        max(68, CGFloat(container.height) + resizeDelta.height)
    }

    private var cardBackground: Color {
        if container.kind == .richText && !showChrome {
            return .clear
        }
        switch theme {
        case .original:
            return Color(nsColor: .windowBackgroundColor).opacity(container.kind == .richText ? 0.55 : 0.82)
        case .sepia:
            return Color(red: 0.98, green: 0.95, blue: 0.88).opacity(container.kind == .richText ? 0.65 : 0.88)
        case .softDark:
            return Color(red: 0.15, green: 0.16, blue: 0.18).opacity(container.kind == .richText ? 0.65 : 0.88)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top drag handle bar (always subtle for quote/image, revealed on hover/focus for richText)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(nsColor: inkColor).opacity(0.45))

                if container.kind == .pdfQuote, let srcPage = container.sourcePageIndex {
                    Button {
                        onJumpToSourcePage(srcPage)
                    } label: {
                        HStack(spacing: 3) {
                            if let accent = container.accentColor {
                                Circle()
                                    .fill(accent.swiftUIColor)
                                    .frame(width: 6, height: 6)
                            }
                            Text("s. \(srcPage + 1)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("PDF'te Sayfa \(srcPage + 1)'e Git")
                }

                Spacer()

                if showChrome {
                    Menu {
                        Button("Renksiz") {
                            var copy = container
                            copy.accentColor = nil
                            onUpdate(copy, false)
                        }
                        ForEach(HighlightColor.allCases) { color in
                            Button(color.fullLabel) {
                                var copy = container
                                copy.accentColor = color
                                onUpdate(copy, false)
                            }
                        }
                    } label: {
                        Circle()
                            .fill(container.accentColor?.swiftUIColor ?? Color.secondary.opacity(0.4))
                            .frame(width: 9, height: 9)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Kutu Rengi")

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(nsColor: inkColor).opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Kutuyu Sil")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .opacity(container.kind == .pdfQuote ? 1.0 : (showChrome ? 1.0 : 0.0))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named("onenote-canvas"))
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        var copy = container
                        copy.x = max(8, container.x + Double(value.translation.width))
                        copy.y = max(86, container.y + Double(value.translation.height))
                        dragOffset = .zero
                        onFocus()
                        onUpdate(copy, true)
                    }
            )

            // Body content
            switch container.kind {
            case .richText:
                RichTextContainerEditor(
                    containerID: container.id,
                    rtfData: container.rtfData,
                    plainText: container.plainText,
                    textColor: inkColor,
                    defaultFontFamily: defaultFontFamily,
                    shouldFocus: isFocused,
                    formatCommand: formatCommand,
                    onFocus: onFocus,
                    onContentChanged: { rtf, plain in
                        var copy = container
                        copy.rtfData = rtf
                        copy.plainText = plain
                        let neededHeight = Double(requiredEditorHeight + 32)
                        if neededHeight > copy.height + 2 {
                            copy.height = min(680, neededHeight)
                        }
                        onUpdate(copy, false)
                    },
                    onRequiredHeightChanged: { h in
                        requiredEditorHeight = h
                    },
                    onPasteImage: onPasteImage
                )
                .padding(.horizontal, 4)
                .padding(.bottom, 6)

            case .pdfQuote:
                VStack(alignment: .leading, spacing: 4) {
                    if let quote = container.quoteText, !quote.isEmpty {
                        ScrollView {
                            Text("“\(quote)”")
                                .font(.caption)
                                .foregroundStyle(Color(nsColor: inkColor).opacity(0.80))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 8)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill((container.accentColor ?? .yellow).swiftUIColor)
                                        .frame(width: 3)
                                        .clipShape(Capsule())
                                }
                        }
                        .frame(maxHeight: 72)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                    }

                    RichTextContainerEditor(
                        containerID: container.id,
                        rtfData: container.rtfData,
                        plainText: container.plainText,
                        placeholder: "Yorumunuzu yazın...",
                        textColor: inkColor,
                        defaultFontFamily: defaultFontFamily,
                        shouldFocus: isFocused,
                        formatCommand: formatCommand,
                        onFocus: onFocus,
                        onContentChanged: { rtf, plain in
                            var copy = container
                            copy.rtfData = rtf
                            copy.plainText = plain
                            let neededHeight = Double(requiredEditorHeight + 112)
                            if neededHeight > copy.height + 2 {
                                copy.height = min(680, neededHeight)
                            }
                            onUpdate(copy, false)
                        },
                        onRequiredHeightChanged: { h in
                            requiredEditorHeight = h
                        },
                        onPasteImage: onPasteImage
                    )
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
                }

            case .image:
                Group {
                    if let path = container.imagePath, let nsImage = NotebookImageCache.shared.image(atPath: path) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(4)
                    } else {
                        ContentUnavailableView("Görsel Bulunamadı", systemImage: "photo")
                    }
                }
                .onTapGesture {
                    onFocus()
                }
            }
        }
        .frame(width: currentWidth, height: currentHeight, alignment: .topLeading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isHighlighted
                        ? Color.accentColor
                        : (showChrome
                            ? (container.accentColor?.swiftUIColor ?? Color.accentColor).opacity(isFocused ? 0.65 : 0.30)
                            : (container.kind == .pdfQuote ? (container.accentColor ?? .yellow).swiftUIColor.opacity(0.22) : Color.clear)),
                    lineWidth: isHighlighted ? 2.2 : (isFocused ? 1.2 : 0.8)
                )
        )
        .shadow(color: isHighlighted ? Color.accentColor.opacity(0.32) : .clear, radius: isHighlighted ? 10 : 0)
        .animation(.easeInOut(duration: 0.22), value: isHighlighted)
        .overlay(alignment: .bottomTrailing) {
            if showChrome {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(nsColor: inkColor).opacity(0.45))
                    .padding(5)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(coordinateSpace: .named("onenote-canvas"))
                            .onChanged { value in
                                resizeDelta = value.translation
                            }
                            .onEnded { value in
                                var copy = container
                                copy.width = max(160, container.width + Double(value.translation.width))
                                copy.height = max(68, container.height + Double(value.translation.height))
                                resizeDelta = .zero
                                onFocus()
                                onUpdate(copy, true)
                            }
                    )
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .offset(
            x: CGFloat(container.x) + dragOffset.width,
            y: CGFloat(container.y) + dragOffset.height
        )
        .zIndex(Double(container.zIndex))
    }
}

@MainActor
private final class NotebookImageCache {
    static let shared = NotebookImageCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 64
    }

    func image(atPath path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let loaded = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(loaded, forKey: key)
        return loaded
    }
}

private struct NotebookFontPickerPopover: View {
    let title: String
    let selectedFamily: String?
    let userInstalledFonts: [String]
    let curatedFonts: [String]
    let otherSystemFonts: [String]
    let theme: ReadingTheme
    let onSelect: (String) -> Void

    @State private var showOtherSystemFonts: Bool = false
    @State private var searchQuery: String = ""
    @State private var hoveredFamily: String?

    private var filteredOtherFonts: [String] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return otherSystemFonts }
        return otherSystemFonts.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryInk)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !userInstalledFonts.isEmpty {
                        sectionHeader("İndirdiklerim")
                        ForEach(userInstalledFonts, id: \.self) { fam in
                            fontRow(family: fam, label: fam)
                        }
                        Divider()
                            .padding(.vertical, 4)
                    }

                    sectionHeader("Temel Fontlar")
                    ForEach(curatedFonts, id: \.self) { fam in
                        fontRow(family: fam, label: NotebookFontCatalog.displayName(for: fam))
                    }

                    if !otherSystemFonts.isEmpty {
                        Divider()
                            .padding(.vertical, 4)

                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                showOtherSystemFonts.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showOtherSystemFonts ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(theme.secondaryInk)
                                    .frame(width: 10)
                                Text("Diğer Sistem Fontları (\(otherSystemFonts.count))")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(theme.secondaryInk)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showOtherSystemFonts {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.caption2)
                                    .foregroundStyle(theme.secondaryInk)
                                TextField("Font ara...", text: $searchQuery)
                                    .textFieldStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(theme.primaryInk)
                                if !searchQuery.isEmpty {
                                    Button {
                                        searchQuery = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(theme.secondaryInk)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(theme.subtleBorder, lineWidth: 1)
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)

                            ForEach(filteredOtherFonts, id: \.self) { fam in
                                fontRow(family: fam, label: fam)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: showOtherSystemFonts ? 380 : 280)
        }
        .frame(width: 248)
        .background(theme.chromeBackground)
        .preferredColorScheme(theme.preferredColorScheme)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.secondaryInk.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func fontRow(family: String, label: String) -> some View {
        let isSelected = (selectedFamily == family)
        let isHovered = (hoveredFamily == family)

        return Button {
            onSelect(family)
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .font(NotebookFontCatalog.swiftUIFont(family: family, size: 13.5))
                    .foregroundStyle(theme.primaryInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.14)
                            : (isHovered ? theme.primaryInk.opacity(0.07) : Color.clear)
                    )
            )
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredFamily = hovering ? family : (hoveredFamily == family ? nil : hoveredFamily)
        }
    }
}
