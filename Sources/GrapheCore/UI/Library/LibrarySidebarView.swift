import AppKit
import SwiftUI

public struct LibrarySidebarView: View {
    @Bindable public var state: WorkspaceState
    public let onRequestOpenPDF: () -> Void
    public let onRequestOpenSecondaryPDF: () -> Void

    @State private var editingTagDocument: LibraryDocumentRecord? = nil
    @State private var tagEditInput: String = ""

    @State private var newSubfolderParent: FileTreeNode? = nil
    @State private var newSubfolderName: String = ""

    @State private var renamingNode: FileTreeNode? = nil
    @State private var renameNodeDraft: String = ""

    @State private var renamingNotebook: StandaloneNotebook? = nil
    @State private var renameNotebookDraft: String = ""
    @State private var pendingDeleteNotebook: StandaloneNotebook? = nil

    @State private var expandedFolderPaths: Set<String> = []

    public init(
        state: WorkspaceState,
        onRequestOpenPDF: @escaping () -> Void,
        onRequestOpenSecondaryPDF: @escaping () -> Void
    ) {
        self.state = state
        self.onRequestOpenPDF = onRequestOpenPDF
        self.onRequestOpenSecondaryPDF = onRequestOpenSecondaryPDF
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ForEach(LeftPanelTab.allCases) { tab in
                    let isSelected = state.leftPanelTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            state.leftPanelTab = tab
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Text(tab.rawValue)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? state.theme.primaryInk : state.theme.secondaryInk)
                            Rectangle()
                                .fill(isSelected ? Color.accentColor : Color.clear)
                                .frame(height: 1.5)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

            Rectangle()
                .fill(state.theme.subtleBorder)
                .frame(height: 1)

            switch state.leftPanelTab {
            case .library:
                librarySection
            case .notebooks:
                standaloneNotebooksSection
            case .outline:
                outlineList
            }

            SpotifySidebarCardView(spotify: state.spotify, theme: state.theme)
        }
        .frame(minWidth: 215, idealWidth: 255, maxWidth: 360)
        .background(state.theme.chromeBackground)
        .onChange(of: state.folderTrees) { _, newTrees in
            // Auto-expand newly attached root folders
            for root in newTrees where !expandedFolderPaths.contains(root.id) {
                expandedFolderPaths.insert(root.id)
            }
        }
        .onAppear {
            for root in state.folderTrees {
                expandedFolderPaths.insert(root.id)
            }
        }
        .sheet(item: $editingTagDocument) { doc in
            VStack(alignment: .leading, spacing: 12) {
                Text("Kitap Etiketleri")
                    .font(.headline)
                    .foregroundStyle(state.theme.primaryInk)
                Text(doc.title)
                    .font(.caption)
                    .foregroundStyle(state.theme.secondaryInk)
                    .lineLimit(2)

                TextField("Etiketler (virgülle ayırın: heidegger, fenomenoloji)", text: $tagEditInput)
                    .textFieldStyle(.plain)
                    .foregroundStyle(state.theme.primaryInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(state.theme.subtleBorder, lineWidth: 1)
                    )

                HStack {
                    Spacer()
                    Button("İptal") {
                        editingTagDocument = nil
                    }
                    .buttonStyle(.bordered)

                    Button("Kaydet") {
                        let tags = tagEditInput
                            .components(separatedBy: CharacterSet(charactersIn: ",;"))
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
                            .filter { !$0.isEmpty }
                        state.updateDocumentTags(hash: doc.hash, tags: tags)
                        editingTagDocument = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 340)
            .background(state.theme.chromeBackground)
            .preferredColorScheme(state.theme.preferredColorScheme)
        }
        .sheet(item: $newSubfolderParent) { parent in
            VStack(alignment: .leading, spacing: 12) {
                Text("Yeni Alt Klasör")
                    .font(.headline)
                    .foregroundStyle(state.theme.primaryInk)
                Text("Konum: \(parent.name)")
                    .font(.caption)
                    .foregroundStyle(state.theme.secondaryInk)
                TextField("Klasör adı (ör. Heidegger)", text: $newSubfolderName)
                    .textFieldStyle(.plain)
                    .foregroundStyle(state.theme.primaryInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(state.theme.subtleBorder, lineWidth: 1)
                    )
                HStack {
                    Spacer()
                    Button("İptal") { newSubfolderParent = nil }
                        .buttonStyle(.bordered)
                    Button("Oluştur") {
                        state.createSubfolder(named: newSubfolderName, inside: parent.url)
                        expandedFolderPaths.insert(parent.id)
                        newSubfolderName = ""
                        newSubfolderParent = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newSubfolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 320)
            .background(state.theme.chromeBackground)
            .preferredColorScheme(state.theme.preferredColorScheme)
        }
        .sheet(item: $renamingNode) { node in
            VStack(alignment: .leading, spacing: 12) {
                Text(node.isDirectory ? "Klasörü Yeniden Adlandır" : "PDF'i Yeniden Adlandır")
                    .font(.headline)
                    .foregroundStyle(state.theme.primaryInk)
                TextField("Yeni ad", text: $renameNodeDraft)
                    .textFieldStyle(.plain)
                    .foregroundStyle(state.theme.primaryInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(state.theme.subtleBorder, lineWidth: 1)
                    )
                HStack {
                    Spacer()
                    Button("İptal") { renamingNode = nil }
                        .buttonStyle(.bordered)
                    Button("Kaydet") {
                        state.renameFileItem(at: node.url, to: renameNodeDraft)
                        renamingNode = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameNodeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 320)
            .background(state.theme.chromeBackground)
            .preferredColorScheme(state.theme.preferredColorScheme)
        }
        .sheet(item: $renamingNotebook) { nb in
            VStack(alignment: .leading, spacing: 12) {
                Text("Defteri Yeniden Adlandır")
                    .font(.headline)
                    .foregroundStyle(state.theme.primaryInk)
                TextField("Defter adı", text: $renameNotebookDraft)
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
                        state.renameStandaloneNotebook(id: nb.id, title: renameNotebookDraft)
                        renamingNotebook = nil
                    }
                HStack {
                    Spacer()
                    Button("İptal") { renamingNotebook = nil }
                        .buttonStyle(.bordered)
                    Button("Kaydet") {
                        state.renameStandaloneNotebook(id: nb.id, title: renameNotebookDraft)
                        renamingNotebook = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameNotebookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 320)
            .background(state.theme.chromeBackground)
            .preferredColorScheme(state.theme.preferredColorScheme)
        }
        .confirmationDialog(
            "Defteri Sil",
            isPresented: Binding(
                get: { pendingDeleteNotebook != nil },
                set: { if !$0 { pendingDeleteNotebook = nil } }
            ),
            presenting: pendingDeleteNotebook
        ) { nb in
            Button("“\(nb.title)” Defterini Sil", role: .destructive) {
                state.deleteStandaloneNotebook(id: nb.id)
                pendingDeleteNotebook = nil
            }
            Button("İptal", role: .cancel) {
                pendingDeleteNotebook = nil
            }
        } message: { nb in
            Text("“\(nb.title)” defteri ve içindeki tüm bölümler, sayfalar, notlar ve görseller kalıcı olarak silinecek.")
        }
    }

    // MARK: - Standalone Notebooks Tab (PDF-Free Notes)

    private var standaloneNotebooksSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bağımsız Defterlerim")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)
                Spacer()
                Button {
                    _ = state.createStandaloneNotebook()
                } label: {
                    Label("Yeni", systemImage: "plus")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Yeni Bağımsız Defter Oluştur (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle()
                .fill(state.theme.subtleBorder)
                .frame(height: 1)

            if state.standaloneNotebooks.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "book.pages")
                        .font(.system(size: 28))
                        .foregroundStyle(state.theme.secondaryInk.opacity(0.6))
                    Text("Henüz Bağımsız Defter Yok")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.theme.primaryInk)
                    Text("PDF okumuyorken de ders notu, taslak veya günlük tutmak için yeni bir defter oluşturun.")
                        .font(.caption2)
                        .foregroundStyle(state.theme.secondaryInk)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Button {
                        _ = state.createStandaloneNotebook()
                    } label: {
                        Label("Yeni Defter Oluştur", systemImage: "plus")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(state.standaloneNotebooks) { nb in
                            let isActive = (state.activeStandaloneNotebookID == nb.id)
                            Button {
                                state.openStandaloneNotebook(id: nb.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(nb.color.swiftUIColor)
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(nb.title)
                                            .font(.caption.weight(isActive ? .semibold : .medium))
                                            .foregroundStyle(state.theme.primaryInk)
                                            .lineLimit(1)
                                        Text(nb.updatedAt, style: .date)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(state.theme.secondaryInk.opacity(0.8))
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(isActive ? nb.color.swiftUIColor.opacity(0.15) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Yeniden Adlandır…") {
                                    renameNotebookDraft = nb.title
                                    renamingNotebook = nb
                                }
                                Menu("Renk") {
                                    ForEach(SectionColor.allCases) { color in
                                        Button(color.displayName) {
                                            state.updateStandaloneNotebookColor(id: nb.id, color: color)
                                        }
                                    }
                                }
                                Divider()
                                Button("Defteri Sil", role: .destructive) {
                                    pendingDeleteNotebook = nb
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Library Section (Global Search + Klasörler | Tümü)

    private var librarySection: some View {
        VStack(spacing: 0) {
            // Global FTS5 Search bar across all books, highlights & OneNote notebooks
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(state.theme.secondaryInk)
                TextField("Tüm kitap ve notlarda ara...", text: Binding(
                    get: { state.globalSearchQuery },
                    set: { state.scheduleGlobalSearch($0) }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(state.theme.primaryInk)

                if !state.globalSearchQuery.isEmpty {
                    Button {
                        state.performGlobalSearch("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(state.theme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(state.theme.surfaceBackground.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(state.theme.subtleBorder, lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if !state.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                globalSearchResultsList
            } else {
                // Compact mode switcher: Klasörler | Tümü + Folder Actions
                HStack(spacing: 6) {
                    ForEach(LibraryViewMode.allCases) { mode in
                        let isSelected = state.libraryViewMode == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                state.libraryViewMode = mode
                            }
                        } label: {
                            Text(mode.rawValue)
                                .font(.caption2.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? state.theme.primaryInk : state.theme.secondaryInk)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    isSelected ? state.theme.subtleBorder : Color.clear,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    if state.libraryViewMode == .folders {
                        if !state.watchedFolders.isEmpty {
                            Button {
                                state.refreshFolderTrees()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                                    .foregroundStyle(state.theme.secondaryInk)
                            }
                            .buttonStyle(.plain)
                            .help("Klasörleri Yenile")
                        }

                        Button {
                            presentAttachVaultFolderPanel()
                        } label: {
                            Image(systemName: "folder.badge.plus")
                                .font(.caption)
                                .foregroundStyle(state.theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                        .help("Kitap Klasörü (Vault) Bağla")
                    } else {
                        Button {
                            onRequestOpenPDF()
                        } label: {
                            Image(systemName: "doc.badge.plus")
                                .font(.caption)
                                .foregroundStyle(state.theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                        .help("PDF Dosyası Aç (⌘O)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

                switch state.libraryViewMode {
                case .folders:
                    folderExplorerView
                case .all:
                    allDocumentsListView
                }
            }
        }
    }

    // MARK: - 1. Vault / Folder File Manager Tree

    private var folderExplorerView: some View {
        Group {
            if state.folderTrees.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(state.theme.secondaryInk)
                    Text("Kitap Klasörü Bağla")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(state.theme.primaryInk)
                    Text("PDF'lerini topladığın klasörü bağla; alt klasörlerle dosya yöneticisi gibi gez, taşı ve yeniden adlandır.")
                        .font(.caption)
                        .foregroundStyle(state.theme.secondaryInk)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Button {
                        presentAttachVaultFolderPanel()
                    } label: {
                        Label("Klasör Seç...", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.folderTrees) { rootNode in
                            FileTreeNodeRow(
                                node: rootNode,
                                depth: 0,
                                state: state,
                                expandedPaths: $expandedFolderPaths,
                                onRequestNewSubfolder: { parent in
                                    newSubfolderName = ""
                                    newSubfolderParent = parent
                                },
                                onRequestRename: { target in
                                    renameNodeDraft = target.name
                                    renamingNode = target
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - 2. All Documents & Tag Filter View

    private var allDocumentsListView: some View {
        VStack(spacing: 0) {
            if !state.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Button {
                            state.selectedTagFilter = nil
                        } label: {
                            Text("Tümü")
                                .font(.caption2.weight(state.selectedTagFilter == nil ? .semibold : .regular))
                                .foregroundStyle(state.selectedTagFilter == nil ? Color.accentColor : state.theme.primaryInk)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    state.selectedTagFilter == nil ? Color.accentColor.opacity(0.18) : state.theme.subtleBorder,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)

                        ForEach(state.allTags, id: \.self) { tag in
                            Button {
                                state.selectedTagFilter = state.selectedTagFilter == tag ? nil : tag
                            } label: {
                                Text("#\(tag)")
                                    .font(.caption2.weight(state.selectedTagFilter == tag ? .semibold : .regular))
                                    .foregroundStyle(state.selectedTagFilter == tag ? Color.accentColor : state.theme.primaryInk)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        state.selectedTagFilter == tag ? Color.accentColor.opacity(0.18) : state.theme.subtleBorder,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
            }

            if state.filteredLibraryDocuments.isEmpty {
                ContentUnavailableView(
                    state.libraryDocuments.isEmpty ? "Henüz PDF Yok" : "Bu Etikette Kitap Yok",
                    systemImage: "books.vertical",
                    description: Text(state.libraryDocuments.isEmpty
                        ? "Bir PDF açın veya Klasörler sekmesinden kitap klasörünüzü bağlayın."
                        : "Farklı bir etiket seçin veya filtreyi temizleyin.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.filteredLibraryDocuments) { doc in
                        let isActiveDoc = state.activeTab?.activePane.url.path == doc.url.path
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(doc.title)
                                    .font(.callout.weight(isActiveDoc ? .semibold : .regular))
                                    .foregroundStyle(isActiveDoc ? Color.accentColor : state.theme.primaryInk)
                                    .lineLimit(1)
                                Spacer()
                                if state.indexingDocumentHashes.contains(doc.hash) {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .help("Tam metin indeksleniyor...")
                                } else if doc.isIndexed {
                                    Image(systemName: "text.magnifyingglass")
                                        .font(.caption2)
                                        .foregroundStyle(state.theme.secondaryInk)
                                        .help("FTS5 Tam Metin İndeksi Hazır")
                                }
                            }

                            HStack(spacing: 6) {
                                let subtitle: String = {
                                    let parts = [doc.author, doc.year.map(String.init)].compactMap { $0?.isEmpty == false ? $0 : nil }
                                    return parts.isEmpty ? doc.url.deletingLastPathComponent().lastPathComponent : parts.joined(separator: " · ")
                                }()
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(state.theme.secondaryInk)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if let prog = state.readingProgress(for: doc) {
                                    Text("s. \(prog.page)/\(doc.pageCount)")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(state.theme.secondaryInk)
                                } else if doc.pageCount > 0 {
                                    Text("\(doc.pageCount) s.")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(state.theme.secondaryInk)
                                }
                            }

                            if let prog = state.readingProgress(for: doc) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(state.theme.subtleBorder)
                                        Capsule()
                                            .fill(Color.accentColor.opacity(0.65))
                                            .frame(width: max(4, geo.size.width * prog.fraction))
                                    }
                                }
                                .frame(height: 2)
                                .padding(.top, 2)
                            }

                            if !doc.tags.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(doc.tags.prefix(3), id: \.self) { tag in
                                        Text("#\(tag)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(state.theme.secondaryInk)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(state.theme.subtleBorder, in: Capsule())
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.openDocument(at: doc.url, inNewTab: false)
                        }
                        .contextMenu {
                            Button("Yeni Sekmede Aç") {
                                state.openDocument(at: doc.url, inNewTab: true)
                            }
                            Button("Yan Yana (Sağ Panelde) Aç") {
                                state.openInSecondarySplit(url: doc.url)
                            }
                            Divider()
                            Button("Metadata & Adlandırma...") {
                                state.editingMetadataDocument = doc
                            }
                            Menu("Atıf Kopyala") {
                                ForEach(CitationStyle.allCases) { style in
                                    Button(style.rawValue) {
                                        state.copyCitationToPasteboard(forDocumentHash: doc.hash, style: style)
                                    }
                                }
                            }
                            Button("Etiketleri Düzenle...") {
                                tagEditInput = doc.tags.joined(separator: ", ")
                                editingTagDocument = doc
                            }
                            Button("Finder'da Göster") {
                                state.revealInFinder(at: doc.url)
                            }
                            Divider()
                            Button("Kütüphaneden Kaldır", role: .destructive) {
                                state.removeLibraryDocument(hash: doc.hash)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - 3. Global FTS5 Search Results

    private var globalSearchResultsList: some View {
        Group {
            if state.globalSearchResults.isEmpty {
                ContentUnavailableView(
                    "Eşleşme Bulunamadı",
                    systemImage: "magnifyingglass",
                    description: Text("İndekslenen kitaplarda ve notlarda sonuç bulunamadı.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    Section("Sonuçlar (\(state.globalSearchResults.count))") {
                        ForEach(state.globalSearchResults) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    if let color = result.highlightColor {
                                        Circle()
                                            .fill(color.swiftUIColor)
                                            .frame(width: 7, height: 7)
                                    }
                                    Text(result.kind.displayBadge)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())

                                    Text(result.documentTitle)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(state.theme.primaryInk)
                                        .lineLimit(1)

                                    Spacer()

                                    if result.pageIndex >= 0 {
                                        Text("s. \(result.pageIndex + 1)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(state.theme.secondaryInk)
                                    }
                                }

                                Text(result.snippet)
                                    .font(.caption2)
                                    .foregroundStyle(state.theme.secondaryInk)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                state.openGlobalSearchResult(result)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - 4. Outline / TOC

    private var outlineList: some View {
        Group {
            if let pane = state.activeTab?.activePane {
                if pane.metadata.outline.isEmpty && state.activeDocumentBookmarks.isEmpty {
                    ContentUnavailableView(
                        "İçindekiler Bulunamadı",
                        systemImage: "list.bullet.indent",
                        description: Text("Bu PDF'te içindekiler tablosu yok. ⌘D ile sayfalara yer imi ekleyebilirsiniz.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        if !state.activeDocumentBookmarks.isEmpty {
                            Section("Yer İmleri (\(state.activeDocumentBookmarks.count))") {
                                ForEach(state.activeDocumentBookmarks) { bm in
                                    HStack(spacing: 6) {
                                        Image(systemName: "bookmark.fill")
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)
                                        Text(bm.label.isEmpty ? "Sayfa \(bm.pageIndex + 1)" : bm.label)
                                            .font(.callout)
                                            .foregroundStyle(state.theme.primaryInk)
                                            .lineLimit(1)
                                        Spacer()
                                        Text("s. \(bm.pageIndex + 1)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(state.theme.secondaryInk)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        state.jumpToPage(bm.pageIndex)
                                    }
                                    .contextMenu {
                                        Button("Yer İmini Kaldır", role: .destructive) {
                                            state.removeBookmark(bm)
                                        }
                                    }
                                }
                            }
                        }

                        if !pane.metadata.outline.isEmpty {
                            Section("İçindekiler") {
                                OutlineGroup(pane.metadata.outline, children: \.optionalChildren) { item in
                                    HStack {
                                        Text(item.title)
                                            .font(.callout)
                                            .foregroundStyle(state.theme.primaryInk)
                                            .lineLimit(2)
                                        Spacer()
                                        Text("\(item.pageIndex + 1)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(state.theme.secondaryInk)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        state.jumpToPage(item.pageIndex)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ContentUnavailableView(
                    "Açık Belge Yok",
                    systemImage: "doc.text",
                    description: Text("İçindekiler ve yer imlerini görmek için bir PDF açın.")
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func presentAttachVaultFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Kitap Klasörü (Vault) Bağla"
        panel.message = "Seçilen klasör ve alt klasörleri canlı dosya yöneticisi olarak sol panele eklenecek."
        if panel.runModal() == .OK, let folder = panel.url {
            state.addWatchedFolder(url: folder)
        }
    }
}

// MARK: - Recursive Interactive File Tree Row (Drag & Drop + Context Menu)

private struct FileTreeNodeRow: View {
    let node: FileTreeNode
    let depth: Int
    @Bindable var state: WorkspaceState
    @Binding var expandedPaths: Set<String>
    let onRequestNewSubfolder: (FileTreeNode) -> Void
    let onRequestRename: (FileTreeNode) -> Void

    @State private var isDropTargeted: Bool = false

    private var isExpanded: Bool {
        expandedPaths.contains(node.id)
    }

    private var isActiveDocument: Bool {
        !node.isDirectory && state.activeTab?.activePane.url.path == node.url.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if node.isDirectory {
                directoryRow
                if isExpanded {
                    ForEach(node.children) { child in
                        FileTreeNodeRow(
                            node: child,
                            depth: depth + 1,
                            state: state,
                            expandedPaths: $expandedPaths,
                            onRequestNewSubfolder: onRequestNewSubfolder,
                            onRequestRename: onRequestRename
                        )
                    }
                }
            } else {
                pdfFileRow
            }
        }
    }

    private var directoryRow: some View {
        HStack(spacing: 5) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(state.theme.secondaryInk)
                .frame(width: 10)

            Image(systemName: node.isRootFolder ? "books.vertical.fill" : (isExpanded ? "folder.fill" : "folder"))
                .font(.caption)
                .foregroundStyle(node.isRootFolder ? Color.accentColor : state.theme.secondaryInk)

            Text(node.name)
                .font(.caption.weight(node.isRootFolder ? .semibold : .medium))
                .foregroundStyle(state.theme.primaryInk)
                .lineLimit(1)

            Spacer(minLength: 4)

            if node.pdfCount > 0 {
                Text("\(node.pdfCount)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(state.theme.secondaryInk)
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.14)) {
                if isExpanded {
                    expandedPaths.remove(node.id)
                } else {
                    expandedPaths.insert(node.id)
                }
            }
        }
        .draggable(node.url)
        .dropDestination(for: URL.self) { items, _ in
            var moved = false
            for droppedURL in items {
                state.moveFileItem(at: droppedURL, toFolder: node.url)
                moved = true
            }
            if moved {
                expandedPaths.insert(node.id)
            }
            return moved
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .contextMenu {
            Button("Yeni Alt Klasör...") {
                onRequestNewSubfolder(node)
            }
            Button("Yeniden Adlandır...") {
                onRequestRename(node)
            }
            Button("Finder'da Göster") {
                state.revealInFinder(at: node.url)
            }
            Divider()
            if node.isRootFolder {
                Button("Klasör Bağlantısını Kaldır", role: .destructive) {
                    state.removeWatchedFolder(path: node.url.path)
                }
            } else {
                Button("Çöp Kutusuna Taşı", role: .destructive) {
                    state.trashFileItem(at: node.url)
                }
            }
        }
    }

    private var pdfFileRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(isActiveDocument ? Color.accentColor : state.theme.secondaryInk)
                .frame(width: 12)

            Text(node.name)
                .font(.caption.weight(isActiveDocument ? .semibold : .regular))
                .foregroundStyle(isActiveDocument ? state.theme.primaryInk : state.theme.primaryInk.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.leading, CGFloat(depth) * 14 + 16)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActiveDocument ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.openDocument(at: node.url, inNewTab: false)
        }
        .draggable(node.url)
        .contextMenu {
            Button("Yeni Sekmede Aç") {
                state.openDocument(at: node.url, inNewTab: true)
            }
            Button("Yan Yana (Sağ Panelde) Aç") {
                state.openInSecondarySplit(url: node.url)
            }
            Divider()
            Button("Metadata & Adlandırma...") {
                state.openMetadataEditor(forURL: node.url)
            }
            Button("Yeniden Adlandır...") {
                onRequestRename(node)
            }
            let moveTargets = state.allFolderDirectories.filter {
                $0.url.path != node.url.deletingLastPathComponent().path
            }
            if !moveTargets.isEmpty {
                Menu("Klasöre Taşı") {
                    ForEach(moveTargets) { targetDir in
                        Button(targetDir.name) {
                            state.moveFileItem(at: node.url, toFolder: targetDir.url)
                        }
                    }
                }
            }
            Button("Finder'da Göster") {
                state.revealInFinder(at: node.url)
            }
            Divider()
            Button("Çöp Kutusuna Taşı", role: .destructive) {
                state.trashFileItem(at: node.url)
            }
        }
    }
}

private extension OutlineItem {
    var optionalChildren: [OutlineItem]? {
        children.isEmpty ? nil : children
    }
}
