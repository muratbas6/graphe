import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct DictionaryManagerSheet: View {
    @Bindable public var manager: DictionaryManager
    public let theme: ReadingTheme
    @Environment(\.dismiss) private var dismiss

    public init(manager: DictionaryManager, theme: ReadingTheme = .original) {
        self.manager = manager
        self.theme = theme
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Akademik Sözlük Yöneticisi")
                        .font(.headline)
                        .foregroundStyle(theme.primaryInk)
                    Text("StarDict (.ifo / .idx / .dict / .dict.dz / .syn) sözlüklerini ekleyin ve sıralayın.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
                Spacer()
                Button("Kapat") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Rectangle()
                .fill(theme.subtleBorder)
                .frame(height: 1)

            HStack(spacing: 8) {
                Button {
                    pickFolder()
                } label: {
                    Label("Sözlük Klasörü Tara...", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    pickIfoFile()
                } label: {
                    Label("Tek Sözlük (.ifo) Ekle...", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if let error = manager.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            List {
                Section("Yüklü StarDict Sözlükleri (Öncelik Sırası)") {
                    if manager.installedDictionaries.isEmpty {
                        Text("Henüz StarDict sözlüğü eklenmedi. Klasör tarayarak veya .ifo dosyası seçerek Oxford, Duden, Wiktionary, Liddell-Scott veya Kubbealtı gibi akademik StarDict sözlüklerini ekleyebilirsiniz.")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryInk)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(Array(manager.installedDictionaries.enumerated()), id: \.element.id) { index, dict in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { dict.isEnabled },
                                    set: { _ in manager.toggleEnabled(id: dict.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dict.bookName)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(theme.primaryInk)
                                        .lineLimit(1)
                                    Text("\(dict.wordCount.formatted()) madde · \(dict.ifoURL.deletingLastPathComponent().lastPathComponent)")
                                        .font(.caption2)
                                        .foregroundStyle(theme.secondaryInk)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Button {
                                    manager.moveUp(id: dict.id)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)

                                Button {
                                    manager.moveDown(id: dict.id)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == manager.installedDictionaries.count - 1)

                                Button(role: .destructive) {
                                    manager.removeDictionary(id: dict.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Yerleşik Sistem Kaynağı") {
                    Toggle("macOS Yerleşik Sözlük (Apple Dictionary)", isOn: Binding(
                        get: { manager.includeSystemDictionary },
                        set: { manager.setIncludeSystemDictionary($0) }
                    ))
                    .font(.callout)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 540, height: 420)
        .background(theme.chromeBackground)
        .preferredColorScheme(theme.preferredColorScheme)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "StarDict Sözlük Klasörünü Seçin"
        if panel.runModal() == .OK, let url = panel.url {
            manager.scanFolder(at: url)
        }
    }

    private func pickIfoFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if let ifoType = UTType(filenameExtension: "ifo") {
            panel.allowedContentTypes = [ifoType]
        }
        panel.title = "StarDict .ifo Dosyasını Seçin"
        if panel.runModal() == .OK {
            for url in panel.urls {
                manager.addDictionary(ifoURL: url)
            }
        }
    }
}
