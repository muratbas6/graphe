#if os(macOS)
import AppKit
import SwiftUI

public struct MovePDFRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL

    public init(url: URL) {
        let std = url.standardizedFileURL
        self.id = std.path
        self.url = std
    }
}

public struct MoveFolderTarget: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let breadcrumb: String
    public let depth: Int
    public let pdfCount: Int

    public init(url: URL, name: String, breadcrumb: String, depth: Int, pdfCount: Int) {
        self.url = url.standardizedFileURL
        self.name = name
        self.breadcrumb = breadcrumb
        self.depth = depth
        self.pdfCount = pdfCount
    }
}

public struct MoveToFolderSheet: View {
    public let sourceURL: URL
    @Bindable public var state: WorkspaceState
    @Environment(\.dismiss) private var dismiss

    @State private var searchQuery: String = ""
    @State private var selectedFolderURL: URL?
    @State private var isCreatingSubfolder: Bool = false
    @State private var newSubfolderName: String = ""
    @State private var localError: String?
    @State private var hoveredID: String?
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isNewFolderFocused: Bool

    public init(sourceURL: URL, state: WorkspaceState) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.state = state
    }

    private var currentParentPath: String {
        sourceURL.deletingLastPathComponent().standardizedFileURL.path
    }

    private var allTargets: [MoveFolderTarget] {
        state.allDestinationFolderTargets()
    }

    private var filteredTargets: [MoveFolderTarget] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allTargets }
        return allTargets.filter { target in
            target.name.localizedCaseInsensitiveContains(q)
                || target.breadcrumb.localizedCaseInsensitiveContains(q)
        }
    }

    private var effectiveSelectedTarget: MoveFolderTarget? {
        if let selectedURL = selectedFolderURL,
           let match = filteredTargets.first(where: { $0.url.path == selectedURL.path }) {
            return match
        }
        return filteredTargets.first(where: { $0.url.path != currentParentPath })
            ?? filteredTargets.first
    }

    private var canMoveToSelection: Bool {
        guard let target = effectiveSelectedTarget else { return false }
        return target.url.path != currentParentPath
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "folder.badge.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.theme.accentColor)
                    .frame(width: 28, height: 28)
                    .background(state.theme.accentSoftBackground, in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Klasöre Taşı")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(state.theme.primaryInk)
                    Text(sourceURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(state.theme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state.theme.secondaryInk)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(state.theme.chromeBackground)

            Rectangle()
                .fill(state.theme.subtleBorder)
                .frame(height: 1)

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state.theme.secondaryInk)
                TextField("Klasör veya kategori ara (örn. okumalar, mantık)...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(state.theme.primaryInk)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if canMoveToSelection {
                            performMove()
                        }
                    }
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(state.theme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(state.theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(state.theme.subtleBorder, lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if let localError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(localError)
                        .font(.caption)
                        .foregroundStyle(state.theme.primaryInk)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            // Folder list
            if allTargets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 26))
                        .foregroundStyle(state.theme.secondaryInk.opacity(0.6))
                    Text("Henüz bağlı bir okuma klasörü yok.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(state.theme.primaryInk)
                    Text("Önce `okumalar` gibi bir klasörü Graphe'ye bağlayın; ardından tüm alt kategorileri burada listelenecek.")
                        .font(.caption)
                        .foregroundStyle(state.theme.secondaryInk)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 310)
                    Button {
                        pickAndLinkRootFolder()
                    } label: {
                        Label("Klasör Bağla...", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(state.theme.accentColor)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding(16)
            } else if filteredTargets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(state.theme.secondaryInk.opacity(0.55))
                    Text("“\(searchQuery)” ile eşleşen klasör bulunamadı.")
                        .font(.caption)
                        .foregroundStyle(state.theme.secondaryInk)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredTargets) { target in
                            folderRow(target)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 200, maxHeight: 280)
            }

            // Optional inline new subfolder creator
            if !allTargets.isEmpty {
                Rectangle()
                    .fill(state.theme.subtleBorder)
                    .frame(height: 1)

                if isCreatingSubfolder {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.caption)
                            .foregroundStyle(state.theme.accentColor)
                        TextField(
                            "“\(effectiveSelectedTarget?.name ?? allTargets.first?.name ?? "")” içine yeni alt klasör...",
                            text: $newSubfolderName
                        )
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(state.theme.primaryInk)
                        .focused($isNewFolderFocused)
                        .onSubmit {
                            createSubfolderNow()
                        }

                        Button("Oluştur") {
                            createSubfolderNow()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .tint(state.theme.accentColor)
                        .disabled(newSubfolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("İptal") {
                            isCreatingSubfolder = false
                            newSubfolderName = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(state.theme.surfaceBackground)
                } else {
                    HStack(spacing: 10) {
                        Button {
                            isCreatingSubfolder = true
                            newSubfolderName = ""
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isNewFolderFocused = true
                            }
                        } label: {
                            Label(
                                "“\(effectiveSelectedTarget?.name ?? allTargets.first?.name ?? "Klasör")” İçine Yeni Alt Klasör...",
                                systemImage: "folder.badge.plus"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(state.theme.accentColor)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            pickAndLinkRootFolder()
                        } label: {
                            Text("Başka Klasör Bağla...")
                                .font(.caption)
                                .foregroundStyle(state.theme.secondaryInk)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(state.theme.surfaceBackground)
                }
            }

            Rectangle()
                .fill(state.theme.subtleBorder)
                .frame(height: 1)

            // Footer actions
            HStack(spacing: 10) {
                if let target = effectiveSelectedTarget {
                    Text(target.breadcrumb)
                        .font(.caption2)
                        .foregroundStyle(state.theme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer()

                Button("İptal") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Buraya Taşı") {
                    performMove()
                }
                .buttonStyle(.borderedProminent)
                .tint(state.theme.accentColor)
                .disabled(!canMoveToSelection)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(state.theme.chromeBackground)
        }
        .frame(width: 440)
        .background(state.theme.windowBackground)
        .preferredColorScheme(state.theme.preferredColorScheme)
        .onAppear {
            state.refreshFolderTrees()
            if selectedFolderURL == nil {
                selectedFolderURL = allTargets.first(where: { $0.url.path != currentParentPath })?.url
                    ?? allTargets.first?.url
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
    }

    private func folderRow(_ target: MoveFolderTarget) -> some View {
        let isCurrent = (target.url.path == currentParentPath)
        let isSelected = (effectiveSelectedTarget?.url.path == target.url.path)
        let isHovered = (hoveredID == target.id)
        let showIndent = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Button {
            selectedFolderURL = target.url
            localError = nil
        } label: {
            HStack(spacing: 8) {
                if showIndent && target.depth > 0 {
                    Color.clear
                        .frame(width: CGFloat(min(target.depth, 5)) * 14, height: 1)
                }

                Image(systemName: target.depth == 0 ? "folder.fill" : "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? state.theme.accentColor : state.theme.secondaryInk)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? state.theme.secondaryInk : state.theme.primaryInk)
                        .lineLimit(1)

                    if !showIndent && target.depth > 0 {
                        Text(target.breadcrumb)
                            .font(.system(size: 10))
                            .foregroundStyle(state.theme.secondaryInk)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if isCurrent {
                    Text("Mevcut konum")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(state.theme.secondaryInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(state.theme.subtleBorder.opacity(0.6), in: Capsule())
                } else {
                    Text("\(target.pdfCount)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(state.theme.secondaryInk.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(state.theme.subtleBorder.opacity(0.45), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? state.theme.cardBackground
                            : (isHovered ? state.theme.primaryInk.opacity(0.05) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? state.theme.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? target.id : (hoveredID == target.id ? nil : hoveredID)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                selectedFolderURL = target.url
                if target.url.path != currentParentPath {
                    performMove()
                }
            }
        )
    }

    private func createSubfolderNow() {
        let trimmed = newSubfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parent = effectiveSelectedTarget?.url ?? allTargets.first?.url else {
            return
        }
        if let createdURL = state.createSubfolderAndReturnURL(named: trimmed, inside: parent) {
            selectedFolderURL = createdURL
            searchQuery = ""
            newSubfolderName = ""
            isCreatingSubfolder = false
            localError = nil
        } else {
            localError = state.errorMessage ?? "Alt klasör oluşturulamadı."
            state.errorMessage = nil
        }
    }

    private func pickAndLinkRootFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Klasör Bağla"
        panel.message = "Okuma klasörünüzü seçin (örn. okumalar)."
        if panel.runModal() == .OK, let url = panel.url {
            state.addWatchedFolder(url: url)
            selectedFolderURL = url.standardizedFileURL
            localError = nil
        }
    }

    private func performMove() {
        guard let target = effectiveSelectedTarget,
              target.url.path != currentParentPath else {
            return
        }
        if let err = state.moveFileItemReturningError(at: sourceURL, toFolder: target.url) {
            localError = err
            return
        }
        NotificationCenter.default.post(
            name: .grapheShowToast,
            object: nil,
            userInfo: ["message": "‘\(sourceURL.lastPathComponent)’ → ‘\(target.name)’ klasörüne taşındı."]
        )
        dismiss()
    }
}
#endif
