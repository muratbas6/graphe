import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var selectedFolderURL: URL? = nil

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
            // Warm Editorial Segmented Control (Kitaplar / Defterler / İçindekiler)
            HStack(spacing: 2) {
                ForEach(LeftPanelTab.allCases) { tab in
                    let isSelected = state.leftPanelTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            state.leftPanelTab = tab
                        }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? state.theme.primaryInk : state.theme.secondaryInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5.5)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isSelected ? state.theme.cardBackground : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(isSelected ? state.theme.subtleBorder : Color.clear, lineWidth: 0.8)
                            )
                            .shadow(
                                color: isSelected ? state.theme.cardShadowColor : .clear,
                                radius: isSelected ? 3 : 0,
                                y: isSelected ? 1 : 0
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(state.theme.windowBackground, in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(state.theme.subtleBorder, lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.top, 11)
            .padding(.bottom, 9)

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
                Text("BAĞIMSIZ DEFTERLER")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(state.theme.secondaryInk)
                Spacer()
                Button {
                    _ = state.createStandaloneNotebook()
                } label: {
                    Label("Yeni", systemImage: "plus")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(state.theme.primaryInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(state.theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(state.theme.subtleBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Yeni Bağımsız Defter Oluştur (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

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
                    LazyVStack(spacing: 4) {
                        ForEach(state.standaloneNotebooks) { nb in
                            let isActive = (state.activeStandaloneNotebookID == nb.id)
                            SidebarSelectableRow(isSelected: isActive, theme: state.theme) {
                                state.openStandaloneNotebook(id: nb.id)
                            } content: {
                                HStack(spacing: 9) {
                                    Circle()
                                        .fill(nb.color.swiftUIColor)
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(nb.title)
                                            .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                                            .foregroundStyle(isActive ? state.theme.primaryInk : state.theme.primaryInk.opacity(0.88))
                                            .lineLimit(1)
                                        Text(nb.updatedAt, style: .date)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(state.theme.secondaryInk.opacity(0.85))
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                            }
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: - Library Section (Global Search + Klasörler | Tümü)

    private var librarySection: some View {
        VStack(spacing: 0) {
            // Global FTS5 Search bar across all books, highlights & OneNote notebooks
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(state.theme.secondaryInk)
                TextField("Kütüphanede ara…", text: Binding(
                    get: { state.globalSearchQuery },
                    set: { state.scheduleGlobalSearch($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
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
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(state.theme.cardBackground, in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(state.theme.subtleBorder, lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if !state.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                globalSearchResultsList
            } else {
                // Compact mode switcher: Klasörler | Tümü + Folder Actions
                HStack(spacing: 5) {
                    ForEach(LibraryViewMode.allCases) { mode in
                        let isSelected = state.libraryViewMode == mode
                        Button {
                            withAnimation(.easeInOut(duration: 0.14)) {
                                state.libraryViewMode = mode
                            }
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? state.theme.primaryInk : state.theme.secondaryInk)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected ? state.theme.cardBackground : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isSelected ? state.theme.subtleBorder : Color.clear, lineWidth: 0.8)
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
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Klasörleri Yenile")
                        }

                        Menu {
                            if let targetNode = resolvedActiveFolderNode() {
                                Button {
                                    presentImportPDFsPanel(into: targetNode)
                                } label: {
                                    Label("‘\(targetNode.name)’ İçine PDF Ekle...", systemImage: "doc.badge.plus")
                                }

                                Button {
                                    newSubfolderName = ""
                                    newSubfolderParent = targetNode
                                } label: {
                                    Label("‘\(targetNode.name)’ İçine Yeni Alt Klasör...", systemImage: "folder.badge.plus")
                                }

                                Divider()
                            }

                            Button {
                                presentAttachVaultFolderPanel()
                            } label: {
                                Label("Mevcut Klasör Bağla...", systemImage: "folder.badge.gearshape")
                            }
                        } label: {
                            Label("Ekle", systemImage: "plus")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(state.theme.primaryInk)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(state.theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(state.theme.subtleBorder, lineWidth: 1)
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("PDF Ekle, Yeni Alt Klasör Oluştur veya Klasör Bağla")
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
                .padding(.horizontal, 12)
                .padding(.bottom, 7)

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
                                selectedFolderURL: $selectedFolderURL,
                                onRequestImportPDFs: { target in
                                    presentImportPDFsPanel(into: target)
                                },
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
                                .foregroundStyle(state.selectedTagFilter == nil ? state.theme.accentColor : state.theme.primaryInk)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(
                                    state.selectedTagFilter == nil ? state.theme.accentSoftBackground : state.theme.cardBackground,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(state.selectedTagFilter == nil ? state.theme.accentColor.opacity(0.3) : state.theme.subtleBorder, lineWidth: 0.8)
                                )
                        }
                        .buttonStyle(.plain)

                        ForEach(state.allTags, id: \.self) { tag in
                            Button {
                                state.selectedTagFilter = state.selectedTagFilter == tag ? nil : tag
                            } label: {
                                Text("#\(tag)")
                                    .font(.caption2.weight(state.selectedTagFilter == tag ? .semibold : .regular))
                                    .foregroundStyle(state.selectedTagFilter == tag ? state.theme.accentColor : state.theme.primaryInk)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        state.selectedTagFilter == tag ? state.theme.accentSoftBackground : state.theme.cardBackground,
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(state.selectedTagFilter == tag ? state.theme.accentColor.opacity(0.3) : state.theme.subtleBorder, lineWidth: 0.8)
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        Text("KİTAPLAR")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(state.theme.secondaryInk)
                            .padding(.horizontal, 6)
                            .padding(.top, 2)
                            .padding(.bottom, 2)

                        ForEach(state.filteredLibraryDocuments) { doc in
                            let isActiveDoc = state.activeStandaloneNotebookID == nil && state.activeTab?.activePane.url.path == doc.url.path
                            SidebarSelectableRow(isSelected: isActiveDoc, theme: state.theme) {
                                state.openDocument(at: doc.url, inNewTab: false)
                            } content: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 5) {
                                        Text(doc.title)
                                            .font(.system(size: 12, weight: isActiveDoc ? .semibold : .medium))
                                            .foregroundStyle(isActiveDoc ? state.theme.primaryInk : state.theme.primaryInk.opacity(0.9))
                                            .lineLimit(1)
                                        Spacer()
                                        if state.indexingDocumentHashes.contains(doc.hash) {
                                            ProgressView()
                                                .controlSize(.mini)
                                                .help("Tam metin indeksleniyor...")
                                        } else if doc.isIndexed {
                                            Image(systemName: "text.magnifyingglass")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(isActiveDoc ? state.theme.accentColor : state.theme.secondaryInk.opacity(0.75))
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
                                                    .fill(state.theme.accentColor.opacity(0.75))
                                                    .frame(width: max(4, geo.size.width * prog.fraction))
                                            }
                                        }
                                        .frame(height: 2.5)
                                        .padding(.top, 1)
                                    }

                                    if !doc.tags.isEmpty {
                                        HStack(spacing: 4) {
                                            ForEach(doc.tags.prefix(3), id: \.self) { tag in
                                                Text("#\(tag)")
                                                    .font(.system(size: 9.5))
                                                    .foregroundStyle(state.theme.secondaryInk)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1.5)
                                                    .background(state.theme.windowBackground, in: Capsule())
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
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
                                Button("Klasöre Taşı...") {
                                    state.presentMoveToFolder(url: doc.url)
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
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
                                        .foregroundStyle(state.theme.accentColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(state.theme.accentSoftBackground, in: Capsule())

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
                                            .foregroundStyle(state.theme.accentColor)
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
            selectedFolderURL = folder.standardizedFileURL
            expandedFolderPaths.insert(folder.standardizedFileURL.path)
        }
    }

    private func resolvedActiveFolderNode() -> FileTreeNode? {
        if let selected = selectedFolderURL {
            for root in state.folderTrees {
                if let found = findFolderNode(in: root, matchingPath: selected.standardizedFileURL.path) {
                    return found
                }
            }
        }
        return state.folderTrees.first
    }

    private func findFolderNode(in node: FileTreeNode, matchingPath path: String) -> FileTreeNode? {
        if node.isDirectory && node.url.standardizedFileURL.path == path {
            return node
        }
        for child in node.children where child.isDirectory {
            if let found = findFolderNode(in: child, matchingPath: path) {
                return found
            }
        }
        return nil
    }

    private func presentImportPDFsPanel(into targetFolder: FileTreeNode) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "‘\(targetFolder.name)’ Klasörüne PDF Ekle"
        panel.message = "Seçilen PDF dosyaları ‘\(targetFolder.name)’ klasörüne taşınacak ve kütüphaneye eklenecek."
        panel.prompt = "Klasöre Ekle"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            expandedFolderPaths.insert(targetFolder.id)
            selectedFolderURL = targetFolder.url
            _ = state.importPDFs(from: panel.urls, into: targetFolder.url, openFirst: panel.urls.count == 1)
        }
    }
}

// MARK: - Recursive Interactive File Tree Row (Drag & Drop + Hover Actions + Context Menu)

private struct FileTreeNodeRow: View {
    let node: FileTreeNode
    let depth: Int
    @Bindable var state: WorkspaceState
    @Binding var expandedPaths: Set<String>
    @Binding var selectedFolderURL: URL?
    let onRequestImportPDFs: (FileTreeNode) -> Void
    let onRequestNewSubfolder: (FileTreeNode) -> Void
    let onRequestRename: (FileTreeNode) -> Void

    @State private var isDropTargeted: Bool = false
    @State private var isHovered: Bool = false

    private var isExpanded: Bool {
        expandedPaths.contains(node.id)
    }

    private var isSelectedFolder: Bool {
        node.isDirectory && selectedFolderURL?.standardizedFileURL.path == node.url.standardizedFileURL.path
    }

    private var isActiveDocument: Bool {
        !node.isDirectory && state.activeStandaloneNotebookID == nil && state.activeTab?.activePane.url.path == node.url.path
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
                            selectedFolderURL: $selectedFolderURL,
                            onRequestImportPDFs: onRequestImportPDFs,
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
                .foregroundStyle((node.isRootFolder || isSelectedFolder) ? state.theme.accentColor : state.theme.secondaryInk)

            Text(node.name)
                .font(.caption.weight((node.isRootFolder || isSelectedFolder) ? .semibold : .medium))
                .foregroundStyle(state.theme.primaryInk)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isHovered {
                HStack(spacing: 3) {
                    Menu {
                        Button {
                            onRequestImportPDFs(node)
                        } label: {
                            Label("PDF Ekle...", systemImage: "doc.badge.plus")
                        }
                        Button {
                            onRequestNewSubfolder(node)
                        } label: {
                            Label("Yeni Alt Klasör...", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(state.theme.primaryInk)
                            .frame(width: 18, height: 18)
                            .background(state.theme.cardBackground.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Bu Klasöre PDF veya Alt Klasör Ekle")

                    Button {
                        onRequestRename(node)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(state.theme.secondaryInk)
                            .frame(width: 18, height: 18)
                            .background(state.theme.cardBackground.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Yeniden Adlandır")

                    Menu {
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
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(state.theme.secondaryInk)
                            .frame(width: 18, height: 18)
                            .background(state.theme.cardBackground.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Klasör Seçenekleri")
                }
            } else if node.pdfCount > 0 {
                Text("\(node.pdfCount)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(state.theme.secondaryInk)
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isDropTargeted
                        ? state.theme.accentSoftBackground
                        : (isHovered ? state.theme.hoverFill : (isSelectedFolder ? state.theme.cardBackground.opacity(0.6) : Color.clear))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isDropTargeted
                        ? state.theme.accentColor.opacity(0.6)
                        : (isSelectedFolder ? state.theme.subtleBorder : Color.clear),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            selectedFolderURL = node.url
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
            let pdfs = items.filter { $0.pathExtension.lowercased() == "pdf" }
            let others = items.filter { $0.pathExtension.lowercased() != "pdf" }
            var handled = false
            if !pdfs.isEmpty {
                let count = state.importPDFs(from: pdfs, into: node.url, openFirst: false)
                handled = handled || (count > 0)
            }
            for otherURL in others {
                state.moveFileItem(at: otherURL, toFolder: node.url)
                handled = true
            }
            if handled {
                expandedPaths.insert(node.id)
                selectedFolderURL = node.url
            }
            return handled
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .contextMenu {
            Button("Bu Klasöre PDF Ekle...") {
                onRequestImportPDFs(node)
            }
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
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(isActiveDocument ? state.theme.accentColor : state.theme.secondaryInk)
                .frame(width: 12)

            Text(node.name)
                .font(.system(size: 11.5, weight: isActiveDocument ? .semibold : .regular))
                .foregroundStyle(isActiveDocument ? state.theme.primaryInk : state.theme.primaryInk.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 4)

            if isHovered {
                Menu {
                    Button("Yan Yana (Sağ Panelde) Aç") {
                        state.openInSecondarySplit(url: node.url)
                    }
                    Divider()
                    Button("Metadata & Adlandırma...") {
                        state.openMetadataEditor(forURL: node.url)
                    }
                    Button("Klasöre Taşı...") {
                        state.presentMoveToFolder(url: node.url)
                    }
                    Button("Yeniden Adlandır...") {
                        onRequestRename(node)
                    }
                    Button("Finder'da Göster") {
                        state.revealInFinder(at: node.url)
                    }
                    Divider()
                    Button("Çöp Kutusuna Taşı", role: .destructive) {
                        state.trashFileItem(at: node.url)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(state.theme.secondaryInk)
                        .frame(width: 18, height: 18)
                        .background(state.theme.cardBackground.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Kitap İşlemleri")
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActiveDocument ? state.theme.cardBackground : (isHovered ? state.theme.hoverFill : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActiveDocument ? state.theme.subtleBorder : Color.clear, lineWidth: 1)
        )
        .shadow(
            color: isActiveDocument ? state.theme.cardShadowColor : .clear,
            radius: isActiveDocument ? 4 : 0,
            y: isActiveDocument ? 1.5 : 0
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.openDocument(at: node.url, inNewTab: false)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
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
            Button("Klasöre Taşı...") {
                state.presentMoveToFolder(url: node.url)
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

private struct SidebarSelectableRow<Content: View>: View {
    let isSelected: Bool
    let theme: ReadingTheme
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            content()
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
                    radius: isSelected ? 5 : 0,
                    y: isSelected ? 1.5 : 0
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
