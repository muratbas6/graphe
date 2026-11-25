#if os(macOS)
import AppKit
import SwiftUI

public struct ReaderPaneView: View {
    public let pane: ReaderPaneState
    public let side: PaneSide
    public let isActive: Bool
    public let isSplit: Bool
    public let isBookmarked: Bool
    public let theme: ReadingTheme
    public let isSyncScrollEnabled: Bool
    public let syncScrollSignal: SyncScrollSignal?
    public let footnoteResolver: FootnoteResolver
    public let annotations: [AnnotationItem]
    public let layoutRefreshToken: UUID
    public let isTwoUpBookMode: Bool
    public let isSnapshotMode: Bool
    public let isReadingRulerEnabled: Bool
    public let ocrPageProvider: (Int) -> OCRPageResult?

    public let onActivate: () -> Void
    public let onPositionChanged: (Int, Double) -> Void
    public let onSelectionChanged: (String) -> Void
    public let onSelectionCaptured: (SelectionCapture?) -> Void
    public let onQuickHighlight: (SelectionCapture, HighlightColor, Bool) -> Void
    public let onSendToNotebook: (SelectionCapture) -> Void
    public let onCopyWithCitation: (SelectionCapture) -> Void
    public let onScrollNormalized: (Double) -> Void
    public let onJumpToPage: (Int) -> Void
    public let onGoBack: () -> Void
    public let onGoForward: () -> Void
    public let onZoom: (ZoomAction) -> Void
    public let onFootnoteJumpToPage: (Int) -> Void
    public let onFootnoteOpenInSplit: (Int) -> Void
    public let onFootnotePin: (FootnotePreview) -> Void
    public let onToggleBookmark: () -> Void
    public let onCloseSecondary: (() -> Void)?
    public let onSnapshotCaptured: (NSImage) -> Void
    public let onCancelSnapshotMode: () -> Void
    public let onHighlightClicked: (AnnotationItem) -> Void

    @State private var pageInput: String = ""
    @State private var isHeaderHovered: Bool = false
    @FocusState private var isPageFieldFocused: Bool

    public init(
        pane: ReaderPaneState,
        side: PaneSide,
        isActive: Bool,
        isSplit: Bool,
        isBookmarked: Bool = false,
        theme: ReadingTheme,
        isSyncScrollEnabled: Bool = false,
        syncScrollSignal: SyncScrollSignal?,
        footnoteResolver: FootnoteResolver = FootnoteResolver(),
        annotations: [AnnotationItem] = [],
        layoutRefreshToken: UUID = UUID(),
        isTwoUpBookMode: Bool = false,
        isSnapshotMode: Bool = false,
        isReadingRulerEnabled: Bool = false,
        ocrPageProvider: @escaping (Int) -> OCRPageResult? = { _ in nil },
        onActivate: @escaping () -> Void,
        onPositionChanged: @escaping (Int, Double) -> Void,
        onSelectionChanged: @escaping (String) -> Void,
        onSelectionCaptured: @escaping (SelectionCapture?) -> Void = { _ in },
        onQuickHighlight: @escaping (SelectionCapture, HighlightColor, Bool) -> Void = { _, _, _ in },
        onSendToNotebook: @escaping (SelectionCapture) -> Void = { _ in },
        onCopyWithCitation: @escaping (SelectionCapture) -> Void = { _ in },
        onScrollNormalized: @escaping (Double) -> Void,
        onJumpToPage: @escaping (Int) -> Void,
        onGoBack: @escaping () -> Void,
        onGoForward: @escaping () -> Void,
        onZoom: @escaping (ZoomAction) -> Void,
        onFootnoteJumpToPage: @escaping (Int) -> Void,
        onFootnoteOpenInSplit: @escaping (Int) -> Void,
        onFootnotePin: @escaping (FootnotePreview) -> Void,
        onToggleBookmark: @escaping () -> Void = {},
        onCloseSecondary: (() -> Void)? = nil,
        onSnapshotCaptured: @escaping (NSImage) -> Void = { _ in },
        onCancelSnapshotMode: @escaping () -> Void = {},
        onHighlightClicked: @escaping (AnnotationItem) -> Void = { _ in }
    ) {
        self.pane = pane
        self.side = side
        self.isActive = isActive
        self.isSplit = isSplit
        self.isBookmarked = isBookmarked
        self.theme = theme
        self.isSyncScrollEnabled = isSyncScrollEnabled
        self.syncScrollSignal = syncScrollSignal
        self.footnoteResolver = footnoteResolver
        self.annotations = annotations
        self.layoutRefreshToken = layoutRefreshToken
        self.isTwoUpBookMode = isTwoUpBookMode
        self.isSnapshotMode = isSnapshotMode
        self.isReadingRulerEnabled = isReadingRulerEnabled
        self.ocrPageProvider = ocrPageProvider
        self.onActivate = onActivate
        self.onPositionChanged = onPositionChanged
        self.onSelectionChanged = onSelectionChanged
        self.onSelectionCaptured = onSelectionCaptured
        self.onQuickHighlight = onQuickHighlight
        self.onSendToNotebook = onSendToNotebook
        self.onCopyWithCitation = onCopyWithCitation
        self.onScrollNormalized = onScrollNormalized
        self.onJumpToPage = onJumpToPage
        self.onGoBack = onGoBack
        self.onGoForward = onGoForward
        self.onZoom = onZoom
        self.onFootnoteJumpToPage = onFootnoteJumpToPage
        self.onFootnoteOpenInSplit = onFootnoteOpenInSplit
        self.onFootnotePin = onFootnotePin
        self.onToggleBookmark = onToggleBookmark
        self.onCloseSecondary = onCloseSecondary
        self.onSnapshotCaptured = onSnapshotCaptured
        self.onCancelSnapshotMode = onCancelSnapshotMode
        self.onHighlightClicked = onHighlightClicked
    }

    private var shouldShowHeader: Bool {
        isHeaderHovered || isPageFieldFocused
    }

    public var body: some View {
        ZStack(alignment: .top) {
            PDFKitRepresentable(
                pane: pane,
                side: side,
                theme: theme,
                isSyncScrollEnabled: isSyncScrollEnabled,
                syncScrollSignal: syncScrollSignal,
                footnoteResolver: footnoteResolver,
                annotations: annotations,
                layoutRefreshToken: layoutRefreshToken,
                isTwoUpBookMode: isTwoUpBookMode,
                isSnapshotMode: isSnapshotMode,
                ocrPageProvider: ocrPageProvider,
                onActivate: onActivate,
                onPositionChanged: onPositionChanged,
                onSelectionChanged: onSelectionChanged,
                onSelectionCaptured: onSelectionCaptured,
                onQuickHighlight: onQuickHighlight,
                onSendToNotebook: onSendToNotebook,
                onCopyWithCitation: onCopyWithCitation,
                onScrollNormalized: onScrollNormalized,
                onFootnoteJumpToPage: onFootnoteJumpToPage,
                onFootnoteOpenInSplit: onFootnoteOpenInSplit,
                onFootnotePin: onFootnotePin,
                onSnapshotCaptured: onSnapshotCaptured,
                onCancelSnapshotMode: onCancelSnapshotMode,
                onHighlightClicked: onHighlightClicked
            )

            if isReadingRulerEnabled && !isSnapshotMode {
                ReadingRulerOverlay(theme: theme)
                    .allowsHitTesting(false)
            }

            if isSnapshotMode {
                HStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accentColor)
                    Text("Bölge Kırpma (Snapshot) — Kırpmak için PDF üzerinde sürükleyin")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.primaryInk)
                    Button("İptal (Esc)") {
                        onCancelSnapshotMode()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(theme.cardBackground.opacity(0.97), in: Capsule())
                .overlay(Capsule().stroke(theme.accentColor.opacity(0.45), lineWidth: 1))
                .shadow(color: theme.cardShadowColor, radius: 10, y: 3)
                .padding(.top, 10)
            }

            // Slim 18pt top hover sensor so the first PDF text line stays unobstructed until hovered near top edge
            VStack(spacing: 0) {
                paneHeader
                    .opacity(shouldShowHeader ? 1.0 : 0.0)
                    .offset(y: shouldShowHeader ? 0 : -6)
                    .allowsHitTesting(shouldShowHeader)
                    .animation(.easeOut(duration: 0.16), value: shouldShowHeader)
            }
            .frame(maxWidth: .infinity, minHeight: shouldShowHeader ? 36 : 18, alignment: .top)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHeaderHovered = hovering
            }
        }
        .overlay(alignment: .top) {
            if isSplit && isActive {
                Rectangle()
                    .fill(theme.accentColor.opacity(0.7))
                    .frame(height: 2)
            }
        }
        .overlay(alignment: side == .primary ? .trailing : .leading) {
            if isSplit {
                Rectangle()
                    .fill(theme.subtleBorder)
                    .frame(width: 1)
            }
        }
        .onAppear {
            pageInput = "\(pane.currentPageIndex + 1)"
        }
        .onChange(of: pane.currentPageIndex) { _, newValue in
            if !isPageFieldFocused {
                pageInput = "\(newValue + 1)"
            }
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? theme.accentColor : theme.secondaryInk.opacity(0.35))
                .frame(width: 7, height: 7)

            Text(pane.metadata.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.primaryInk)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            HStack(spacing: 3) {
                Button {
                    onGoBack()
                } label: {
                    Image(systemName: "chevron.backward.circle")
                        .foregroundStyle(pane.canGoBack ? theme.primaryInk : theme.secondaryInk.opacity(0.45))
                }
                .buttonStyle(.borderless)
                .disabled(!pane.canGoBack)
                .help("Önceki Konuma Dön (⌘[)")

                Button {
                    onGoForward()
                } label: {
                    Image(systemName: "chevron.forward.circle")
                        .foregroundStyle(pane.canGoForward ? theme.primaryInk : theme.secondaryInk.opacity(0.45))
                }
                .buttonStyle(.borderless)
                .disabled(!pane.canGoForward)
                .help("Sonraki Konuma İleri Git (⌘])")
            }

            Rectangle()
                .fill(theme.subtleBorder)
                .frame(width: 1, height: 14)

            HStack(spacing: 4) {
                Button {
                    onJumpToPage(pane.currentPageIndex - 1)
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(pane.currentPageIndex > 0 ? theme.primaryInk : theme.secondaryInk.opacity(0.45))
                }
                .buttonStyle(.borderless)
                .disabled(pane.currentPageIndex <= 0)

                TextField("", text: $pageInput)
                    .textFieldStyle(.plain)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.primaryInk)
                    .multilineTextAlignment(.center)
                    .frame(width: 44)
                    .padding(.vertical, 2.5)
                    .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.subtleBorder, lineWidth: 1)
                    )
                    .focused($isPageFieldFocused)
                    .onSubmit {
                        let maxPage = max(1, pane.metadata.pageCount)
                        if let pageNumber = Int(pageInput.trimmingCharacters(in: .whitespaces)),
                           pageNumber >= 1, pageNumber <= maxPage {
                            onJumpToPage(pageNumber - 1)
                            pageInput = "\(pageNumber)"
                        } else if let pageNumber = Int(pageInput.trimmingCharacters(in: .whitespaces)) {
                            let clamped = max(1, min(maxPage, pageNumber))
                            onJumpToPage(clamped - 1)
                            pageInput = "\(clamped)"
                        } else {
                            pageInput = "\(pane.currentPageIndex + 1)"
                        }
                    }

                Text("/ \(pane.metadata.pageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryInk)

                Button {
                    onJumpToPage(pane.currentPageIndex + 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(pane.currentPageIndex < pane.metadata.pageCount - 1 ? theme.primaryInk : theme.secondaryInk.opacity(0.45))
                }
                .buttonStyle(.borderless)
                .disabled(pane.currentPageIndex >= pane.metadata.pageCount - 1)

                Button {
                    onToggleBookmark()
                } label: {
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(isBookmarked ? theme.accentColor : theme.secondaryInk)
                }
                .buttonStyle(.borderless)
                .help(isBookmarked ? "Yer İmini Kaldır (⌘D)" : "Bu Sayfaya Yer İmi Ekle (⌘D)")
            }

            Rectangle()
                .fill(theme.subtleBorder)
                .frame(width: 1, height: 14)

            HStack(spacing: 4) {
                Button {
                    onZoom(.zoomOut)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .foregroundStyle(theme.primaryInk)
                }
                .buttonStyle(.borderless)
                .help("Uzaklaştır")

                Text("\(Int(round(pane.scaleFactor * 100)))%")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(theme.primaryInk)
                    .frame(width: 42)
                    .padding(.vertical, 2.5)
                    .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.subtleBorder, lineWidth: 1)
                    )

                Button {
                    onZoom(.zoomIn)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .foregroundStyle(theme.primaryInk)
                }
                .buttonStyle(.borderless)
                .help("Yakınlaştır")

                Button {
                    onZoom(.fitWidth)
                } label: {
                    Image(systemName: "arrow.left.and.right.square")
                        .foregroundStyle(theme.primaryInk)
                }
                .buttonStyle(.borderless)
                .help("Genişliğe Sığdır")
            }

            if side == .secondary, let onCloseSecondary {
                Rectangle()
                    .fill(theme.subtleBorder)
                    .frame(width: 1, height: 14)
                Button {
                    onCloseSecondary()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
                .buttonStyle(.borderless)
                .help("İkinci Paneli Kapat")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.chromeBackground.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.subtleBorder)
                .frame(height: 1)
        }
    }
}

// MARK: - Focus Reading Ruler (Follows Mouse Vertically Without Blocking Hits)

private struct ReadingRulerOverlay: View {
    let theme: ReadingTheme

    @State private var rulerY: CGFloat = 220
    @State private var isMouseInside: Bool = false
    @State private var moveMonitor: Any?

    private let bandHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if isMouseInside {
                    let clampedY = max(bandHeight / 2, min(geo.size.height - bandHeight / 2, rulerY))
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(bandFillColor)
                            .frame(height: bandHeight)
                        Rectangle()
                            .fill(guideLineColor)
                            .frame(height: 1.2)
                    }
                    .offset(y: clampedY - bandHeight / 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                installMonitor(paneHeight: geo.size.height)
            }
            .onDisappear {
                if let m = moveMonitor {
                    NSEvent.removeMonitor(m)
                    moveMonitor = nil
                }
            }
        }
    }

    private var bandFillColor: Color {
        switch theme {
        case .original: return Color.accentColor.opacity(0.065)
        case .sepia: return Color(red: 0.72, green: 0.55, blue: 0.28).opacity(0.11)
        case .softDark: return Color.white.opacity(0.06)
        }
    }

    private var guideLineColor: Color {
        switch theme {
        case .original: return Color.accentColor.opacity(0.35)
        case .sepia: return Color(red: 0.65, green: 0.48, blue: 0.22).opacity(0.45)
        case .softDark: return Color.accentColor.opacity(0.45)
        }
    }

    private func installMonitor(paneHeight: CGFloat) {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            guard let window = event.window, let contentView = window.contentView else { return event }
            let loc = event.locationInWindow
            let contentHeight = contentView.bounds.height
            let flippedY = contentHeight - loc.y
            // Account for toolbar/tab bar offset roughly (keep ruler centered under pointer)
            if loc.x >= 0 && loc.x <= contentView.bounds.width && flippedY >= 0 && flippedY <= contentHeight {
                isMouseInside = true
                rulerY = max(0, flippedY - 34)
            } else {
                isMouseInside = false
            }
            return event
        }
    }
}
#endif
