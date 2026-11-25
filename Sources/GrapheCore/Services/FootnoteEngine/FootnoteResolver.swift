#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation
import PDFKit

public final class FootnoteResolver: @unchecked Sendable {
    private let lock = NSLock()
    private let visionOCR = VisionOCRService()
    private var pageFootnotesCache: [ObjectIdentifier: [Int: [PageFootnoteItem]]] = [:]
    private var notesSectionPagesCache: [ObjectIdentifier: [Int]] = [:]
    private var endnoteBlocksCache: [ObjectIdentifier: [Int: [PageFootnoteItem]]] = [:]
    private var cachedDocumentOrder: [ObjectIdentifier] = []
    private static let maxCachedDocuments = 24

    private static let bottomScanHeightRatio: CGFloat = 0.48

    private static let doubleAsteriskRegex = try! NSRegularExpression(
        pattern: #"^\*\s*\*\s*(.+)$"#
    )
    private static let bracedMarkerRegex = try! NSRegularExpression(
        pattern: #"^\{(\d{1,3}[a-d]?)\.?\}\s*(.+)$"#
    )
    private static let alphanumericPunctRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,3}[a-d])[\.\)\·•:]\s*(.+)$"#
    )
    private static let digitPunctRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,3})[\.\)\·•:]\s*(.+)$"#
    )
    private static let ocrIRegex = try! NSRegularExpression(
        pattern: #"^I[\.\·]\s+([A-ZÇĞİÖŞÜ"'\(\[«].+)$"#
    )
    private static let bareDigitRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,3})\s+([A-ZÇĞİÖŞÜ"'\(\[«].+)$"#
    )
    private static let gluedTrailingNumberRegex = try! NSRegularExpression(
        pattern: #"^(?:.*[A-Za-zÇĞİÖŞÜçğıöşü"'\)\]\.,;:!?])(\d{1,3}[a-d]?)$"#
    )
    private static let gluedTrailingSymbolRegex = try! NSRegularExpression(
        pattern: #"^(?:.*[A-Za-zÇĞİÖŞÜçğıöşü"'\)\]\.,;:!?])(\*\*|\*|†|‡)$"#
    )
    private static let standaloneAlphanumericRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,3})([a-d])?$"#
    )

    public init() {}

    // MARK: - 0. Caching & Background Prewarm

    /// Synchronously scans the document once for standalone NOTES / ENDNOTES heading pages.
    @discardableResult
    public func prewarmNotesIndex(for document: PDFDocument) -> [Int] {
        let key = ObjectIdentifier(document)
        if let cached = cachedNotesPages(for: key) {
            return cached
        }
        let pages = scanNotesSectionPages(in: document)
        storeNotesPages(pages, for: key)
        return pages
    }

    /// Populates the notes index for a document key using an already-opened background PDFDocument copy.
    public func prewarmNotesIndex(forDocumentKey key: ObjectIdentifier, usingBackgroundDocument bgDoc: PDFDocument) {
        if cachedNotesPages(for: key) != nil {
            return
        }
        let pages = scanNotesSectionPages(in: bgDoc)
        storeNotesPages(pages, for: key)
    }

    /// Asynchronously scans a separate PDFDocument copy off the main thread so PDFView is never blocked.
    public func prewarmNotesIndexAsync(for document: PDFDocument, url: URL) {
        let key = ObjectIdentifier(document)
        if cachedNotesPages(for: key) != nil {
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let bgDoc = PDFDocument(url: url) else { return }
            let pages = self.scanNotesSectionPages(in: bgDoc)
            self.storeNotesPages(pages, for: key)
        }
    }

    public func evictCache(for document: PDFDocument) {
        let key = ObjectIdentifier(document)
        lock.lock()
        pageFootnotesCache.removeValue(forKey: key)
        notesSectionPagesCache.removeValue(forKey: key)
        endnoteBlocksCache.removeValue(forKey: key)
        cachedDocumentOrder.removeAll { $0 == key }
        lock.unlock()
    }

    public func isNotesHeadingPageText(_ pageText: String) -> Bool {
        let lines = pageText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var inspectedNonEmpty = 0
        for rawLine in lines {
            let trimmed = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-–—•·:*[]()"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            inspectedNonEmpty += 1
            if inspectedNonEmpty > 12 { break }

            // Skip standalone page numbers
            if isStandalonePageNumber(trimmed) { continue }

            // Standalone heading lines are short; body prose ("Heidegger notes that...") is long or starts differently
            guard trimmed.count <= 45 else { continue }

            let lower = trimmed.lowercased()
            let exactHeadings: Set<String> = [
                "notes",
                "endnotes",
                "notlar",
                "sonnotlar",
                "son notlar",
                "anmerkungen",
                "notes and references",
                "reference notes",
                "bibliographical notes",
                "translator's notes",
                "translators' notes",
                "author's notes",
                "editor's notes",
                "chapter notes"
            ]
            if exactHeadings.contains(lower) {
                return true
            }

            let headingPrefixes = [
                "notes to ",
                "notes on ",
                "notes for ",
                "endnotes to ",
                "endnotes for ",
                "anmerkungen zu ",
                "notlar:"
            ]
            if headingPrefixes.contains(where: { lower.hasPrefix($0) }) {
                return true
            }
        }

        return false
    }

    // MARK: - 1. Internal PDF Link Resolution

    public func resolveLinkAnnotation(
        _ annotation: PDFAnnotation,
        on sourcePage: PDFPage,
        in document: PDFDocument,
        documentTitle: String,
        documentHash: String? = nil
    ) -> FootnotePreview? {
        let directDest = annotation.destination
        let actionDest = (annotation.action as? PDFActionGoTo)?.destination
        let destination: PDFDestination?
        if let directDest, directDest.page != nil {
            destination = directDest
        } else if let actionDest, actionDest.page != nil {
            destination = actionDest
        } else {
            destination = nil
        }
        guard let destination, let targetPage = destination.page else {
            return nil
        }

        let sourcePageIndex = document.index(for: sourcePage)
        let targetPageIndex = document.index(for: targetPage)
        guard targetPageIndex != NSNotFound else { return nil }

        let mediaBox = targetPage.bounds(for: .mediaBox)
        let cropRect = computeTargetCropRect(for: destination.point, on: mediaBox)

        let rawText = targetPage.selection(for: cropRect)?.string ?? ""
        let normalizedText = PDFTextNormalizer.normalize(rawText)
        let snapshot = renderSnapshot(of: targetPage, cropRect: cropRect)

        let rawMarker = sourcePage.selection(for: annotation.bounds.insetBy(dx: -3, dy: -3))?.string ?? ""
        let cleanedMarker = normalizeSuperscripts(rawMarker)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]()."))
        let marker = cleanedMarker.isEmpty ? "Not" : String(cleanedMarker.prefix(16))

        return FootnotePreview(
            marker: marker,
            sourcePageIndex: max(0, sourcePageIndex),
            targetPageIndex: targetPageIndex,
            targetRect: cropRect,
            extractedText: normalizedText,
            snapshotImage: snapshot,
            origin: .pdfLink,
            documentTitle: documentTitle,
            documentHash: documentHash
        )
    }

    // MARK: - 2. Heuristic Marker Resolution (Non-linked PDFs)

    public func resolveMarkerClick(
        at pagePoint: CGPoint,
        on sourcePage: PDFPage,
        in document: PDFDocument,
        documentTitle: String,
        documentHash: String? = nil,
        ocrPage: OCRPageResult? = nil
    ) -> FootnotePreview? {
        let sourcePageIndex = document.index(for: sourcePage)
        guard sourcePageIndex != NSNotFound else { return nil }

        var triedMarkers = Set<String>()

        func tryResolve(marker: String) -> FootnotePreview? {
            guard !triedMarkers.contains(marker) else { return nil }
            triedMarkers.insert(marker)
            return resolveVerifiedMarker(
                marker,
                at: pagePoint,
                on: sourcePage,
                sourcePageIndex: sourcePageIndex,
                in: document,
                documentTitle: documentTitle,
                documentHash: documentHash
            )
        }

        // Pass 1: Embedded PDF text layer
        if let directMarker = extractMarkerToken(at: pagePoint, on: sourcePage),
           let preview = tryResolve(marker: directMarker) {
            return preview
        }

        // Pass 2: Saved Apple Vision OCR page blocks
        if let ocrPage,
           let ocrMarker = extractMarkerToken(at: pagePoint, from: ocrPage),
           let preview = tryResolve(marker: ocrMarker) {
            return preview
        }

        // Pass 3: On-demand 8x micro-zoom Vision OCR with early exit on first verified match
        if isPlausibleSuperscriptClick(at: pagePoint, on: sourcePage) {
            var matchedPreview: FootnotePreview?
            _ = visionOCR.recognizeMicroSuperscript(at: pagePoint, on: sourcePage) { raw in
                for token in self.extractMicroMarkerTokens(from: raw) {
                    if let preview = tryResolve(marker: token) {
                        matchedPreview = preview
                        return true
                    }
                }
                return false
            }
            if let matchedPreview {
                return matchedPreview
            }
        }

        return nil
    }

    private func resolveVerifiedMarker(
        _ marker: String,
        at pagePoint: CGPoint,
        on sourcePage: PDFPage,
        sourcePageIndex: Int,
        in document: PDFDocument,
        documentTitle: String,
        documentHash: String?
    ) -> FootnotePreview? {
        // 1) Check bottom-of-page footnotes on the same page (cached)
        let pageFootnotes = extractPageFootnotes(from: sourcePage, pageIndex: sourcePageIndex)
        if let matched = pageFootnotes.first(where: { $0.marker == marker }) {
            let mediaBox = sourcePage.bounds(for: .mediaBox)
            let bottomArea = CGRect(
                x: mediaBox.minX,
                y: mediaBox.minY,
                width: mediaBox.width,
                height: mediaBox.height * Self.bottomScanHeightRatio
            )
            let matchBounds = locateSnippetBounds(
                snippet: matched.text,
                on: sourcePage,
                preferBottomRegion: true
            )
            // If the user clicked directly inside the footnote definition block at the bottom,
            // let normal text selection handle it instead of popping up itself.
            // Guard that matchBounds actually lies in the bottom footnote region so a fallback
            // match in body text never falsely suppresses valid body footnote clicks.
            let bottomThresholdY = mediaBox.minY + mediaBox.height * (Self.bottomScanHeightRatio + 0.04)
            if let matchBounds,
               matchBounds.maxY <= bottomThresholdY,
               pagePoint.y <= matchBounds.maxY + 6 {
                return nil
            }
            let cropRect = cropRectFromBounds(
                matchBounds,
                mediaBox: mediaBox,
                fallbackRect: bottomArea
            )
            let snapshot = renderSnapshot(of: sourcePage, cropRect: cropRect)

            return FootnotePreview(
                marker: matched.marker,
                sourcePageIndex: sourcePageIndex,
                targetPageIndex: sourcePageIndex,
                targetRect: cropRect,
                extractedText: matched.text,
                snapshotImage: snapshot,
                origin: .pageBottomHeuristic,
                documentTitle: documentTitle,
                documentHash: documentHash
            )
        }

        // 2) Search endnote pages using cached notes index (never stalls main thread)
        if let endnote = searchEndnotes(
            forMarker: marker,
            sourcePageIndex: sourcePageIndex,
            in: document,
            documentTitle: documentTitle,
            documentHash: documentHash
        ) {
            return endnote
        }

        return nil
    }

    // MARK: - 3. Bottom-of-Page Automatic Footnote Extraction

    public func extractPageFootnotes(from page: PDFPage, pageIndex: Int) -> [PageFootnoteItem] {
        let docKey = page.document.map { ObjectIdentifier($0) }
        if let docKey, let cached = cachedPageFootnotes(for: docKey, pageIndex: pageIndex) {
            return cached
        }

        let mediaBox = page.bounds(for: .mediaBox)
        let candidateFootnoteText = extractVerifiedBottomFootnoteRegionText(from: page, mediaBox: mediaBox)
        guard !candidateFootnoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let docKey {
                storePageFootnotes([], for: docKey, pageIndex: pageIndex)
            }
            return []
        }

        let parsed = parseFootnoteBlocks(from: candidateFootnoteText, pageIndex: pageIndex)
        if let docKey {
            storePageFootnotes(parsed, for: docKey, pageIndex: pageIndex)
        }
        return parsed
    }

    private func extractVerifiedBottomFootnoteRegionText(from page: PDFPage, mediaBox: CGRect) -> String {
        guard let fullSel = page.selection(for: mediaBox) else { return "" }
        let lineSels = fullSel.selectionsByLine()
        var positioned: [(text: String, bounds: CGRect)] = []
        for sel in lineSels where sel.pages.contains(page) {
            guard let s = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { continue }
            let b = sel.bounds(for: page)
            guard !b.isNull, !b.isEmpty, b.height > 1 else { continue }
            positioned.append((s, b))
        }

        guard positioned.count >= 2 else {
            let bottomRect = CGRect(
                x: mediaBox.minX,
                y: mediaBox.minY,
                width: mediaBox.width,
                height: mediaBox.height * 0.30
            )
            return page.selection(for: bottomRect)?.string ?? ""
        }

        // Sort top-to-bottom (descending midY)
        positioned.sort { lhs, rhs in
            if abs(lhs.bounds.midY - rhs.bounds.midY) > min(lhs.bounds.height, rhs.bounds.height) * 0.45 {
                return lhs.bounds.midY > rhs.bounds.midY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }

        let upperCutoff = mediaBox.minY + mediaBox.height * 0.45
        let upperHeights = positioned.filter { $0.bounds.midY >= upperCutoff }.map(\.bounds.height).sorted()
        let allHeights = positioned.map(\.bounds.height).sorted()
        let medianBodyHeight = upperHeights.isEmpty
            ? allHeights[allHeights.count / 2]
            : upperHeights[upperHeights.count / 2]

        let maxFootnoteZoneY = mediaBox.minY + mediaBox.height * 0.40
        let strictBottomZoneY = mediaBox.minY + mediaBox.height * 0.28

        var startIndex: Int?
        for idx in 1..<positioned.count {
            let curr = positioned[idx]
            guard curr.bounds.maxY <= maxFootnoteZoneY else { continue }
            if isStandalonePageNumber(curr.text) { continue }

            let prev = positioned[idx - 1]
            let vGap = prev.bounds.minY - curr.bounds.maxY
            let isSmallerFont = curr.bounds.height < medianBodyHeight * 0.91
            let isExplicitSymbolOrSup = curr.text.first.map {
                $0 == "*" || $0 == "†" || $0 == "‡" || isUnicodeSuperscriptDigit($0)
            } ?? false
            let isSeparatedAtBottom = curr.bounds.maxY <= strictBottomZoneY && vGap > medianBodyHeight * 0.80

            if (isSmallerFont || isExplicitSymbolOrSup || isSeparatedAtBottom),
               matchFootnoteStart(in: curr.text) != nil {
                startIndex = idx
                break
            }
        }

        guard let start = startIndex else { return "" }
        return positioned[start...].map(\.text).joined(separator: "\n")
    }

    // MARK: - 4. Marker & Footnote Block Parsing (Public for Unit Testing)

    public func parseMarkerToken(
        from raw: String,
        allowGluedSuffix: Bool = true,
        allowDecimalLike: Bool = false
    ) -> String? {
        let normalized = normalizeSuperscripts(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        // Handle OCR-spaced double asterisk "* *"
        let collapsedAsterisks = normalized.replacingOccurrences(of: "* *", with: "**")

        // 1) Standalone symbol markers
        let symbolTrimmed = collapsedAsterisks.trimmingCharacters(in: CharacterSet(charactersIn: "[]().,;:\"'"))
        if symbolTrimmed == "**" || symbolTrimmed == "*" || symbolTrimmed == "†" || symbolTrimmed == "‡" {
            return symbolTrimmed
        }

        // 2) Standalone numeric or alphanumeric marker: "3", "14", "1a", "5a", "[14]", "(5)", "{2.}"
        let tokenTrimmed = collapsedAsterisks.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}.,;:\"'·"))
        if !tokenTrimmed.isEmpty, tokenTrimmed.count <= 4 {
            let range = NSRange(tokenTrimmed.startIndex..., in: tokenTrimmed)
            if let match = Self.standaloneAlphanumericRegex.firstMatch(in: tokenTrimmed, range: range),
               let numRange = Range(match.range(at: 1), in: tokenTrimmed),
               let num = Int(tokenTrimmed[numRange]),
               (1...999).contains(num) {
                if match.range(at: 2).location != NSNotFound,
                   let suffixRange = Range(match.range(at: 2), in: tokenTrimmed) {
                    return "\(num)\(tokenTrimmed[suffixRange])"
                }
                return String(num)
            }
        }

        guard allowGluedSuffix else { return nil }

        // 3) Reject obvious ordinals ("1st", "2nd", "3rd", "19th") and 4-digit years ("1925")
        let lower = collapsedAsterisks.lowercased()
        if lower.hasSuffix("st") || lower.hasSuffix("nd") || lower.hasSuffix("rd") || lower.hasSuffix("th") {
            return nil
        }

        // 4) Glued trailing symbol: "to be*", "[jeweiliges].**", "world†"
        let fullRange = NSRange(collapsedAsterisks.startIndex..., in: collapsedAsterisks)
        if let match = Self.gluedTrailingSymbolRegex.firstMatch(in: collapsedAsterisks, range: fullRange),
           let symRange = Range(match.range(at: 1), in: collapsedAsterisks) {
            return String(collapsedAsterisks[symRange])
        }

        // 5) Glued trailing number or alphanumeric: "development.3", "(11).5", "'fascinated'6", "false.\"2", "1919-20.7", "appears,\"1a"
        // Avoid matching pure decimal numbers like "3.14" or "0.5" in normal text-layer clicks,
        // while allowing year ranges ("1919-20.7") and micro-OCR crops ("20.7" -> "7") when allowDecimalLike is true.
        if let match = Self.gluedTrailingNumberRegex.firstMatch(in: collapsedAsterisks, range: fullRange),
           let markerRange = Range(match.range(at: 1), in: collapsedAsterisks) {
            let candidate = String(collapsedAsterisks[markerRange])
            if !allowDecimalLike, markerRange.lowerBound > collapsedAsterisks.startIndex {
                let prevIdx = collapsedAsterisks.index(before: markerRange.lowerBound)
                if collapsedAsterisks[prevIdx] == "." {
                    let prefixBeforeDot = String(collapsedAsterisks[..<prevIdx])
                    if !prefixBeforeDot.isEmpty,
                       prefixBeforeDot.count <= 3,
                       prefixBeforeDot.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        return nil
                    }
                }
            }
            return parseMarkerToken(from: candidate, allowGluedSuffix: false)
        }

        return nil
    }

    /// Extracts all plausible footnote marker tokens from a micro-OCR string such as
    /// `"7"`, `".7"`, `"-20.7"`, `"20.7 Ph"`, `"o.7 Pl"`, `"7:"`, or `"* *"`.
    public func extractMicroMarkerTokens(from raw: String) -> [String] {
        var result: [String] = []
        func appendUnique(_ token: String?) {
            guard let token, !token.isEmpty, !result.contains(token) else { return }
            result.append(token)
        }

        // 1) Whole string first (handles standalone "7", ".7", "-20.7", "* *")
        appendUnique(parseMarkerToken(from: raw, allowGluedSuffix: true, allowDecimalLike: true))

        // 2) Whitespace-separated chunks (handles "20.7 Ph", "o.7 Pl", "7 D", ".7 :")
        let parts = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for part in parts {
            appendUnique(parseMarkerToken(from: part, allowGluedSuffix: true, allowDecimalLike: true))
            let trimmedNoise = part.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:'\"‘’“”`°^|[](){}"))
            if trimmedNoise != part {
                appendUnique(parseMarkerToken(from: trimmedNoise, allowGluedSuffix: true, allowDecimalLike: true))
            }
        }

        return result
    }

    public func parseFootnoteBlocks(from text: String, pageIndex: Int) -> [PageFootnoteItem] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var items: [PageFootnoteItem] = []
        var currentMarker: String?
        var currentLines: [String] = []
        var seenMarkers = Set<String>()

        func flushCurrent() {
            guard let marker = currentMarker, !currentLines.isEmpty else { return }
            let joined = PDFTextNormalizer.normalize(currentLines.joined(separator: "\n"))
            if !joined.isEmpty, joined.contains(where: { $0.isLetter }) {
                let uniqueID = seenMarkers.contains(marker)
                    ? "\(pageIndex)-\(marker)-\(items.count)"
                    : "\(pageIndex)-\(marker)"
                seenMarkers.insert(marker)
                items.append(
                    PageFootnoteItem(
                        id: uniqueID,
                        marker: marker,
                        text: joined,
                        pageIndex: pageIndex
                    )
                )
            }
            currentMarker = nil
            currentLines = []
        }

        for line in lines {
            guard !line.isEmpty else {
                if currentMarker != nil {
                    currentLines.append("")
                }
                continue
            }

            if isStandalonePageNumber(line) {
                continue
            }

            if let match = matchFootnoteStart(in: line) {
                flushCurrent()
                currentMarker = match.marker
                currentLines = [match.body]
            } else if currentMarker != nil {
                currentLines.append(line)
            }
        }

        flushCurrent()
        return items
    }

    // MARK: - 5. Retina Snapshot Renderer

    public func renderSnapshot(of page: PDFPage, cropRect: CGRect, scale: CGFloat = 2.0) -> PlatformImage? {
        let mediaBox = page.bounds(for: .mediaBox)
        let clamped = cropRect.intersection(mediaBox)
        guard !clamped.isNull, clamped.width > 1, clamped.height > 1 else {
            return nil
        }

        let rotation = ((page.rotation % 360) + 360) % 360
        let pageTransform = page.transform(for: .mediaBox)
        let displayRect = rotation == 0 ? clamped : clamped.applying(pageTransform)
        guard displayRect.width > 1, displayRect.height > 1 else {
            return nil
        }

        let pixelWidth = max(1, Int(ceil(displayRect.width * scale)))
        let pixelHeight = max(1, Int(ceil(displayRect.height * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -displayRect.minX, y: -displayRect.minY)
        if rotation != 0 {
            ctx.concatenate(pageTransform)
        }
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        guard let cgImage = ctx.makeImage() else { return nil }
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: displayRect.size)
        #elseif canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        #endif
    }

    // MARK: - Internal Helpers

    private func scanNotesSectionPages(in document: PDFDocument) -> [Int] {
        let totalPages = document.pageCount
        guard totalPages > 0 else { return [] }
        var result: [Int] = []
        for idx in 0..<totalPages {
            guard let page = document.page(at: idx),
                  let text = page.string,
                  !text.isEmpty else { continue }
            if isNotesHeadingPageText(text) {
                result.append(idx)
            }
        }
        return result
    }

    private func computeTargetCropRect(for point: CGPoint, on mediaBox: CGRect) -> CGRect {
        let isSpecified = point.y.isFinite && abs(point.y) < 100_000
        let topY: CGFloat
        let bottomY: CGFloat

        if isSpecified {
            let anchorY = max(mediaBox.minY, min(mediaBox.maxY, point.y))
            let candidateTop = min(mediaBox.maxY, anchorY + 28)
            let candidateBottom = max(mediaBox.minY, candidateTop - 280)
            if candidateTop - candidateBottom < 160 {
                bottomY = candidateBottom
                topY = min(mediaBox.maxY, bottomY + 180)
            } else {
                topY = candidateTop
                bottomY = candidateBottom
            }
        } else {
            topY = mediaBox.maxY
            bottomY = max(mediaBox.minY, topY - 320)
        }

        return CGRect(
            x: mediaBox.minX,
            y: bottomY,
            width: mediaBox.width,
            height: max(40, topY - bottomY)
        )
    }

    private func extractMarkerToken(at pagePoint: CGPoint, on page: PDFPage) -> String? {
        let wordSelection = page.selectionForWord(at: pagePoint)
        let wordBounds = wordSelection?.bounds(for: page) ?? .null
        let isInsideWord = !wordBounds.isNull && !wordBounds.isEmpty
            && wordBounds.insetBy(dx: -4.0, dy: -4.0).contains(pagePoint)

        if isInsideWord, let rawWord = wordSelection?.string {
            let rawTrimmed = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            // Parenthesized numbers in body prose like "(1)" or "(2)" are logic premises/equations, not footnotes
            if rawTrimmed.hasPrefix("(") && rawTrimmed.hasSuffix(")") {
                return nil
            }

            let trimmedWord = normalizeSuperscripts(rawTrimmed)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[](){}.,;:\"'"))
            // Reject 4+ digit numbers (years like 1925) and ordinals (19th, 2nd) before checking tinyRect
            if trimmedWord.count >= 4 && trimmedWord.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return nil
            }
            let lowerWord = trimmedWord.lowercased()
            if lowerWord.count >= 3,
               lowerWord.first?.isNumber == true,
               (lowerWord.hasSuffix("st") || lowerWord.hasSuffix("nd") || lowerWord.hasSuffix("rd") || lowerWord.hasSuffix("th")) {
                return nil
            }
            if let standalone = parseMarkerToken(from: rawWord, allowGluedSuffix: false) {
                if standalone == "*" {
                    let asteriskRect = CGRect(x: pagePoint.x - 9, y: pagePoint.y - 6, width: 18, height: 12)
                    if let nearAst = page.selection(for: asteriskRect)?.string,
                       nearAst.replacingOccurrences(of: "* *", with: "**").contains("**") {
                        return "**"
                    }
                }
                return standalone
            }
        }

        // Check tight 8x8pt area around the exact click point (verifying the selection actually touches pagePoint)
        let tinyRect = CGRect(x: pagePoint.x - 4.0, y: pagePoint.y - 4.0, width: 8.0, height: 8.0)
        if let nearSel = page.selection(for: tinyRect),
           !nearSel.bounds(for: page).isEmpty,
           nearSel.bounds(for: page).insetBy(dx: -4.5, dy: -4.5).contains(pagePoint),
           let near = nearSel.string {
            let trimmedNear = near.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(trimmedNear.hasPrefix("(") && trimmedNear.hasSuffix(")")) {
                if near.replacingOccurrences(of: "* *", with: "**").contains("**") {
                    return "**"
                }
                if let token = parseMarkerToken(from: near, allowGluedSuffix: true) {
                    return token
                }
            }
        }

        // For glued words like "development.3", trigger only when clicking inside the trailing edge of the word
        if isInsideWord, let rawWord = wordSelection?.string {
            let trailingZoneStart = min(wordBounds.maxX - 16, wordBounds.minX + wordBounds.width * 0.65)
            if pagePoint.x >= trailingZoneStart && pagePoint.x <= wordBounds.maxX + 4.0,
               let glued = parseMarkerToken(from: rawWord, allowGluedSuffix: true) {
                return glued
            }
        }

        return nil
    }

    public func extractMarkerToken(at pagePoint: CGPoint, from ocrPage: OCRPageResult) -> String? {
        for block in ocrPage.blocks {
            let rect = block.rect.cgRect.insetBy(dx: -4, dy: -4)
            guard rect.contains(pagePoint), !block.text.isEmpty else { continue }

            // If the entire block is a standalone marker
            if let standalone = parseMarkerToken(from: block.text, allowGluedSuffix: false) {
                return standalone
            }

            // Estimate character index from click X inside the OCR line bounding box
            let width = max(1, block.rect.width)
            let ratio = max(0.0, min(1.0, (Double(pagePoint.x) - block.rect.x) / width))
            let chars = Array(block.text)
            let centerIdx = min(chars.count - 1, max(0, Int(round(ratio * Double(chars.count)))))
            let startIdx = max(0, centerIdx - 6)
            let endIdx = min(chars.count, centerIdx + 6)
            let window = String(chars[startIdx..<endIdx])

            for token in window.split(whereSeparator: { $0.isWhitespace }) {
                if let parsed = parseMarkerToken(from: String(token), allowGluedSuffix: true) {
                    return parsed
                }
            }
        }
        return nil
    }

    private func isPlausibleSuperscriptClick(at pagePoint: CGPoint, on page: PDFPage) -> Bool {
        let pageHasEmbeddedText = !(page.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !pageHasEmbeddedText {
            // Pure scanned image page without any PDF text layer -> allow micro-OCR at click point
            return true
        }

        // On pages WITH embedded text, clicking blank space / margins must NEVER run Vision OCR!
        let tinyRect = CGRect(x: pagePoint.x - 4.0, y: pagePoint.y - 4.0, width: 8.0, height: 8.0)
        guard let nearSel = page.selection(for: tinyRect),
              !nearSel.bounds(for: page).isEmpty,
              nearSel.bounds(for: page).insetBy(dx: -4.0, dy: -4.0).contains(pagePoint) else {
            return false
        }
        let nearText = (nearSel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nearText.isEmpty else { return false }

        // Only run micro-OCR on embedded-text pages when clicking right on the trailing upper edge of a word
        // that carries OCR-garbled superscript artifacts (like `.'`, `."`, `*`, `†`, `‡`, `°`)
        guard let wordSel = page.selectionForWord(at: pagePoint) else { return false }
        let wb = wordSel.bounds(for: page)
        guard !wb.isEmpty, wb.insetBy(dx: -4.0, dy: -4.0).contains(pagePoint) else { return false }
        guard pagePoint.x >= wb.maxX - 6.0 && pagePoint.y >= wb.midY - 2.0 else { return false }

        let ocrSuperscriptArtifacts = CharacterSet(charactersIn: "'’\"”*†‡^°`")
        return nearText.unicodeScalars.contains(where: { ocrSuperscriptArtifacts.contains($0) })
    }

    private func matchFootnoteStart(in line: String) -> (marker: String, body: String)? {
        let normalizedLine = normalizeSuperscripts(line)
        let fullRange = NSRange(normalizedLine.startIndex..., in: normalizedLine)

        // 1. Double asterisk ("**" or OCR-spaced "* *")
        if let match = Self.doubleAsteriskRegex.firstMatch(in: normalizedLine, range: fullRange),
           let bodyRange = Range(match.range(at: 1), in: normalizedLine) {
            let body = String(normalizedLine[bodyRange]).trimmingCharacters(in: .whitespaces)
            if body.count >= 3, body.contains(where: { $0.isLetter }) {
                return ("**", body)
            }
        }

        // 2. Single explicit symbol marker (*, †, ‡)
        if let first = normalizedLine.first, (first == "*" || first == "†" || first == "‡") {
            let rest = String(normalizedLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            if rest.count >= 3, rest.contains(where: { $0.isLetter }) {
                return (String(first), rest)
            }
        }

        // 3. Braced marker: "{2.} Text" or "{2} Text"
        if let match = Self.bracedMarkerRegex.firstMatch(in: normalizedLine, range: fullRange),
           let markerRange = Range(match.range(at: 1), in: normalizedLine),
           let bodyRange = Range(match.range(at: 2), in: normalizedLine) {
            let marker = String(normalizedLine[markerRange])
            let body = String(normalizedLine[bodyRange]).trimmingCharacters(in: .whitespaces)
            if body.count >= 3, body.contains(where: { $0.isLetter }) {
                return (marker, body)
            }
        }

        // 4. Alphanumeric marker with punctuation: "1a. Text", "5a. Text", "7a) Text"
        if let match = Self.alphanumericPunctRegex.firstMatch(in: normalizedLine, range: fullRange),
           let markerRange = Range(match.range(at: 1), in: normalizedLine),
           let bodyRange = Range(match.range(at: 2), in: normalizedLine) {
            let marker = String(normalizedLine[markerRange])
            let body = String(normalizedLine[bodyRange]).trimmingCharacters(in: .whitespaces)
            if body.count >= 3, body.contains(where: { $0.isLetter }) {
                return (marker, body)
            }
        }

        // 5. Digit(s) with punctuation (including OCR middle dot "3· Ibid.")
        if let match = Self.digitPunctRegex.firstMatch(in: normalizedLine, range: fullRange),
           let markerRange = Range(match.range(at: 1), in: normalizedLine),
           let bodyRange = Range(match.range(at: 2), in: normalizedLine) {
            let marker = String(normalizedLine[markerRange])
            let body = String(normalizedLine[bodyRange]).trimmingCharacters(in: .whitespaces)
            if let num = Int(marker), (1...999).contains(num),
               body.count >= 3, body.contains(where: { $0.isLetter }) {
                return (String(num), body)
            }
        }

        // 6. OCR misreading "1." as "I." at bottom of page (e.g. "I. Franz Brentano...", "I. Cf. ...")
        if let match = Self.ocrIRegex.firstMatch(in: normalizedLine, range: fullRange),
           let bodyRange = Range(match.range(at: 1), in: normalizedLine) {
            let body = String(normalizedLine[bodyRange]).trimmingCharacters(in: .whitespaces)
            if body.count >= 4, body.contains(where: { $0.isLowercase }) {
                return ("1", body)
            }
        }

        // 7. Original superscript digit prefix: "¹Text" or "¹ Text"
        if let first = line.first, isUnicodeSuperscriptDigit(first) {
            var supDigits = ""
            var idx = line.startIndex
            while idx < line.endIndex && isUnicodeSuperscriptDigit(line[idx]) {
                supDigits.append(line[idx])
                idx = line.index(after: idx)
            }
            let marker = normalizeSuperscripts(supDigits)
            let body = String(line[idx...]).trimmingCharacters(in: .whitespaces)
            if let num = Int(marker), (1...999).contains(num),
               body.count >= 3, body.contains(where: { $0.isLetter }) {
                return (String(num), body)
            }
        }

        // 8. Bare digit(s) + space + capitalized start: "12 Heidegger argues..."
        if let match = Self.bareDigitRegex.firstMatch(in: normalizedLine, range: fullRange),
           let markerRange = Range(match.range(at: 1), in: normalizedLine),
           let bodyRange = Range(match.range(at: 2), in: normalizedLine) {
            let marker = String(normalizedLine[markerRange])
            let body = String(normalizedLine[bodyRange]).trimmingCharacters(in: .whitespaces)
            if let num = Int(marker), (1...999).contains(num),
               body.count >= 4, body.contains(where: { $0.isLetter }) {
                return (String(num), body)
            }
        }

        return nil
    }

    private func searchEndnotes(
        forMarker marker: String,
        sourcePageIndex: Int,
        in document: PDFDocument,
        documentTitle: String,
        documentHash: String? = nil
    ) -> FootnotePreview? {
        let totalPages = document.pageCount
        guard totalPages > 0 else { return nil }

        let docKey = ObjectIdentifier(document)
        let notesHeadings: [Int]

        if let cached = cachedNotesPages(for: docKey) {
            notesHeadings = cached
        } else {
            // Prewarm hasn't finished yet: do a fast bounded scan of at most 20 pages ahead
            // so mouseDown stays instantaneous even on a 500-page PDF.
            var quickFound: [Int] = []
            let upperBound = min(totalPages, sourcePageIndex + 21)
            if sourcePageIndex + 1 < upperBound {
                for idx in (sourcePageIndex + 1)..<upperBound {
                    if let page = document.page(at: idx),
                       let text = page.string,
                       isNotesHeadingPageText(text) {
                        quickFound.append(idx)
                    }
                }
            }
            notesHeadings = quickFound
        }

        // Prioritize the nearest upcoming NOTES heading pages after sourcePageIndex
        let upcomingHeadings = notesHeadings.filter { $0 > sourcePageIndex }.sorted()
        let headingSet = Set(notesHeadings)
        var visited = Set<Int>()

        func blocksForEndnotePage(_ pageIndex: Int) -> [PageFootnoteItem] {
            if let cachedBlocks = cachedEndnoteBlocks(for: docKey, pageIndex: pageIndex) {
                return cachedBlocks
            }
            guard let page = document.page(at: pageIndex),
                  let pageText = page.string else {
                storeEndnoteBlocks([], for: docKey, pageIndex: pageIndex)
                return []
            }
            let parsed = parseFootnoteBlocks(from: pageText, pageIndex: pageIndex)
            storeEndnoteBlocks(parsed, for: docKey, pageIndex: pageIndex)
            return parsed
        }

        for headingPage in upcomingHeadings {
            var consecutiveEmptyContinuations = 0
            // Follow multi-page endnotes sections (up to 20 continuation pages), stopping once the section ends.
            for offset in 0...20 {
                let pageIndex = headingPage + offset
                guard pageIndex >= 0, pageIndex < totalPages, pageIndex != sourcePageIndex else { break }
                if offset > 0 && headingSet.contains(pageIndex) {
                    break
                }
                guard !visited.contains(pageIndex) else { continue }
                visited.insert(pageIndex)

                let blocks = blocksForEndnotePage(pageIndex)
                if offset > 0 {
                    if blocks.isEmpty {
                        consecutiveEmptyContinuations += 1
                        if consecutiveEmptyContinuations >= 2 {
                            break
                        }
                        continue
                    } else {
                        consecutiveEmptyContinuations = 0
                    }
                }

                if let matched = blocks.first(where: { $0.marker == marker }),
                   let page = document.page(at: pageIndex) {
                    let mediaBox = page.bounds(for: .mediaBox)
                    let fallback = CGRect(
                        x: mediaBox.minX,
                        y: max(mediaBox.minY, mediaBox.maxY - 320),
                        width: mediaBox.width,
                        height: min(320, mediaBox.height)
                    )
                    let cropRect = cropRectFromBounds(
                        locateSnippetBounds(snippet: matched.text, on: page, preferBottomRegion: false),
                        mediaBox: mediaBox,
                        fallbackRect: fallback
                    )
                    let snapshot = renderSnapshot(of: page, cropRect: cropRect)

                    return FootnotePreview(
                        marker: matched.marker,
                        sourcePageIndex: sourcePageIndex,
                        targetPageIndex: pageIndex,
                        targetRect: cropRect,
                        extractedText: matched.text,
                        snapshotImage: snapshot,
                        origin: .endnoteHeuristic,
                        documentTitle: documentTitle,
                        documentHash: documentHash
                    )
                }
            }
        }

        return nil
    }

    private func locateSnippetBounds(
        snippet: String,
        on page: PDFPage,
        preferBottomRegion: Bool
    ) -> CGRect? {
        let mediaBox = page.bounds(for: .mediaBox)
        let probeWords = snippet
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(5)
            .joined(separator: " ")

        guard !probeWords.isEmpty,
              let pageText = page.string as NSString? else {
            return nil
        }

        var searchStart = 0
        var firstValidBounds: CGRect?
        let bottomThresholdY = mediaBox.minY + mediaBox.height * (Self.bottomScanHeightRatio + 0.04)

        while searchStart < pageText.length {
            let searchRange = NSRange(location: searchStart, length: pageText.length - searchStart)
            let range = pageText.range(of: probeWords, options: [.caseInsensitive], range: searchRange)
            guard range.location != NSNotFound else { break }

            if let sel = page.selection(for: range) {
                let bounds = sel.bounds(for: page)
                if !bounds.isEmpty {
                    if firstValidBounds == nil {
                        firstValidBounds = bounds
                    }
                    if !preferBottomRegion || bounds.maxY <= bottomThresholdY {
                        return bounds
                    }
                }
            }
            searchStart = range.location + max(1, range.length)
        }

        return firstValidBounds
    }

    private func cropRectFromBounds(
        _ bounds: CGRect?,
        mediaBox: CGRect,
        fallbackRect: CGRect
    ) -> CGRect {
        guard let bounds else { return fallbackRect }
        let topY = min(mediaBox.maxY, bounds.maxY + 28)
        let bottomY = max(mediaBox.minY, topY - 240)
        return CGRect(
            x: mediaBox.minX,
            y: bottomY,
            width: mediaBox.width,
            height: max(80, topY - bottomY)
        )
    }

    private func isStandalonePageNumber(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.allSatisfy({ $0.isNumber }) && trimmed.count <= 4 {
            return true
        }
        let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-–—[]() "))
        return !cleaned.isEmpty && cleaned.allSatisfy({ $0.isNumber }) && cleaned.count <= 4
    }

    private func isUnicodeSuperscriptDigit(_ ch: Character) -> Bool {
        "¹²³⁴⁵⁶⁷⁸⁹⁰".contains(ch)
    }

    private func normalizeSuperscripts(_ input: String) -> String {
        let map: [Character: Character] = [
            "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4",
            "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9"
        ]
        return String(input.map { map[$0] ?? $0 })
    }

    // MARK: - Lock-Protected Bounded Cache Accessors

    private func touchCacheKeyUnlocked(_ docKey: ObjectIdentifier) {
        if let idx = cachedDocumentOrder.firstIndex(of: docKey) {
            cachedDocumentOrder.remove(at: idx)
        }
        cachedDocumentOrder.append(docKey)
        while cachedDocumentOrder.count > Self.maxCachedDocuments {
            let evicted = cachedDocumentOrder.removeFirst()
            pageFootnotesCache.removeValue(forKey: evicted)
            notesSectionPagesCache.removeValue(forKey: evicted)
            endnoteBlocksCache.removeValue(forKey: evicted)
        }
    }

    private func cachedPageFootnotes(for docKey: ObjectIdentifier, pageIndex: Int) -> [PageFootnoteItem]? {
        lock.lock()
        defer { lock.unlock() }
        return pageFootnotesCache[docKey]?[pageIndex]
    }

    private func storePageFootnotes(_ items: [PageFootnoteItem], for docKey: ObjectIdentifier, pageIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        pageFootnotesCache[docKey, default: [:]][pageIndex] = items
        touchCacheKeyUnlocked(docKey)
    }

    private func cachedNotesPages(for docKey: ObjectIdentifier) -> [Int]? {
        lock.lock()
        defer { lock.unlock() }
        return notesSectionPagesCache[docKey]
    }

    private func storeNotesPages(_ pages: [Int], for docKey: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        notesSectionPagesCache[docKey] = pages
        touchCacheKeyUnlocked(docKey)
    }

    private func cachedEndnoteBlocks(for docKey: ObjectIdentifier, pageIndex: Int) -> [PageFootnoteItem]? {
        lock.lock()
        defer { lock.unlock() }
        return endnoteBlocksCache[docKey]?[pageIndex]
    }

    private func storeEndnoteBlocks(_ items: [PageFootnoteItem], for docKey: ObjectIdentifier, pageIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        endnoteBlocksCache[docKey, default: [:]][pageIndex] = items
        touchCacheKeyUnlocked(docKey)
    }
}
