import AppKit
import SwiftUI

public enum FootnoteDisplayMode: String, CaseIterable, Identifiable {
    case text = "Metin"
    case snapshot = "Görsel"

    public var id: String { rawValue }
}

public struct FootnotePopoverView: View {
    public let preview: FootnotePreview
    public let theme: ReadingTheme
    public let onLookupSelection: (String) -> Void
    public let onJumpToPage: () -> Void
    public let onOpenInSplit: () -> Void
    public let onPin: () -> Void
    public let onClose: () -> Void

    @State private var didCopyText = false

    public init(
        preview: FootnotePreview,
        theme: ReadingTheme = .original,
        onLookupSelection: @escaping (String) -> Void = { _ in },
        onJumpToPage: @escaping () -> Void,
        onOpenInSplit: @escaping () -> Void,
        onPin: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.preview = preview
        self.theme = theme
        self.onLookupSelection = onLookupSelection
        self.onJumpToPage = onJumpToPage
        self.onOpenInSplit = onOpenInSplit
        self.onPin = onPin
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.subtleBorder)
                .frame(height: 1)
            contentArea
            Rectangle()
                .fill(theme.subtleBorder)
                .frame(height: 1)
            footer
        }
        .frame(width: 480)
        .frame(minHeight: 180, maxHeight: 400)
        .background(theme.chromeBackground)
        .preferredColorScheme(theme.preferredColorScheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption2)
                    .foregroundStyle(theme.accentColor)
                Text("\(preview.origin.badgeTitle) #\(preview.marker)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accentColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(theme.accentSoftBackground, in: Capsule())

            Text("Sayfa \(preview.targetPageIndex + 1)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(theme.secondaryInk)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(theme.chromeBackground)
    }

    @ViewBuilder
    private var contentArea: some View {
        if let snapshot = preview.snapshotImage {
            ScrollView([.vertical, .horizontal]) {
                themedSnapshotImage(snapshot)
                    .frame(maxWidth: .infinity)
                    .padding(8)
            }
            .background(theme.surfaceBackground)
            .frame(minHeight: 140, maxHeight: 310)
        } else if !preview.extractedText.isEmpty {
            ScrollView {
                Text(preview.extractedText)
                    .font(.system(size: 13.5, design: .serif))
                    .lineSpacing(4)
                    .foregroundStyle(theme.primaryInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(theme.surfaceBackground)
            .frame(minHeight: 120, maxHeight: 310)
        } else {
            Text("Bu dipnot için önizleme oluşturulamadı.")
                .font(.caption)
                .foregroundStyle(theme.secondaryInk)
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 100)
                .background(theme.surfaceBackground)
        }
    }

    @ViewBuilder
    private func themedSnapshotImage(_ snapshot: NSImage) -> some View {
        let base = Image(nsImage: snapshot)
            .resizable()
            .scaledToFit()
        switch theme {
        case .original:
            base
        case .sepia:
            base.colorMultiply(Color(red: 0.96, green: 0.91, blue: 0.81))
        case .softDark:
            base.colorInvert()
                .opacity(0.88)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onJumpToPage()
                onClose()
            } label: {
                Label("Sayfaya Git", systemImage: "arrow.right.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                onOpenInSplit()
                onClose()
            } label: {
                Label("Yan Panelde Aç", systemImage: "rectangle.split.2x1")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if !preview.extractedText.isEmpty {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(preview.extractedText, forType: .string)
                    didCopyText = true
                } label: {
                    Label(didCopyText ? "Kopyalandı" : "Kopyala", systemImage: didCopyText ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Dipnot metnini panoya kopyala")
            }

            Spacer()

            Button {
                onPin()
                onClose()
            } label: {
                Label("Sabitle", systemImage: "pin.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.chromeBackground)
    }
}
