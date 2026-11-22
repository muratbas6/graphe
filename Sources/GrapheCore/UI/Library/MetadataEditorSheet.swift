import SwiftUI

public struct MetadataEditorSheet: View {
    public let document: LibraryDocumentRecord
    @Bindable public var state: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var draft = BookMetadataDraft()
    @State private var yearText: String = ""
    @State private var isEnriching: Bool = false
    @State private var statusMessage: String?
    @State private var isErrorStatus: Bool = false

    public init(document: LibraryDocumentRecord, state: WorkspaceState) {
        self.document = document
        self.state = state
    }

    private var previewFilename: String {
        var copy = draft
        copy.year = Int(yearText.trimmingCharacters(in: .whitespaces))
        return "\(copy.suggestedFileStem()).pdf"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kitap Metadata & Dosya Adlandırma")
                        .font(.headline)
                        .foregroundStyle(state.theme.primaryInk)
                    Text(document.url.lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(state.theme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    enrichFromWeb()
                } label: {
                    if isEnriching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("İnternetten Tamamla", systemImage: "globe")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isEnriching)
                .help("CrossRef / OpenLibrary üzerinden Yazar, Yıl, Yayınevi ve Başlık tamamla")
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(isErrorStatus ? Color.red : Color.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (isErrorStatus ? Color.red : Color.green).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }

            VStack(alignment: .leading, spacing: 10) {
                labeledField("Kitap Adı", text: $draft.title)
                labeledField("Yazar", text: $draft.author)

                HStack(spacing: 10) {
                    labeledField("Yıl", text: $yearText)
                        .frame(width: 96)
                    labeledField("Yayınevi", text: $draft.publisher)
                }

                HStack(spacing: 10) {
                    labeledField("ISBN", text: $draft.isbn)
                    labeledField("DOI", text: $draft.doi)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Önerilen Temiz Dosya Adı")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(state.theme.secondaryInk)
                Text(previewFilename)
                    .font(.caption.monospaced())
                    .foregroundStyle(state.theme.primaryInk)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(state.theme.subtleBorder, lineWidth: 1)
                    )
            }

            HStack {
                Button("İptal") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Sadece Bilgileri Kaydet") {
                    save(andRenameFile: false)
                }
                .buttonStyle(.bordered)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Kaydet ve Dosyayı Adlandır") {
                    save(andRenameFile: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        .background(state.theme.chromeBackground)
        .preferredColorScheme(state.theme.preferredColorScheme)
        .task(id: document.hash) {
            let service = state.metadataService
            let url = document.url
            let existing = document
            let extracted = await Task.detached(priority: .userInitiated) {
                service.extractOfflineMetadata(from: url, existing: existing)
            }.value
            draft = extracted
            yearText = extracted.year.map(String.init) ?? ""
        }
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(state.theme.secondaryInk)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(state.theme.primaryInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(state.theme.surfaceBackground, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(state.theme.subtleBorder, lineWidth: 1)
                )
        }
    }

    private func enrichFromWeb() {
        isEnriching = true
        statusMessage = nil
        var current = draft
        current.year = Int(yearText.trimmingCharacters(in: .whitespaces))
        let service = state.metadataService

        Task {
            do {
                let enriched = try await service.enrichOnline(draft: current)
                await MainActor.run {
                    draft = enriched
                    yearText = enriched.year.map(String.init) ?? ""
                    isEnriching = false
                    isErrorStatus = false
                    statusMessage = "CrossRef / OpenLibrary kaydı bulundu ve alanlar dolduruldu."
                }
            } catch {
                await MainActor.run {
                    isEnriching = false
                    isErrorStatus = true
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func save(andRenameFile: Bool) {
        var finalDraft = draft
        finalDraft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        finalDraft.author = draft.author.trimmingCharacters(in: .whitespacesAndNewlines)
        finalDraft.publisher = draft.publisher.trimmingCharacters(in: .whitespacesAndNewlines)
        finalDraft.isbn = draft.isbn.trimmingCharacters(in: .whitespacesAndNewlines)
        finalDraft.doi = draft.doi.trimmingCharacters(in: .whitespacesAndNewlines)
        finalDraft.year = Int(yearText.trimmingCharacters(in: .whitespaces))

        state.errorMessage = nil
        state.saveDocumentMetadata(hash: document.hash, draft: finalDraft, alsoRenameFile: andRenameFile)
        if let err = state.errorMessage {
            statusMessage = err
            isErrorStatus = true
            state.errorMessage = nil
        } else {
            dismiss()
        }
    }
}
