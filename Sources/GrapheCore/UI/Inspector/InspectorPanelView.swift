import AppKit
import SwiftUI
@preconcurrency import Translation

public struct InspectorPanelView: View {
    @Bindable public var state: WorkspaceState

    @State private var manualQuery: String = ""
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var showCopiedToast: Bool = false
    @State private var copiedToastTask: Task<Void, Never>?
    @State private var showDictionaryManager: Bool = false

    public init(state: WorkspaceState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(RightPanelTab.allCases) { tab in
                    let isSelected = state.rightPanelTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            state.rightPanelTab = tab
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

            switch state.rightPanelTab {
            case .dictionary:
                dictionaryView
            case .notes:
                OneNoteWorkspaceView(state: state)
            case .footnotes:
                footnotesView
            }
        }
        .frame(minWidth: 280, idealWidth: 380, maxWidth: 960)
        .background(state.theme.chromeBackground)
        .sheet(isPresented: $showDictionaryManager, onDismiss: {
            state.refreshCurrentLookup()
        }) {
            DictionaryManagerSheet(manager: state.dictionaryManager, theme: state.theme)
        }
        .translationTask(translationConfig) { session in
            let requestedText = await MainActor.run {
                state.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !requestedText.isEmpty else { return }

            await MainActor.run {
                state.isTranslating = true
                state.translationError = nil
            }

            do {
                let response = try await session.translate(requestedText)
                await MainActor.run {
                    let currentText = state.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard currentText == requestedText else { return }
                    state.translatedText = response.targetText
                    state.isTranslating = false
                }
            } catch {
                await MainActor.run {
                    let currentText = state.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard currentText == requestedText else { return }
                    state.isTranslating = false
                    state.translationError = "Çevrimdışı çeviri için bu dil çifti macOS'te henüz indirilmemiş olabilir. Sistem Ayarları → Genel → Dil ve Bölge → Çeviri Dilleri bölümünden çevrimdışı paketi indirebilirsiniz."
                }
            }
        }
        .onAppear {
            if !state.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.translatedText.isEmpty {
                triggerTranslation(for: state.selectedText)
            }
        }
        .onChange(of: state.selectedText) { _, newValue in
            triggerTranslation(for: newValue)
        }
        .onChange(of: state.targetLanguage) { _, _ in
            triggerTranslation(for: state.selectedText)
        }
    }

    private var dictionaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Manual lookup bar + Dictionary Manager trigger
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(state.theme.secondaryInk)
                        TextField("Kelime veya ifade ara...", text: $manualQuery)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(state.theme.primaryInk)
                            .onSubmit {
                                let trimmed = manualQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    state.lookupManualTerm(trimmed)
                                }
                            }
                        if !manualQuery.isEmpty {
                            Button {
                                manualQuery = ""
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

                    Button {
                        showDictionaryManager = true
                    } label: {
                        Image(systemName: "books.vertical")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Akademik Sözlük Yöneticisi (StarDict)")
                }

                if state.selectedText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Akademik Sözlük & Çeviri", systemImage: "character.book.closed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(state.theme.primaryInk)
                        Text("• PDF'te bir kelimeye **Option (⌥) + Tık** yaparak anında sözlüğe bakabilirsiniz.\n• Sağ üstteki kitap simgesinden **StarDict (.ifo/.idx/.dict)** akademik sözlüklerinizi ekleyebilirsiniz.")
                            .font(.caption)
                            .foregroundStyle(state.theme.secondaryInk)

                        if state.dictionaryManager.installedDictionaries.isEmpty {
                            Button {
                                showDictionaryManager = true
                            } label: {
                                Label("StarDict Sözlük Ekle...", systemImage: "plus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(state.theme.surfaceBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(state.theme.subtleBorder, lineWidth: 1)
                    )
                } else {
                    selectedTextSection
                    dictionaryCardsSection
                    nearbySuggestionsSection
                    translationSection
                }

                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)
                vocabularySection
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedTextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Seçili Metin")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)

                if let langName = state.multiDictionaryResult?.detectedLanguageName {
                    Text(langName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                Button {
                    state.saveCurrentLookupToVocabulary()
                } label: {
                    Label("Kaydet", systemImage: "bookmark.fill")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Kelime Defterine Kaydet")
            }

            Text(state.selectedText)
                .font(.callout)
                .foregroundStyle(state.theme.primaryInk)
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var dictionaryCardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Sözlük Kaynakları", systemImage: "books.vertical")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)
                Spacer()
                Button {
                    showDictionaryManager = true
                } label: {
                    Text("Yönet (\(state.dictionaryManager.installedDictionaries.filter(\.isEnabled).count))")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }

            if let cards = state.multiDictionaryResult?.cards, !cards.isEmpty {
                VStack(spacing: 8) {
                    ForEach(cards) { card in
                        DictionaryResultCardView(card: card, theme: state.theme)
                    }
                }
            } else {
                Text("Etkin sözlüklerde bu madde bulunamadı. Yeni StarDict akademik sözlükleri eklemek için 'Yönet' düğmesini kullanabilirsiniz.")
                    .font(.caption)
                    .foregroundStyle(state.theme.secondaryInk)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(state.theme.surfaceBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(state.theme.subtleBorder, lineWidth: 1)
                    )
            }
        }
    }

    @ViewBuilder
    private var nearbySuggestionsSection: some View {
        if let suggestions = state.multiDictionaryResult?.nearbySuggestions, !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Yakın Maddeler")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)

                FlowLayoutChips(items: suggestions) { word in
                    state.lookupManualTerm(word)
                }
            }
        }
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Çevrimdışı Çeviri", systemImage: "translate")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)

                Spacer()

                Picker("", selection: $state.targetLanguage) {
                    ForEach(TargetLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 96)
            }

            if state.isTranslating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Çevriliyor...")
                        .font(.caption)
                        .foregroundStyle(state.theme.secondaryInk)
                }
                .padding(8)
            } else if !state.translatedText.isEmpty {
                Text(state.translatedText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if let error = state.translationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(state.theme.secondaryInk)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Aynı dil seçili veya çeviri hazır değil.")
                    .font(.caption)
                    .foregroundStyle(state.theme.secondaryInk)
            }
        }
    }

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Kelime Defteri (\(state.vocabulary.count))", systemImage: "bookmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)

                Spacer()

                if !state.vocabulary.isEmpty {
                    Button {
                        let md = state.exportVocabularyMarkdown()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(md, forType: .string)
                        showCopiedToast = true
                        copiedToastTask?.cancel()
                        copiedToastTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(1800))
                            guard !Task.isCancelled else { return }
                            showCopiedToast = false
                        }
                    } label: {
                        Text(showCopiedToast ? "Kopyalandı!" : "Markdown Kopyala")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if state.vocabulary.isEmpty {
                Text("Kaydettiğiniz kelimeler burada birikir.")
                    .font(.caption)
                    .foregroundStyle(state.theme.secondaryInk)
            } else {
                VStack(spacing: 6) {
                    ForEach(state.vocabulary) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.term)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    state.removeVocabularyItem(id: item.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                        .foregroundStyle(state.theme.secondaryInk)
                                }
                                .buttonStyle(.plain)
                            }

                            if let tr = item.translation, !tr.isEmpty {
                                Text(tr)
                                    .font(.caption)
                                    .foregroundStyle(state.theme.primaryInk)
                                    .lineLimit(2)
                            } else if let def = item.definition, !def.isEmpty {
                                Text(def)
                                    .font(.caption2)
                                    .foregroundStyle(state.theme.secondaryInk)
                                    .lineLimit(2)
                            }

                            if let doc = item.sourceDocumentTitle {
                                let page = item.pageIndex.map { " · s.\($0 + 1)" } ?? ""
                                Text("\(doc)\(page)")
                                    .font(.caption2)
                                    .foregroundStyle(state.theme.secondaryInk.opacity(0.8))
                                    .lineLimit(1)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(state.theme.surfaceBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(state.theme.subtleBorder, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.lookupManualTerm(item.term)
                        }
                    }
                }
            }
        }
    }

    private func triggerTranslation(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.translatedText = ""
            state.translationError = nil
            return
        }

        let detectedCode = state.multiDictionaryResult?.detectedLanguageCode
        if let detectedCode, detectedCode == state.targetLanguage.rawValue {
            state.translatedText = ""
            state.translationError = nil
            return
        }

        let sourceLang: Locale.Language? = detectedCode.map { Locale.Language(identifier: $0) }
        let targetLang = state.targetLanguage.localeLanguage

        if translationConfig == nil {
            translationConfig = TranslationSession.Configuration(source: sourceLang, target: targetLang)
        } else {
            translationConfig?.source = sourceLang
            translationConfig?.target = targetLang
            translationConfig?.invalidate()
        }
    }

    private var footnotesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Current Page Footnotes
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Bu Sayfadaki Dipnotlar (\(state.currentPageFootnotes.count))", systemImage: "text.alignleft")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(state.theme.secondaryInk)
                        Spacer()
                        if let pane = state.activeTab?.activePane {
                            Text("s. \(pane.currentPageIndex + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(state.theme.secondaryInk.opacity(0.8))
                        }
                    }

                    if state.activeTab == nil {
                        Text("Sayfadaki dipnotları görmek için bir PDF açın.")
                            .font(.caption)
                            .foregroundStyle(state.theme.secondaryInk)
                    } else if state.currentPageFootnotes.isEmpty {
                        Text("Bu sayfanın alt bölgesinde otomatik algılanan dipnot bulunamadı. PDF içi bağlantı veya numara üzerine tıklayarak dipnot önizleyebilirsiniz.")
                            .font(.caption)
                            .foregroundStyle(state.theme.secondaryInk)
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(state.theme.surfaceBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(state.theme.subtleBorder, lineWidth: 1)
                            )
                    } else {
                        VStack(spacing: 8) {
                            ForEach(state.currentPageFootnotes) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("#\(item.marker)")
                                            .font(.caption2.weight(.bold).monospacedDigit())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                                            .foregroundStyle(Color.accentColor)

                                        Spacer()

                                        Button {
                                            state.pinPageFootnote(item)
                                        } label: {
                                            Label("Sabitle", systemImage: "pin")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.borderless)
                                    }

                                    Text(item.text)
                                        .font(.caption)
                                        .foregroundStyle(state.theme.primaryInk)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(state.theme.surfaceBackground.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(state.theme.subtleBorder, lineWidth: 1)
                                )
                            }
                        }
                    }
                }

                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)

                // 2. Pinned Footnotes
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sabitlenmiş Dipnotlar (\(state.pinnedFootnotes.count))", systemImage: "pin.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.theme.secondaryInk)

                    if state.pinnedFootnotes.isEmpty {
                        Text("Uzun dipnot ve sonnotları buradan veya açılır önizleme penceresinden (Popover) sabitleyebilirsiniz.")
                            .font(.caption)
                            .foregroundStyle(state.theme.secondaryInk)
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(state.theme.surfaceBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(state.theme.subtleBorder, lineWidth: 1)
                            )
                    } else {
                        VStack(spacing: 8) {
                            ForEach(state.pinnedFootnotes) { preview in
                                PinnedFootnoteCardView(
                                    preview: preview,
                                    theme: state.theme,
                                    onJumpToPage: {
                                        state.jumpToPage(preview.targetPageIndex, recordHistory: true)
                                    },
                                    onOpenInSplit: {
                                        state.openFootnoteInSecondarySplit(targetPageIndex: preview.targetPageIndex)
                                    },
                                    onUnpin: {
                                        state.unpinFootnote(id: preview.id)
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PinnedFootnoteCardView: View {
    let preview: FootnotePreview
    let theme: ReadingTheme
    let onJumpToPage: () -> Void
    let onOpenInSplit: () -> Void
    let onUnpin: () -> Void

    @State private var displayMode: FootnoteDisplayMode

    init(
        preview: FootnotePreview,
        theme: ReadingTheme,
        onJumpToPage: @escaping () -> Void,
        onOpenInSplit: @escaping () -> Void,
        onUnpin: @escaping () -> Void
    ) {
        self.preview = preview
        self.theme = theme
        self.onJumpToPage = onJumpToPage
        self.onOpenInSplit = onOpenInSplit
        self.onUnpin = onUnpin
        self._displayMode = State(initialValue: preview.snapshotImage != nil ? .snapshot : .text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("#\(preview.marker)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)

                Text("s. \(preview.targetPageIndex + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondaryInk)

                Spacer()

                if !preview.extractedText.isEmpty && preview.snapshotImage != nil {
                    Picker("", selection: $displayMode) {
                        ForEach(FootnoteDisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 96)
                }

                Button(role: .destructive) {
                    onUnpin()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryInk)
                }
                .buttonStyle(.plain)
                .help("Sabitlemeyi Kaldır")
            }

            if displayMode == .text && !preview.extractedText.isEmpty {
                Text(preview.extractedText)
                    .font(.caption)
                    .foregroundStyle(theme.primaryInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let snapshot = preview.snapshotImage {
                Image(nsImage: snapshot)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .background(theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                Button {
                    onJumpToPage()
                } label: {
                    Label("Sayfaya Git", systemImage: "arrow.right.circle")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    onOpenInSplit()
                } label: {
                    Label("Yan Panelde Aç", systemImage: "rectangle.split.2x1")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceBackground.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.subtleBorder, lineWidth: 1)
        )
    }
}

private struct DictionaryResultCardView: View {
    let card: DictionaryCardResult
    let theme: ReadingTheme
    @State private var isExpanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.attributedText)
                    .font(.caption)
                    .foregroundStyle(theme.primaryInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: card.isSystemDictionary ? "apple.logo" : "book.closed.fill")
                    .font(.caption2)
                    .foregroundStyle(card.isSystemDictionary ? theme.secondaryInk : Color.accentColor)
                Text(card.sourceName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.primaryInk)
                    .lineLimit(1)
                Spacer()
                Text(card.matchedHeadword)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .background(theme.surfaceBackground.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.subtleBorder, lineWidth: 1)
        )
    }
}

private struct FlowLayoutChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { word in
                Button {
                    onTap(word)
                } label: {
                    Text(word)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
