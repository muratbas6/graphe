import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct NotesInspectorView: View {
    @Bindable public var state: WorkspaceState

    @State private var quickHighlightColor: HighlightColor = .yellow
    @State private var quickHighlightNote: String = ""
    @State private var quickHighlightTags: String = ""

    @State private var showPageNoteComposer: Bool = false
    @State private var newPageNoteText: String = ""
    @State private var newPageNoteTags: String = ""

    @State private var selectedColorFilter: HighlightColor? = nil
    @State private var filterText: String = ""
    @State private var editingAnnotationID: UUID? = nil
    @State private var editNoteDraft: String = ""
    @State private var editTagsDraft: String = ""
    @State private var editColorDraft: HighlightColor = .yellow
    @State private var showExportToast: Bool = false
    @State private var exportToastTask: Task<Void, Never>?

    public init(state: WorkspaceState) {
        self.state = state
    }

    private var filteredAnnotations: [AnnotationItem] {
        let base = state.activeDocumentAnnotations
        return base.filter { item in
            if let colorFilter = selectedColorFilter, item.color != colorFilter {
                return false
            }
            let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                let haystack = "\(item.quote) \(item.note) \(item.tags.joined(separator: " "))"
                return haystack.localizedCaseInsensitiveContains(query)
            }
            return true
        }
    }

    public var body: some View {
        if state.activeTab == nil {
            ContentUnavailableView(
                "Açık Belge Yok",
                systemImage: "note.text",
                description: Text("Vurgu yapmak ve kenar notu almak için bir PDF açın.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(state.theme.chromeBackground)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let capture = state.activeSelection, !capture.text.isEmpty {
                        activeSelectionHighlightCard(capture: capture)
                    }

                    toolbarSection

                    if showPageNoteComposer {
                        pageNoteComposerCard
                    }

                    colorFilterBar

                    if filteredAnnotations.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "highlighter")
                                .font(.title2)
                                .foregroundStyle(state.theme.secondaryInk)
                            Text(state.activeDocumentAnnotations.isEmpty ? "Henüz vurgu veya not yok" : "Filtreye uyan not yok")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(state.theme.primaryInk)
                            Text("PDF'te metin seçip sağ tıklayın, ⇧⌘H / ⌥1–5 kısayollarını kullanın veya yukarıdan sayfa notu ekleyin.")
                                .font(.caption)
                                .foregroundStyle(state.theme.secondaryInk)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filteredAnnotations) { item in
                                annotationCard(item)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .background(state.theme.windowBackground)
        }
    }

    private func activeSelectionHighlightCard(capture: SelectionCapture) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Seçili Metni Vurgula (s. \(capture.pageIndex + 1))", systemImage: "highlighter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)
                Spacer()
                Text(quickHighlightColor.meaningLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(quickHighlightColor.swiftUIColor)
            }

            Text("“\(capture.text)”")
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(state.theme.primaryInk)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(quickHighlightColor.swiftUIColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                ForEach(HighlightColor.allCases) { color in
                    Button {
                        quickHighlightColor = color
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary, lineWidth: quickHighlightColor == color ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(color.fullLabel) (⌥\(color.shortcutDigit))")
                }

                Spacer()

                Button {
                    saveQuickHighlight()
                } label: {
                    Label("Vurgula", systemImage: "checkmark")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            TextField("Kenar notu ekle (opsiyonel)...", text: $quickHighlightNote, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(state.theme.primaryInk)
                .lineLimit(1...4)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(state.theme.subtleBorder, lineWidth: 1)
                )

            TextField("Etiketler (ör. varlık, zaman)", text: $quickHighlightTags)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(state.theme.primaryInk)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(state.theme.subtleBorder, lineWidth: 1)
                )
        }
        .padding(12)
        .background(state.theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(state.theme.subtleBorder, lineWidth: 1)
        )
        .shadow(color: state.theme.cardShadowColor, radius: state.theme.cardShadowRadius, y: state.theme.cardShadowY)
    }

    private var toolbarSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showPageNoteComposer.toggle()
                    }
                } label: {
                    Label("Sayfa Notu", systemImage: "plus.bubble")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    copyMarkdownToPasteboard()
                } label: {
                    Image(systemName: showExportToast ? "checkmark" : "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.activeDocumentAnnotations.isEmpty)
                .help("Notları Markdown olarak panoya kopyala")

                Button {
                    saveMarkdownFile()
                } label: {
                    Label(".md Aktar", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.activeDocumentAnnotations.isEmpty)
                .help("Akademik / Obsidian uyumlu Markdown (.md) olarak dışa aktar (⇧⌘E)")
            }

            if !state.activeDocumentAnnotations.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(state.theme.secondaryInk)
                    TextField("Bu kitaptaki notlarda ara...", text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(state.theme.primaryInk)
                    if !filterText.isEmpty {
                        Button {
                            filterText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
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
            }
        }
    }

    private var pageNoteComposerCard: some View {
        let currentPage = (state.activeTab?.activePane.currentPageIndex ?? 0) + 1
        return VStack(alignment: .leading, spacing: 8) {
            Text("Sayfa \(currentPage) İçin Serbest Not")
                .font(.caption.weight(.semibold))
                .foregroundStyle(state.theme.secondaryInk)

            TextEditor(text: $newPageNoteText)
                .font(.caption)
                .foregroundStyle(state.theme.primaryInk)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 68, maxHeight: 130)
                .padding(4)
                .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(state.theme.subtleBorder, lineWidth: 1)
                )

            TextField("Etiketler (virgülle ayırın)", text: $newPageNoteTags)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(state.theme.primaryInk)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(state.theme.subtleBorder, lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("İptal") {
                    showPageNoteComposer = false
                    newPageNoteText = ""
                    newPageNoteTags = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Notu Kaydet") {
                    let tags = parseTagInput(newPageNoteTags)
                    if state.addPageNote(note: newPageNoteText, color: .purple, tags: tags) != nil {
                        newPageNoteText = ""
                        newPageNoteTags = ""
                        showPageNoteComposer = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newPageNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(state.theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(state.theme.subtleBorder, lineWidth: 1)
        )
        .shadow(color: state.theme.cardShadowColor, radius: state.theme.cardShadowRadius, y: state.theme.cardShadowY)
    }

    private var colorFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    selectedColorFilter = nil
                } label: {
                    Text("Tümü (\(state.activeDocumentAnnotations.count))")
                        .font(.caption2.weight(selectedColorFilter == nil ? .semibold : .medium))
                        .foregroundStyle(selectedColorFilter == nil ? state.theme.accentColor : state.theme.secondaryInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(
                            selectedColorFilter == nil ? state.theme.accentSoftBackground : state.theme.cardBackground,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .stroke(selectedColorFilter == nil ? state.theme.accentColor.opacity(0.3) : state.theme.subtleBorder, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)

                ForEach(HighlightColor.allCases) { color in
                    let count = state.activeDocumentAnnotations.filter { $0.color == color }.count
                    if count > 0 || selectedColorFilter == color {
                        Button {
                            selectedColorFilter = selectedColorFilter == color ? nil : color
                        } label: {
                            HStack(spacing: 4.5) {
                                Circle()
                                    .fill(color.swiftUIColor)
                                    .frame(width: 8, height: 8)
                                Text("\(color.meaningLabel) (\(count))")
                                    .font(.caption2.weight(selectedColorFilter == color ? .semibold : .medium))
                                    .foregroundStyle(selectedColorFilter == color ? state.theme.primaryInk : state.theme.secondaryInk)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(
                                selectedColorFilter == color ? color.swiftUIColor.opacity(0.18) : state.theme.cardBackground,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(selectedColorFilter == color ? color.swiftUIColor.opacity(0.45) : state.theme.subtleBorder, lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func annotationCard(_ item: AnnotationItem) -> some View {
        let isEditing = editingAnnotationID == item.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(item.color.swiftUIColor)
                    .frame(width: 9, height: 9)

                Text(item.kind == .highlight ? item.color.meaningLabel : "Sayfa Notu")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)

                Spacer()

                Button {
                    state.jumpToPage(item.pageIndex)
                } label: {
                    Text("s. \(item.pageIndex + 1)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(state.theme.accentColor)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(state.theme.accentSoftBackground, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Sayfa \(item.pageIndex + 1)'e git")

                if !item.quote.isEmpty {
                    Button {
                        _ = state.sendQuoteToNotebook(
                            quote: item.quote,
                            sourcePageIndex: item.pageIndex,
                            color: item.color,
                            initialNote: item.note
                        )
                    } label: {
                        Image(systemName: "book.pages")
                            .font(.caption2)
                            .foregroundStyle(state.theme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .help("OneNote Defterine Alıntı Kutusu Olarak Gönder")
                }

                Button {
                    if isEditing {
                        editingAnnotationID = nil
                    } else {
                        editingAnnotationID = item.id
                        editNoteDraft = item.note
                        editTagsDraft = item.tags.joined(separator: ", ")
                        editColorDraft = item.color
                    }
                } label: {
                    Image(systemName: isEditing ? "xmark" : "pencil")
                        .font(.caption2)
                        .foregroundStyle(state.theme.secondaryInk)
                }
                .buttonStyle(.plain)
                .help("Düzenle")

                Button {
                    state.deleteAnnotation(id: item.id, documentHash: item.documentHash)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(state.theme.secondaryInk)
                }
                .buttonStyle(.plain)
                .help("Sil")
            }

            if !item.quote.isEmpty {
                Text("“\(item.quote)”")
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(state.theme.primaryInk)
                    .textSelection(.enabled)
                    .onTapGesture {
                        state.jumpToPage(item.pageIndex)
                    }
            }

            if isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    if item.kind == .highlight {
                        HStack(spacing: 6) {
                            ForEach(HighlightColor.allCases) { color in
                                Button {
                                    editColorDraft = color
                                } label: {
                                    Circle()
                                        .fill(color.swiftUIColor)
                                        .frame(width: 15, height: 15)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.primary, lineWidth: editColorDraft == color ? 2 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(color.fullLabel)
                            }
                        }
                    }

                    TextField("Notunuz...", text: $editNoteDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(state.theme.primaryInk)
                        .lineLimit(2...5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(state.theme.subtleBorder, lineWidth: 1)
                        )

                    TextField("Etiketler (virgülle ayırın)", text: $editTagsDraft)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(state.theme.primaryInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(state.theme.subtleBorder, lineWidth: 1)
                        )

                    HStack {
                        Spacer()
                        Button("Kaydet") {
                            var updated = item
                            updated.note = editNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            updated.tags = parseTagInput(editTagsDraft)
                            updated.color = editColorDraft
                            state.updateAnnotation(updated)
                            editingAnnotationID = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            } else {
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.system(size: 12))
                        .lineSpacing(2.5)
                        .foregroundStyle(state.theme.primaryInk.opacity(0.9))
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }

                if !item.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(item.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.caption2)
                                    .foregroundStyle(state.theme.secondaryInk)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(state.theme.windowBackground, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .background(state.theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(item.color.swiftUIColor)
                .frame(width: 3.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(state.theme.subtleBorder, lineWidth: 1)
        )
        .shadow(color: state.theme.cardShadowColor, radius: state.theme.cardShadowRadius, y: state.theme.cardShadowY)
    }

    private func saveQuickHighlight() {
        let tags = parseTagInput(quickHighlightTags)
        if state.createHighlightFromActiveSelection(
            color: quickHighlightColor,
            note: quickHighlightNote,
            tags: tags
        ) != nil {
            quickHighlightNote = ""
            quickHighlightTags = ""
            state.activeSelection = nil
        }
    }

    private func parseTagInput(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
    }

    private func copyMarkdownToPasteboard() {
        guard let markdown = state.exportActiveDocumentMarkdown() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown, forType: .string)
        showExportToast = true
        exportToastTask?.cancel()
        exportToastTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            showExportToast = false
        }
    }

    private func saveMarkdownFile() {
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
            } catch {
                state.errorMessage = "Notlar dışa aktarılamadı: \(error.localizedDescription)"
            }
        }
    }
}
