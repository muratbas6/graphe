#if os(macOS)
import AppKit
import PDFKit
import SwiftUI

public final class ThemeBlendOverlayView: NSView {
    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    public func apply(theme: ReadingTheme) {
        wantsLayer = true
        guard let layer else { return }

        switch theme {
        case .original:
            isHidden = true
            layer.compositingFilter = nil
            layer.backgroundColor = nil
        case .sepia:
            isHidden = false
            layer.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.91, blue: 0.81, alpha: 1.0).cgColor
            layer.compositingFilter = "multiplyBlendMode"
        case .softDark:
            isHidden = false
            layer.backgroundColor = NSColor(calibratedRed: 0.89, green: 0.88, blue: 0.86, alpha: 1.0).cgColor
            layer.compositingFilter = "differenceBlendMode"
        }
    }
}

public final class GraphePDFContainerView: NSView {
    public let pdfView = GraphePDFView()
    public let overlayView = ThemeBlendOverlayView()
    private var floatingBarHost: NSHostingView<FloatingSelectionBarView>?
    private var lastBoundsSize: NSSize = .zero

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)
        addSubview(overlayView)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layout() {
        super.layout()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            hideFloatingSelectionBar()
        }
    }

    public func showFloatingSelectionBar(
        near selectionRectInPDFView: NSRect,
        capture: SelectionCapture,
        theme: ReadingTheme = .original,
        onHighlight: @escaping (HighlightColor) -> Void,
        onLookup: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onCopyCitation: @escaping () -> Void
    ) {
        hideFloatingSelectionBar()

        let barView = FloatingSelectionBarView(
            theme: theme,
            onHighlight: { [weak self] color in
                self?.hideFloatingSelectionBar()
                onHighlight(color)
            },
            onLookup: { [weak self] in
                self?.hideFloatingSelectionBar()
                onLookup()
            },
            onCopy: { [weak self] in
                self?.hideFloatingSelectionBar()
                onCopy()
            },
            onCopyCitation: { [weak self] in
                self?.hideFloatingSelectionBar()
                onCopyCitation()
            }
        )
        let host = NSHostingView(rootView: barView)
        let fitting = host.fittingSize
        let barW = max(240, fitting.width)
        let barH = max(34, fitting.height)

        let converted = convert(selectionRectInPDFView, from: pdfView)
        let margin: CGFloat = 10
        var originX = converted.midX - barW / 2
        originX = max(margin, min(bounds.width - barW - margin, originX))

        // Prefer above selection (AppKit Y grows upward)
        var originY = converted.maxY + 8
        if originY + barH > bounds.height - margin {
            originY = max(margin, converted.minY - barH - 8)
        }

        host.frame = NSRect(x: originX, y: originY, width: barW, height: barH)
        addSubview(host)
        floatingBarHost = host
    }

    public var hasFloatingSelectionBar: Bool {
        floatingBarHost != nil
    }

    public func hideFloatingSelectionBar() {
        floatingBarHost?.removeFromSuperview()
        floatingBarHost = nil
    }
}

private struct FloatingSelectionBarView: View {
    let theme: ReadingTheme
    let onHighlight: (HighlightColor) -> Void
    let onLookup: () -> Void
    let onCopy: () -> Void
    let onCopyCitation: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(HighlightColor.allCases) { color in
                    Button {
                        onHighlight(color)
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .stroke(Color.black.opacity(0.18), lineWidth: 0.75)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(color.fullLabel) (Vurgula ve Deftere Ekle)")
                }
            }

            Rectangle()
                .fill(theme.subtleBorder)
                .frame(width: 1, height: 16)

            Button {
                onLookup()
            } label: {
                Image(systemName: "book.closed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryInk)
            }
            .buttonStyle(.plain)
            .help("Sözlükte Ara")

            Button {
                onCopyCitation()
            } label: {
                Image(systemName: "text.quote")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryInk)
            }
            .buttonStyle(.plain)
            .help("Atıfla Kopyala (Chicago)")

            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryInk)
            }
            .buttonStyle(.plain)
            .help("Kopyala")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.chromeBackground.opacity(0.96), in: Capsule())
        .overlay(
            Capsule()
                .stroke(theme.subtleBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
    }
}

public final class GraphePDFView: PDFView {
    public var documentTitle: String = ""
    public var documentHash: String = ""
    public var onMouseDown: (() -> Void)?
    public var onOptionClickWord: ((String) -> Void)?
    public var onShowFootnotePopover: ((FootnotePreview, NSPoint) -> Void)?
    public var onQuickHighlight: ((SelectionCapture, HighlightColor, Bool) -> Void)?
    public var onSendToNotebook: ((SelectionCapture) -> Void)?
    public var onCopyWithCitation: ((SelectionCapture) -> Void)?
    public var onLookupSelection: ((String) -> Void)?
    public var ocrPageProvider: ((Int) -> OCRPageResult?)?
    public var isSnapshotMode: Bool = false {
        didSet {
            if !isSnapshotMode {
                clearSnapshotOverlay()
            } else {
                clearSelection()
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    public var onSnapshotCaptured: ((NSImage) -> Void)?
    public var onCancelSnapshotMode: (() -> Void)?
    public var pageAnnotationsProvider: ((Int) -> [AnnotationItem])?
    public var onHighlightClicked: ((AnnotationItem) -> Void)?

    private var snapshotStartPoint: NSPoint?
    private var snapshotOverlayView: NSView?
    private var lastMouseDownPoint: NSPoint?

    public var footnoteResolver = FootnoteResolver()

    public override func setCursorFor(_ area: PDFAreaOfInterest) {
        if isSnapshotMode {
            NSCursor.crosshair.set()
            return
        }
        if area.contains(.linkArea) {
            NSCursor.pointingHand.set()
        } else if area.contains(.textArea) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    public func captureCurrentSelection() -> SelectionCapture? {
        guard let selection = currentSelection,
              let rawText = selection.string,
              let doc = document,
              let firstPage = selection.pages.first else {
            return nil
        }
        let cleaned = PDFTextNormalizer.normalize(rawText)
        guard !cleaned.isEmpty else { return nil }
        let pageIndex = doc.index(for: firstPage)
        guard pageIndex != NSNotFound else { return nil }

        let lineSelections = selection.selectionsByLine()
        var rects: [HighlightRect] = []
        for lineSel in lineSelections {
            if lineSel.pages.contains(firstPage) {
                let b = lineSel.bounds(for: firstPage)
                if b.origin.x.isFinite && b.origin.y.isFinite &&
                   b.width.isFinite && b.height.isFinite &&
                   !b.isNull && !b.isEmpty &&
                   b.width > 0.5 && b.height > 0.5 {
                    rects.append(HighlightRect(cgRect: b))
                }
            }
        }
        if rects.isEmpty {
            let b = selection.bounds(for: firstPage)
            if b.origin.x.isFinite && b.origin.y.isFinite &&
               b.width.isFinite && b.height.isFinite &&
               !b.isNull && !b.isEmpty &&
               b.width > 0.5 && b.height > 0.5 {
                rects.append(HighlightRect(cgRect: b))
            }
        }
        return SelectionCapture(pageIndex: pageIndex, text: cleaned, rects: rects)
    }

    /// Captures highlight rectangles across every page spanned by a multi-page selection
    /// while preserving the primary full-quote `SelectionCapture` on the first page.
    public func capturePerPageSelections() -> [SelectionCapture] {
        guard let selection = currentSelection,
              let rawText = selection.string,
              let doc = document,
              !selection.pages.isEmpty else {
            return []
        }
        let fullCleaned = PDFTextNormalizer.normalize(rawText)
        guard !fullCleaned.isEmpty else { return [] }

        let lineSelections = selection.selectionsByLine()
        var results: [SelectionCapture] = []

        for (idx, page) in selection.pages.enumerated() {
            let pageIndex = doc.index(for: page)
            guard pageIndex != NSNotFound else { continue }
            var rects: [HighlightRect] = []
            var pageLines: [String] = []

            for lineSel in lineSelections where lineSel.pages.contains(page) {
                let b = lineSel.bounds(for: page)
                if b.origin.x.isFinite && b.origin.y.isFinite &&
                   b.width.isFinite && b.height.isFinite &&
                   !b.isNull && !b.isEmpty &&
                   b.width > 0.5 && b.height > 0.5 {
                    rects.append(HighlightRect(cgRect: b))
                    if let s = lineSel.string {
                        pageLines.append(s)
                    }
                }
            }
            if rects.isEmpty {
                let b = selection.bounds(for: page)
                if b.origin.x.isFinite && b.origin.y.isFinite &&
                   b.width.isFinite && b.height.isFinite &&
                   !b.isNull && !b.isEmpty &&
                   b.width > 0.5 && b.height > 0.5 {
                    rects.append(HighlightRect(cgRect: b))
                }
            }
            guard !rects.isEmpty else { continue }

            let textForPage: String
            if idx == 0 {
                textForPage = fullCleaned
            } else {
                let joined = PDFTextNormalizer.normalize(pageLines.joined(separator: "\n"))
                textForPage = joined.isEmpty ? fullCleaned : joined
            }
            results.append(SelectionCapture(pageIndex: pageIndex, text: textForPage, rects: rects))
        }
        return results
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event) ?? NSMenu()
        guard let capture = captureCurrentSelection() else {
            return baseMenu
        }

        let highlightMenu = NSMenu(title: "Vurgula")
        for color in HighlightColor.allCases {
            let item = NSMenuItem(
                title: "\(color.fullLabel) (⌥\(color.shortcutDigit))",
                action: #selector(handleContextHighlight(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ContextHighlightPayload(capture: capture, color: color, openNotes: false)
            highlightMenu.addItem(item)
        }

        let highlightSubmenuItem = NSMenuItem(title: "Vurgula", action: nil, keyEquivalent: "")
        highlightSubmenuItem.submenu = highlightMenu

        let highlightWithNoteItem = NSMenuItem(
            title: "Vurgula ve Not Ekle...",
            action: #selector(handleContextHighlight(_:)),
            keyEquivalent: ""
        )
        highlightWithNoteItem.target = self
        highlightWithNoteItem.representedObject = ContextHighlightPayload(
            capture: capture,
            color: .yellow,
            openNotes: true
        )

        let sendToNotebookItem = NSMenuItem(
            title: "OneNote Defterine Gönder",
            action: #selector(handleContextSendToNotebook(_:)),
            keyEquivalent: ""
        )
        sendToNotebookItem.target = self
        sendToNotebookItem.representedObject = ContextHighlightPayload(
            capture: capture,
            color: .yellow,
            openNotes: true
        )

        let copyCitationItem = NSMenuItem(
            title: "Atıfla Kopyala (Chicago)",
            action: #selector(handleContextCopyWithCitation(_:)),
            keyEquivalent: ""
        )
        copyCitationItem.target = self
        copyCitationItem.representedObject = ContextHighlightPayload(
            capture: capture,
            color: .yellow,
            openNotes: false
        )

        let lookupItem = NSMenuItem(
            title: "Sözlükte Ara",
            action: #selector(handleContextLookup(_:)),
            keyEquivalent: ""
        )
        lookupItem.target = self
        lookupItem.representedObject = capture.text

        baseMenu.insertItem(.separator(), at: 0)
        baseMenu.insertItem(lookupItem, at: 0)
        baseMenu.insertItem(copyCitationItem, at: 0)
        baseMenu.insertItem(sendToNotebookItem, at: 0)
        baseMenu.insertItem(highlightWithNoteItem, at: 0)
        baseMenu.insertItem(highlightSubmenuItem, at: 0)

        return baseMenu
    }

    @objc private func handleContextHighlight(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ContextHighlightPayload else { return }
        let perPage = capturePerPageSelections()
        if perPage.count > 1 {
            for (idx, pageCapture) in perPage.enumerated() {
                onQuickHighlight?(pageCapture, payload.color, idx == 0 ? payload.openNotes : false)
            }
        } else {
            onQuickHighlight?(payload.capture, payload.color, payload.openNotes)
        }
        clearSelection()
    }

    @objc private func handleContextSendToNotebook(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ContextHighlightPayload else { return }
        onSendToNotebook?(payload.capture)
        clearSelection()
    }

    @objc private func handleContextCopyWithCitation(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ContextHighlightPayload else { return }
        onCopyWithCitation?(payload.capture)
        clearSelection()
    }

    @objc private func handleContextLookup(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        onLookupSelection?(text)
    }

    public override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        lastMouseDownPoint = convert(event.locationInWindow, from: nil)

        if isSnapshotMode {
            window?.makeFirstResponder(self)
            let start = convert(event.locationInWindow, from: nil)
            snapshotStartPoint = start
            updateSnapshotOverlay(from: start, to: start)
            return
        }

        if event.modifierFlags.contains(.option) {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if let page = page(for: viewPoint, nearest: true) {
                let pagePoint = convert(viewPoint, to: page)
                if let wordSelection = page.selectionForWord(at: pagePoint),
                   let rawWord = wordSelection.string {
                    let cleaned = PDFTextNormalizer.normalize(rawWord)
                    if !cleaned.isEmpty {
                        setCurrentSelection(wordSelection, animate: true)
                        onOptionClickWord?(cleaned)
                        return
                    }
                }
            }
        }

        super.mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        if isSnapshotMode, let start = snapshotStartPoint {
            let current = convert(event.locationInWindow, from: nil)
            updateSnapshotOverlay(from: start, to: current)
            return
        }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if isSnapshotMode, let start = snapshotStartPoint {
            let end = convert(event.locationInWindow, from: nil)
            let selectionRect = NSRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            clearSnapshotOverlay()
            if selectionRect.width >= 8, selectionRect.height >= 8,
               let image = renderSnapshotImage(forViewRect: selectionRect) {
                onSnapshotCaptured?(image)
            }
            return
        }
        super.mouseUp(with: event)

        let activeMods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if !isSnapshotMode,
           event.clickCount == 1,
           activeMods.isEmpty,
           (currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let downPt = lastMouseDownPoint {
            let upPt = convert(event.locationInWindow, from: nil)
            let dist = hypot(upPt.x - downPt.x, upPt.y - downPt.y)
            if dist <= 3.5,
               let page = page(for: upPt, nearest: false),
               let doc = document {
                let pagePt = convert(upPt, to: page)
                let docHashOpt = documentHash.isEmpty ? nil : documentHash

                // 1) Genuine stationary click on internal PDF footnote link or inline marker
                let directLink = page.annotation(at: pagePt)
                let fuzzyLink = page.annotations.first { ann in
                    ann.bounds.insetBy(dx: -1.5, dy: -1.5).contains(pagePt) &&
                    ann.bounds.width < page.bounds(for: .mediaBox).width * 0.35 &&
                    (ann.destination != nil || ann.action is PDFActionGoTo)
                }
                if let linkAnnotation = directLink ?? fuzzyLink,
                   (linkAnnotation.destination != nil || linkAnnotation.action is PDFActionGoTo),
                   let preview = footnoteResolver.resolveLinkAnnotation(
                       linkAnnotation,
                       on: page,
                       in: doc,
                       documentTitle: documentTitle,
                       documentHash: docHashOpt
                   ) {
                    onShowFootnotePopover?(preview, upPt)
                    return
                }

                let pageIndex = doc.index(for: page)
                let ocrPage = pageIndex != NSNotFound ? ocrPageProvider?(pageIndex) : nil
                if let preview = footnoteResolver.resolveMarkerClick(
                    at: pagePt,
                    on: page,
                    in: doc,
                    documentTitle: documentTitle,
                    documentHash: docHashOpt,
                    ocrPage: ocrPage
                ) {
                    onShowFootnotePopover?(preview, upPt)
                    return
                }

                // 2) Two-way PDF -> OneNote link: single click on an existing highlight
                if pageIndex != NSNotFound,
                   let pageAnnotations = pageAnnotationsProvider?(pageIndex),
                   !pageAnnotations.isEmpty {
                    if let hit = pageAnnotations.first(where: { item in
                        item.kind == .highlight && item.rects.contains(where: { $0.cgRect.insetBy(dx: -2, dy: -2).contains(pagePt) })
                    }) {
                        onHighlightClicked?(hit)
                    }
                }
            }
        }
    }

    public override func keyDown(with event: NSEvent) {
        if isSnapshotMode && event.keyCode == 53 { // Escape
            clearSnapshotOverlay()
            onCancelSnapshotMode?()
            return
        }

        // Smooth keyboard reading navigation (J / K / Space / Shift+Space) when PDFView is first responder
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods.isEmpty {
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == "j" {
                scrollReadingOffset(by: 84)
                return
            } else if chars == "k" {
                scrollReadingOffset(by: -84)
                return
            } else if chars == " " {
                let pageStep = max(240, bounds.height * 0.82)
                let delta = event.modifierFlags.contains(.shift) ? -pageStep : pageStep
                scrollReadingOffset(by: delta)
                return
            }
        }
        super.keyDown(with: event)
    }

    private func scrollReadingOffset(by deltaY: CGFloat) {
        guard let scrollView = subviews.compactMap({ $0 as? NSScrollView }).first ?? enclosingScrollView,
              let docView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let currentOrigin = clipView.bounds.origin
        let isFlipped = docView.isFlipped
        let maxY = max(0, docView.bounds.height - clipView.bounds.height)
        let targetY: CGFloat
        if isFlipped {
            targetY = max(0, min(maxY, currentOrigin.y + deltaY))
        } else {
            targetY = max(0, min(maxY, currentOrigin.y - deltaY))
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clipView.animator().setBoundsOrigin(NSPoint(x: currentOrigin.x, y: targetY))
        }
        scrollView.reflectScrolledClipView(clipView)
    }

    private func updateSnapshotOverlay(from start: NSPoint, to current: NSPoint) {
        let rect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        let overlay: NSView
        if let existing = snapshotOverlayView {
            overlay = existing
        } else {
            let v = NSView(frame: rect)
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.90).cgColor
            v.layer?.borderWidth = 1.5
            v.layer?.cornerRadius = 3
            addSubview(v)
            snapshotOverlayView = v
            overlay = v
        }
        overlay.frame = rect
    }

    private func clearSnapshotOverlay() {
        snapshotStartPoint = nil
        snapshotOverlayView?.removeFromSuperview()
        snapshotOverlayView = nil
    }

    private func renderSnapshotImage(forViewRect viewRect: NSRect) -> NSImage? {
        let center = NSPoint(x: viewRect.midX, y: viewRect.midY)
        guard let page = page(for: center, nearest: true) else { return nil }

        let rawPageRect = convert(viewRect, to: page).standardized
        let cropBox = page.bounds(for: .cropBox)
        let clampedPageRect = rawPageRect.intersection(cropBox)
        guard !clampedPageRect.isNull, clampedPageRect.width >= 4, clampedPageRect.height >= 4 else {
            return nil
        }

        // `page.draw(with: .cropBox, to: ctx)` internally applies `page.transform(for: .cropBox)`,
        // mapping cropBox.origin to (0, 0) and applying page.rotation.
        // Map clampedPageRect into that exact drawn coordinate space so Auto-Crop offsets and rotations match 1:1.
        let drawTransform = page.transform(for: .cropBox)
        let drawnRect = clampedPageRect.applying(drawTransform).standardized
        guard drawnRect.width >= 4, drawnRect.height >= 4 else { return nil }

        let scale: CGFloat = 3.0
        let pixelW = max(16, Int(ceil(drawnRect.width * scale)))
        let pixelH = max(16, Int(ceil(drawnRect.height * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -drawnRect.origin.x, y: -drawnRect.origin.y)
        page.draw(with: .cropBox, to: ctx)

        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: drawnRect.width, height: drawnRect.height))
    }

    public override func copy(_ sender: Any?) {
        if let raw = currentSelection?.string {
            let cleaned = PDFTextNormalizer.normalize(raw)
            if !cleaned.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(cleaned, forType: .string)
                return
            }
        }
        super.copy(sender)
    }
}

private final class ContextHighlightPayload: NSObject {
    let capture: SelectionCapture
    let color: HighlightColor
    let openNotes: Bool

    init(capture: SelectionCapture, color: HighlightColor, openNotes: Bool) {
        self.capture = capture
        self.color = color
        self.openNotes = openNotes
    }
}

public struct PDFKitRepresentable: NSViewRepresentable {
    public let pane: ReaderPaneState
    public let side: PaneSide
    public let theme: ReadingTheme
    public let isSyncScrollEnabled: Bool
    public let syncScrollSignal: SyncScrollSignal?
    public let footnoteResolver: FootnoteResolver
    public let annotations: [AnnotationItem]
    public let layoutRefreshToken: UUID
    public let isTwoUpBookMode: Bool
    public let isSnapshotMode: Bool
    public let ocrPageProvider: (Int) -> OCRPageResult?
    public let onActivate: () -> Void
    public let onPositionChanged: (Int, Double) -> Void
    public let onSelectionChanged: (String) -> Void
    public let onSelectionCaptured: (SelectionCapture?) -> Void
    public let onQuickHighlight: (SelectionCapture, HighlightColor, Bool) -> Void
    public let onSendToNotebook: (SelectionCapture) -> Void
    public let onCopyWithCitation: (SelectionCapture) -> Void
    public let onScrollNormalized: (Double) -> Void
    public let onFootnoteJumpToPage: (Int) -> Void
    public let onFootnoteOpenInSplit: (Int) -> Void
    public let onFootnotePin: (FootnotePreview) -> Void
    public let onSnapshotCaptured: (NSImage) -> Void
    public let onCancelSnapshotMode: () -> Void
    public let onHighlightClicked: (AnnotationItem) -> Void

    public init(
        pane: ReaderPaneState,
        side: PaneSide,
        theme: ReadingTheme,
        isSyncScrollEnabled: Bool = false,
        syncScrollSignal: SyncScrollSignal?,
        footnoteResolver: FootnoteResolver = FootnoteResolver(),
        annotations: [AnnotationItem] = [],
        layoutRefreshToken: UUID = UUID(),
        isTwoUpBookMode: Bool = false,
        isSnapshotMode: Bool = false,
        ocrPageProvider: @escaping (Int) -> OCRPageResult? = { _ in nil },
        onActivate: @escaping () -> Void,
        onPositionChanged: @escaping (Int, Double) -> Void,
        onSelectionChanged: @escaping (String) -> Void,
        onSelectionCaptured: @escaping (SelectionCapture?) -> Void = { _ in },
        onQuickHighlight: @escaping (SelectionCapture, HighlightColor, Bool) -> Void = { _, _, _ in },
        onSendToNotebook: @escaping (SelectionCapture) -> Void = { _ in },
        onCopyWithCitation: @escaping (SelectionCapture) -> Void = { _ in },
        onScrollNormalized: @escaping (Double) -> Void,
        onFootnoteJumpToPage: @escaping (Int) -> Void,
        onFootnoteOpenInSplit: @escaping (Int) -> Void,
        onFootnotePin: @escaping (FootnotePreview) -> Void,
        onSnapshotCaptured: @escaping (NSImage) -> Void = { _ in },
        onCancelSnapshotMode: @escaping () -> Void = {},
        onHighlightClicked: @escaping (AnnotationItem) -> Void = { _ in }
    ) {
        self.pane = pane
        self.side = side
        self.theme = theme
        self.isSyncScrollEnabled = isSyncScrollEnabled
        self.syncScrollSignal = syncScrollSignal
        self.footnoteResolver = footnoteResolver
        self.annotations = annotations
        self.layoutRefreshToken = layoutRefreshToken
        self.isTwoUpBookMode = isTwoUpBookMode
        self.isSnapshotMode = isSnapshotMode
        self.ocrPageProvider = ocrPageProvider
        self.onActivate = onActivate
        self.onPositionChanged = onPositionChanged
        self.onSelectionChanged = onSelectionChanged
        self.onSelectionCaptured = onSelectionCaptured
        self.onQuickHighlight = onQuickHighlight
        self.onSendToNotebook = onSendToNotebook
        self.onCopyWithCitation = onCopyWithCitation
        self.onScrollNormalized = onScrollNormalized
        self.onFootnoteJumpToPage = onFootnoteJumpToPage
        self.onFootnoteOpenInSplit = onFootnoteOpenInSplit
        self.onFootnotePin = onFootnotePin
        self.onSnapshotCaptured = onSnapshotCaptured
        self.onCancelSnapshotMode = onCancelSnapshotMode
        self.onHighlightClicked = onHighlightClicked
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> GraphePDFContainerView {
        let container = GraphePDFContainerView()
        let pdfView = container.pdfView
        pdfView.autoScales = false
        pdfView.displayMode = isTwoUpBookMode ? .twoUpContinuous : .singlePageContinuous
        pdfView.displaysAsBook = isTwoUpBookMode
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        pdfView.documentTitle = pane.metadata.title
        pdfView.documentHash = pane.documentHash
        pdfView.footnoteResolver = footnoteResolver
        if pdfView.isSnapshotMode != isSnapshotMode {
            pdfView.isSnapshotMode = isSnapshotMode
        }
        pdfView.onMouseDown = { [weak container] in
            container?.hideFloatingSelectionBar()
            context.coordinator.parent.onActivate()
        }
        pdfView.onOptionClickWord = { word in
            context.coordinator.parent.onSelectionChanged(word)
        }
        pdfView.onShowFootnotePopover = { preview, viewPoint in
            context.coordinator.presentFootnotePopover(preview, at: viewPoint, in: pdfView)
        }
        pdfView.onQuickHighlight = { capture, color, openNotes in
            context.coordinator.parent.onQuickHighlight(capture, color, openNotes)
        }
        pdfView.onSendToNotebook = { capture in
            context.coordinator.parent.onSendToNotebook(capture)
        }
        pdfView.onCopyWithCitation = { capture in
            context.coordinator.parent.onCopyWithCitation(capture)
        }
        pdfView.onLookupSelection = { text in
            context.coordinator.parent.onSelectionChanged(text)
        }
        pdfView.ocrPageProvider = { pageIndex in
            context.coordinator.parent.ocrPageProvider(pageIndex)
        }
        pdfView.isSnapshotMode = isSnapshotMode
        pdfView.onSnapshotCaptured = { image in
            context.coordinator.parent.onSnapshotCaptured(image)
        }
        pdfView.onCancelSnapshotMode = {
            context.coordinator.parent.onCancelSnapshotMode()
        }
        pdfView.pageAnnotationsProvider = { pageIndex in
            context.coordinator.parent.annotations.filter { $0.pageIndex == pageIndex }
        }
        pdfView.onHighlightClicked = { annotation in
            context.coordinator.parent.onHighlightClicked(annotation)
        }

        context.coordinator.containerView = container
        context.coordinator.attach(to: pdfView)
        configureDocument(on: pdfView, coordinator: context.coordinator)
        context.coordinator.syncHighlights(annotations, on: pdfView)
        context.coordinator.lastLayoutRefreshToken = layoutRefreshToken
        applyTheme(theme, to: container)
        context.coordinator.appliedTheme = theme
        return container
    }

    public func updateNSView(_ container: GraphePDFContainerView, context: Context) {
        context.coordinator.parent = self
        let pdfView = container.pdfView
        pdfView.documentTitle = pane.metadata.title
        pdfView.documentHash = pane.documentHash
        pdfView.footnoteResolver = footnoteResolver
        if pdfView.isSnapshotMode != isSnapshotMode {
            pdfView.isSnapshotMode = isSnapshotMode
        }

        if context.coordinator.loadedPaneID != pane.id {
            configureDocument(on: pdfView, coordinator: context.coordinator)
        }

        context.coordinator.syncHighlights(annotations, on: pdfView)

        if context.coordinator.lastLayoutRefreshToken != layoutRefreshToken {
            context.coordinator.lastLayoutRefreshToken = layoutRefreshToken
            pdfView.layoutDocumentView()
        }

        let targetDisplayMode: PDFDisplayMode = isTwoUpBookMode ? .twoUpContinuous : .singlePageContinuous
        if pdfView.displayMode != targetDisplayMode || pdfView.displaysAsBook != isTwoUpBookMode {
            container.hideFloatingSelectionBar()
            let currentPage = pdfView.currentPage
            pdfView.displayMode = targetDisplayMode
            pdfView.displaysAsBook = isTwoUpBookMode
            pdfView.autoScales = true
            pdfView.layoutDocumentView()
            let targetPaneID = pane.id
            DispatchQueue.main.async {
                guard context.coordinator.loadedPaneID == targetPaneID else { return }
                let fitted = pdfView.scaleFactor
                pdfView.autoScales = false
                if fitted > 0.1 {
                    pdfView.scaleFactor = fitted
                }
                if let currentPage {
                    pdfView.go(to: currentPage)
                }
            }
        }

        if context.coordinator.appliedTheme != theme {
            applyTheme(theme, to: container)
            context.coordinator.appliedTheme = theme
        }

        if let jump = pane.targetPageRequest, context.coordinator.lastHandledJumpID != jump.id {
            context.coordinator.lastHandledJumpID = jump.id
            if let page = pdfView.document?.page(at: jump.pageIndex) {
                pdfView.go(to: page)
            }
        }

        if let zoom = pane.zoomRequest, context.coordinator.lastHandledZoomID != zoom.id {
            context.coordinator.lastHandledZoomID = zoom.id
            switch zoom.action {
            case .zoomIn:
                pdfView.zoomIn(nil)
            case .zoomOut:
                pdfView.zoomOut(nil)
            case .fitWidth:
                pdfView.autoScales = true
                let fitted = pdfView.scaleFactor
                pdfView.autoScales = false
                pdfView.scaleFactor = fitted
            case .actualSize:
                pdfView.scaleFactor = 1.0
            }
        }

        if let signal = syncScrollSignal,
           signal.sourceSide != side,
           context.coordinator.lastHandledSyncID != signal.id {
            context.coordinator.lastHandledSyncID = signal.id
            context.coordinator.applyExternalScroll(normalizedY: signal.normalizedY, on: pdfView)
        }

        if let searchHighlight = pane.searchHighlight,
           context.coordinator.lastHandledSearchID != searchHighlight.requestID {
            context.coordinator.lastHandledSearchID = searchHighlight.requestID
            pdfView.highlightedSelections = searchHighlight.allMatches
            if let activeMatch = searchHighlight.activeMatch {
                context.coordinator.suppressNextFloatingBar = true
                container.hideFloatingSelectionBar()
                pdfView.go(to: activeMatch)
                pdfView.setCurrentSelection(activeMatch, animate: true)
            } else if searchHighlight.allMatches.isEmpty {
                container.hideFloatingSelectionBar()
                pdfView.clearSelection()
            }
        }
    }

    private func configureDocument(on pdfView: GraphePDFView, coordinator: Coordinator) {
        coordinator.containerView?.hideFloatingSelectionBar()
        let targetPaneID = pane.id
        let targetDocument = pane.document
        let targetPageIndex = pane.currentPageIndex
        coordinator.loadedPaneID = targetPaneID
        pdfView.document = targetDocument

        if pane.shouldAutoFitWidth {
            pdfView.autoScales = true
            DispatchQueue.main.async {
                guard coordinator.loadedPaneID == targetPaneID else { return }
                let fitted = pdfView.scaleFactor
                pdfView.autoScales = false
                if fitted > 0.1 {
                    pdfView.scaleFactor = fitted
                }
                if let page = targetDocument.page(at: targetPageIndex) {
                    pdfView.go(to: page)
                }
            }
        } else {
            if pane.scaleFactor > 0.1 {
                pdfView.scaleFactor = CGFloat(pane.scaleFactor)
            } else {
                pdfView.autoScales = true
            }
            if let page = targetDocument.page(at: targetPageIndex) {
                DispatchQueue.main.async {
                    guard coordinator.loadedPaneID == targetPaneID else { return }
                    pdfView.go(to: page)
                }
            }
        }

        coordinator.observeScrollView(in: pdfView)
    }

    private func applyTheme(_ theme: ReadingTheme, to container: GraphePDFContainerView) {
        // Keep PDFView's backing layer free of CIFilters so Retina vector text stays
        // razor sharp; color themes are composited via GPU blend-mode overlay.
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.canvasBackgroundColor.cgColor
        switch theme {
        case .original:
            container.pdfView.backgroundColor = theme.canvasBackgroundColor
        case .sepia:
            // Multiplied by overlay (0.96, 0.91, 0.81) -> seamlessly matches ReadingTheme.sepia chrome/canvas
            container.pdfView.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1.0)
        case .softDark:
            // Differenced against overlay (0.89, 0.88, 0.86) -> seamlessly matches ReadingTheme.softDark chrome/canvas (~0.10, 0.11, 0.13)
            container.pdfView.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 1.0)
        }
        container.overlayView.apply(theme: theme)
    }

    @MainActor
    public final class Coordinator: NSObject {
        var parent: PDFKitRepresentable
        var loadedPaneID: UUID?
        var appliedTheme: ReadingTheme?
        var lastHandledJumpID: UUID?
        var lastHandledZoomID: UUID?
        var lastHandledSyncID: UUID?
        var lastHandledSearchID: UUID?
        var lastAnnotationsFingerprint: Int?
        var lastLayoutRefreshToken: UUID?
        private var highlightedPageIndices: Set<Int> = []
        private var highlightedDocumentID: ObjectIdentifier?

        private weak var pdfView: GraphePDFView?
        weak var containerView: GraphePDFContainerView?
        private weak var observedScrollView: NSScrollView?
        private weak var observedClipView: NSClipView?
        private var activePopover: NSPopover?
        private var isApplyingExternalScroll = false
        private var lastBroadcastScrollTime: TimeInterval = 0
        private var lastBroadcastNormalizedY: Double = -1
        var suppressNextFloatingBar = false
        nonisolated(unsafe) private var selectionDebounceWorkItem: DispatchWorkItem?
        nonisolated(unsafe) private var externalScrollResetWorkItem: DispatchWorkItem?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        private static let grapheHighlightUserName = "graphe.highlight"

        func syncHighlights(_ annotations: [AnnotationItem], on pdfView: GraphePDFView) {
            guard let doc = pdfView.document else { return }
            var hasher = Hasher()
            hasher.combine(ObjectIdentifier(doc))
            var highlightCount = 0
            for item in annotations where item.kind == .highlight && !item.rects.isEmpty {
                highlightCount += 1
                hasher.combine(item.id)
                hasher.combine(item.color)
                hasher.combine(item.rects)
            }
            let fingerprint = hasher.finalize()
            if lastAnnotationsFingerprint == fingerprint {
                return
            }
            lastAnnotationsFingerprint = fingerprint

            let highlightItems: [AnnotationItem] = highlightCount == 0
                ? []
                : annotations.filter { $0.kind == .highlight && !$0.rects.isEmpty }

            let docID = ObjectIdentifier(doc)
            if highlightedDocumentID != docID {
                highlightedPageIndices.removeAll()
                highlightedDocumentID = docID
            }

            let newPageIndices = Set(highlightItems.map(\.pageIndex))
            let pagesToClear = highlightedPageIndices.union(newPageIndices)

            // Only touch pages that had or now have highlights (O(k) instead of O(pageCount))
            for pageIdx in pagesToClear {
                guard let page = doc.page(at: pageIdx) else { continue }
                let existing = page.annotations.filter { $0.userName == Self.grapheHighlightUserName }
                for ann in existing {
                    page.removeAnnotation(ann)
                }
            }

            // Re-apply current SQLite highlights
            for item in highlightItems {
                guard let page = doc.page(at: item.pageIndex) else { continue }
                for rect in item.rects {
                    let ann = PDFAnnotation(bounds: rect.cgRect, forType: .highlight, withProperties: nil)
                    ann.color = item.color.pdfNSColor
                    ann.userName = Self.grapheHighlightUserName
                    ann.shouldPrint = false
                    page.addAnnotation(ann)
                }
            }
            highlightedPageIndices = newPageIndices
        }

        init(_ parent: PDFKitRepresentable) {
            self.parent = parent
        }

        deinit {
            selectionDebounceWorkItem?.cancel()
            externalScrollResetWorkItem?.cancel()
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func presentFootnotePopover(_ preview: FootnotePreview, at viewPoint: NSPoint, in pdfView: GraphePDFView) {
            activePopover?.close()

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true

            let content = FootnotePopoverView(
                preview: preview,
                theme: self.parent.theme,
                onLookupSelection: { [weak self] text in
                    self?.parent.onSelectionChanged(text)
                },
                onJumpToPage: { [weak self] in
                    self?.parent.onFootnoteJumpToPage(preview.targetPageIndex)
                },
                onOpenInSplit: { [weak self] in
                    self?.parent.onFootnoteOpenInSplit(preview.targetPageIndex)
                },
                onPin: { [weak self] in
                    self?.parent.onFootnotePin(preview)
                },
                onClose: { [weak popover] in
                    popover?.close()
                }
            )
            let hosting = NSHostingController(rootView: content)
            popover.contentViewController = hosting

            let anchorRect = NSRect(x: viewPoint.x - 4, y: viewPoint.y - 4, width: 8, height: 8)
            popover.show(relativeTo: anchorRect, of: pdfView, preferredEdge: .maxY)
            activePopover = popover
        }

        func attach(to pdfView: GraphePDFView) {
            self.pdfView = pdfView
            let center = NotificationCenter.default

            let pageObs = center.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reportPosition()
                }
            }

            let scaleObs = center.addObserver(
                forName: .PDFViewScaleChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.containerView?.hasFloatingSelectionBar == true {
                        self?.containerView?.hideFloatingSelectionBar()
                    }
                    self?.reportPosition()
                }
            }

            let selectionObs = center.addObserver(
                forName: .PDFViewSelectionChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleSelectionCapture()
                }
            }

            observers.append(contentsOf: [pageObs, scaleObs, selectionObs])
        }

        private func scheduleSelectionCapture() {
            selectionDebounceWorkItem?.cancel()
            selectionDebounceWorkItem = nil

            guard let pdfView else { return }
            if suppressNextFloatingBar {
                suppressNextFloatingBar = false
                containerView?.hideFloatingSelectionBar()
                return
            }

            let capture = pdfView.captureCurrentSelection()
            if capture == nil {
                // Clearing selection is immediate so highlight/lookup state resets right away
                containerView?.hideFloatingSelectionBar()
                parent.onSelectionCaptured(nil)
                return
            }

            // While dragging, hide any stale bar and wait for mouse release
            if NSEvent.pressedMouseButtons != 0 {
                containerView?.hideFloatingSelectionBar()
            }

            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let pdfView = self.pdfView else { return }
                    if NSEvent.pressedMouseButtons != 0 {
                        self.scheduleSelectionCapture()
                        return
                    }
                    let latest = pdfView.captureCurrentSelection()
                    self.parent.onSelectionCaptured(latest)
                    if let latest,
                       let sel = pdfView.currentSelection,
                       let firstPage = sel.pages.first {
                        let pageBounds = sel.bounds(for: firstPage)
                        let viewBounds = pdfView.convert(pageBounds, from: firstPage)
                        let perPageCaptures = pdfView.capturePerPageSelections()
                        self.containerView?.showFloatingSelectionBar(
                            near: viewBounds,
                            capture: latest,
                            theme: self.parent.theme,
                            onHighlight: { [weak self, weak pdfView] color in
                                if perPageCaptures.count > 1 {
                                    for (idx, pageCapture) in perPageCaptures.enumerated() {
                                        self?.parent.onQuickHighlight(pageCapture, color, idx == 0)
                                    }
                                } else {
                                    self?.parent.onQuickHighlight(latest, color, true)
                                }
                                pdfView?.clearSelection()
                            },
                            onLookup: { [weak self] in
                                self?.parent.onSelectionChanged(latest.text)
                            },
                            onCopy: { [weak pdfView] in
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(latest.text, forType: .string)
                                pdfView?.clearSelection()
                            },
                            onCopyCitation: { [weak self, weak pdfView] in
                                self?.parent.onCopyWithCitation(latest)
                                pdfView?.clearSelection()
                            }
                        )
                    } else {
                        self.containerView?.hideFloatingSelectionBar()
                    }
                }
            }
            selectionDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        }

        func observeScrollView(in pdfView: GraphePDFView) {
            guard let scrollView = findScrollView(in: pdfView) else { return }
            observedScrollView = scrollView
            let clipView = scrollView.contentView
            if observedClipView === clipView { return }
            observedClipView = clipView
            clipView.postsBoundsChangedNotifications = true

            let scrollObs = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleScrollBoundsChange()
                }
            }
            observers.append(scrollObs)
        }

        func applyExternalScroll(normalizedY: Double, on pdfView: GraphePDFView) {
            guard let scrollView = observedScrollView ?? findScrollView(in: pdfView),
                  let docView = scrollView.documentView else { return }
            observedScrollView = scrollView
            let maxY = max(0.0, docView.frame.height - scrollView.contentView.bounds.height)
            guard maxY > 0 else { return }

            externalScrollResetWorkItem?.cancel()
            isApplyingExternalScroll = true
            let targetY = CGFloat(normalizedY) * maxY
            var origin = scrollView.contentView.bounds.origin
            origin.y = targetY
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let resetWork = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isApplyingExternalScroll = false
                }
            }
            externalScrollResetWorkItem = resetWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: resetWork)
        }

        private func handleScrollBoundsChange() {
            if containerView?.hasFloatingSelectionBar == true {
                containerView?.hideFloatingSelectionBar()
            }
            guard parent.isSyncScrollEnabled,
                  !isApplyingExternalScroll,
                  let scrollView = observedScrollView,
                  let docView = scrollView.documentView else { return }
            let maxY = max(0.0, docView.frame.height - scrollView.contentView.bounds.height)
            guard maxY > 0 else { return }
            let normalized = Double(scrollView.contentView.bounds.origin.y / maxY)
            let now = CACurrentMediaTime()
            if now - lastBroadcastScrollTime < 0.016 && abs(normalized - lastBroadcastNormalizedY) < 0.01 {
                return
            }
            if abs(normalized - lastBroadcastNormalizedY) < 0.0005 {
                return
            }
            lastBroadcastScrollTime = now
            lastBroadcastNormalizedY = normalized
            parent.onScrollNormalized(normalized)
        }

        private func reportPosition() {
            guard let pdfView,
                  let doc = pdfView.document,
                  let currentPage = pdfView.currentPage else { return }
            let index = doc.index(for: currentPage)
            let scale = Double(pdfView.scaleFactor)
            parent.onPositionChanged(index, scale)
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews {
                if let found = findScrollView(in: sub) {
                    return found
                }
            }
            return nil
        }
    }
}
#endif
