import CoreGraphics
import Foundation
import PDFKit

public struct VisualColumnSlice: Hashable, Sendable {
    /// Bounding box in PDF page `.mediaBox` coordinates.
    public let rect: CGRect
    /// Inter-line horizontal white-gap Y coordinates in `.mediaBox` space, sorted top-to-bottom (descending Y).
    public let lineGapYs: [CGFloat]

    public init(rect: CGRect, lineGapYs: [CGFloat]) {
        self.rect = rect
        self.lineGapYs = lineGapYs
    }
}

public struct VisualPageLayout: Hashable, Sendable {
    public let pageIndex: Int
    public let mediaBox: CGRect
    public let tightInkRect: CGRect
    public let slices: [VisualColumnSlice]
    public let isTwoColumn: Bool

    public init(
        pageIndex: Int,
        mediaBox: CGRect,
        tightInkRect: CGRect,
        slices: [VisualColumnSlice],
        isTwoColumn: Bool
    ) {
        self.pageIndex = pageIndex
        self.mediaBox = mediaBox
        self.tightInkRect = tightInkRect
        self.slices = slices
        self.isTwoColumn = isTwoColumn
    }
}

private final class VisualFlowDocCache: NSObject {
    var layouts: [Int: VisualPageLayout] = [:]
}

/// 100% pixel-projection layout analyzer (zero OCR).
/// Works identically on scanned image PDFs, math/logic formulas, and vector PDFs to detect:
/// 1. Tight per-page ink bounds (eliminating uneven odd/even scan margins),
/// 2. Single-column vs two-column academic paper layouts (including full-width title headers),
/// 3. Exact inter-line horizontal white gaps so vertical tap-stepping and the Reading Ruler
///    never slice a line of text in half.
public final class VisualReadingFlowService: @unchecked Sendable {
    private let lock = NSLock()
    private let caches = NSMapTable<PDFDocument, VisualFlowDocCache>.weakToStrongObjects()

    public init() {}

    public func analyzePage(
        _ page: PDFPage,
        pageIndex: Int,
        padding: CGFloat = 4.5
    ) -> VisualPageLayout {
        if let doc = page.document {
            lock.lock()
            if let cached = caches.object(forKey: doc)?.layouts[pageIndex] {
                lock.unlock()
                return cached
            }
            lock.unlock()
        }

        let computed = computeLayout(for: page, pageIndex: pageIndex, padding: padding)

        if let doc = page.document {
            lock.lock()
            let bucket = caches.object(forKey: doc) ?? {
                let created = VisualFlowDocCache()
                caches.setObject(created, forKey: doc)
                return created
            }()
            bucket.layouts[pageIndex] = computed
            lock.unlock()
        }

        return computed
    }

    public func evictCache(for document: PDFDocument) {
        lock.lock()
        caches.removeObject(forKey: document)
        lock.unlock()
    }

    // MARK: - Core Grayscale Pixel Projection

    private func computeLayout(
        for page: PDFPage,
        pageIndex: Int,
        padding: CGFloat
    ) -> VisualPageLayout {
        let mediaBox = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        guard mediaBox.width > 20, mediaBox.height > 20, rotation == 0 else {
            let fallbackSlice = VisualColumnSlice(rect: mediaBox, lineGapYs: [])
            return VisualPageLayout(
                pageIndex: pageIndex,
                mediaBox: mediaBox,
                tightInkRect: mediaBox,
                slices: [fallbackSlice],
                isTwoColumn: false
            )
        }

        // Render ~420px tall grayscale bitmap (~120 KB, < 3 ms) — enough vertical resolution to see every inter-line gap
        let scale = min(0.9, 420.0 / mediaBox.height)
        let width = max(24, Int(ceil(mediaBox.width * scale)))
        let height = max(24, Int(ceil(mediaBox.height * scale)))

        var pixels = [UInt8](repeating: 255, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            let fallbackSlice = VisualColumnSlice(rect: mediaBox, lineGapYs: [])
            return VisualPageLayout(
                pageIndex: pageIndex,
                mediaBox: mediaBox,
                tightInkRect: mediaBox,
                slices: [fallbackSlice],
                isTwoColumn: false
            )
        }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        let inkThreshold: UInt8 = 238
        let border = 3
        var minCol = width
        var maxCol = -1
        var minRow = height
        var maxRow = -1

        if height > border * 2 && width > border * 2 {
            for row in border..<(height - border) {
                let rowOff = row * width
                for col in border..<(width - border) {
                    if pixels[rowOff + col] < inkThreshold {
                        if col < minCol { minCol = col }
                        if col > maxCol { maxCol = col }
                        if row < minRow { minRow = row }
                        if row > maxRow { maxRow = row }
                    }
                }
            }
        }

        guard maxCol > minCol + 8, maxRow > minRow + 8 else {
            let fallbackSlice = VisualColumnSlice(rect: mediaBox, lineGapYs: [])
            return VisualPageLayout(
                pageIndex: pageIndex,
                mediaBox: mediaBox,
                tightInkRect: mediaBox,
                slices: [fallbackSlice],
                isTwoColumn: false
            )
        }

        func pdfRectFromPixelBox(c0: Int, c1: Int, r0: Int, r1: Int, pad: CGFloat) -> CGRect {
            let x0 = mediaBox.minX + CGFloat(c0) / scale
            let x1 = mediaBox.minX + CGFloat(c1 + 1) / scale
            // Row 0 is top of image (mediaBox.maxY), row (height-1) is bottom (mediaBox.minY)
            let y0 = mediaBox.minY + CGFloat(height - 1 - r1) / scale
            let y1 = mediaBox.minY + CGFloat(height - r0) / scale
            let raw = CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
            let padded = raw.insetBy(dx: -pad, dy: -pad).intersection(mediaBox)
            if padded.isNull || padded.width < mediaBox.width * 0.12 || padded.height < mediaBox.height * 0.08 {
                return mediaBox
            }
            return padded
        }

        func extractLineGapYs(c0: Int, c1: Int, r0: Int, r1: Int) -> [CGFloat] {
            guard r1 > r0 + 4, c1 > c0 + 4 else { return [] }
            let spanW = c1 - c0 + 1
            let dustTol = max(0, spanW / 95)

            var isGapRow = [Bool](repeating: true, count: r1 - r0 + 1)
            for r in r0...r1 {
                let off = r * width
                var dark = 0
                for c in c0...c1 where pixels[off + c] < inkThreshold {
                    dark += 1
                    if dark > dustTol { break }
                }
                isGapRow[r - r0] = (dark <= dustTol)
            }

            // Collect midpoints of white inter-line gaps bounded by ink above and below
            var gaps: [CGFloat] = []
            var seenInk = false
            var idx = 0
            let count = isGapRow.count
            while idx < count {
                if !isGapRow[idx] {
                    seenInk = true
                    idx += 1
                    continue
                }
                let start = idx
                while idx < count && isGapRow[idx] {
                    idx += 1
                }
                let end = idx - 1
                if seenInk && idx < count {
                    let midRow = Double(r0) + Double(start + end + 1) * 0.5
                    let pdfY = mediaBox.minY + CGFloat(Double(height) - midRow) / scale
                    gaps.append(pdfY)
                }
            }
            return gaps
        }

        let tightInkRect = pdfRectFromPixelBox(c0: minCol, c1: maxCol, r0: minRow, r1: maxRow, pad: padding)

        // Check for a clean two-column vertical gutter in the lower/middle body region
        let inkW = maxCol - minCol + 1
        let inkH = maxRow - minRow + 1
        if CGFloat(inkW) >= CGFloat(width) * 0.52 && inkH >= 60 {
            let probeR0 = minRow + Int(Double(inkH) * 0.24)
            let probeR1 = maxRow - Int(Double(inkH) * 0.14)
            let searchC0 = minCol + Int(Double(inkW) * 0.30)
            let searchC1 = minCol + Int(Double(inkW) * 0.70)

            if probeR1 > probeR0 + 25 && searchC1 > searchC0 + 4 {
                let probeRows = probeR1 - probeR0 + 1
                var bestStart = -1
                var bestEnd = -1
                var curStart = -1

                for c in searchC0...searchC1 {
                    var darkRows = 0
                    for r in probeR0...probeR1 where pixels[r * width + c] < inkThreshold {
                        darkRows += 1
                    }
                    let isWhiteCol = Double(darkRows) / Double(probeRows) <= 0.02
                    if isWhiteCol {
                        if curStart == -1 { curStart = c }
                        if (c - curStart) > (bestEnd - bestStart) {
                            bestStart = curStart
                            bestEnd = c
                        }
                    } else {
                        curStart = -1
                    }
                }

                let gutterWidthPt = bestStart >= 0 ? CGFloat(bestEnd - bestStart + 1) / scale : 0
                let leftWidthPt = bestStart > minCol ? CGFloat(bestStart - minCol) / scale : 0
                let rightWidthPt = maxCol > bestEnd ? CGFloat(maxCol - bestEnd) / scale : 0
                if gutterWidthPt >= 7.0 && leftWidthPt >= 80.0 && rightWidthPt >= 80.0 {
                    // Verify both left and right halves actually carry dense text lines
                    let leftHasBody = regionActiveRowRatio(
                        pixels: pixels, width: width, threshold: inkThreshold,
                        c0: minCol, c1: bestStart - 1, r0: probeR0, r1: probeR1
                    ) >= 0.30
                    let rightHasBody = regionActiveRowRatio(
                        pixels: pixels, width: width, threshold: inkThreshold,
                        c0: bestEnd + 1, c1: maxCol, r0: probeR0, r1: probeR1
                    ) >= 0.25

                    if leftHasBody && rightHasBody {
                        // Find where any top spanning title/abstract ends above the 2-column split
                        var splitStartRow = minRow
                        for r in stride(from: probeR0, through: minRow, by: -1) {
                            var gutterInk = 0
                            for c in bestStart...bestEnd where pixels[r * width + c] < inkThreshold {
                                gutterInk += 1
                            }
                            if gutterInk > 0 {
                                splitStartRow = min(probeR0, r + 2)
                                break
                            }
                        }

                        var slices: [VisualColumnSlice] = []
                        if splitStartRow - minRow >= Int(18.0 * scale) {
                            let topRect = pdfRectFromPixelBox(
                                c0: minCol, c1: maxCol, r0: minRow, r1: splitStartRow - 1, pad: padding
                            )
                            let topGaps = extractLineGapYs(c0: minCol, c1: maxCol, r0: minRow, r1: splitStartRow - 1)
                            slices.append(VisualColumnSlice(rect: topRect, lineGapYs: topGaps))
                        }

                        let leftRect = pdfRectFromPixelBox(
                            c0: minCol, c1: bestStart, r0: splitStartRow, r1: maxRow, pad: padding
                        )
                        let leftGaps = extractLineGapYs(c0: minCol, c1: bestStart, r0: splitStartRow, r1: maxRow)
                        slices.append(VisualColumnSlice(rect: leftRect, lineGapYs: leftGaps))

                        let rightRect = pdfRectFromPixelBox(
                            c0: bestEnd, c1: maxCol, r0: splitStartRow, r1: maxRow, pad: padding
                        )
                        let rightGaps = extractLineGapYs(c0: bestEnd, c1: maxCol, r0: splitStartRow, r1: maxRow)
                        slices.append(VisualColumnSlice(rect: rightRect, lineGapYs: rightGaps))

                        return VisualPageLayout(
                            pageIndex: pageIndex,
                            mediaBox: mediaBox,
                            tightInkRect: tightInkRect,
                            slices: slices,
                            isTwoColumn: true
                        )
                    }
                }
            }
        }

        let gaps = extractLineGapYs(c0: minCol, c1: maxCol, r0: minRow, r1: maxRow)
        let singleSlice = VisualColumnSlice(rect: tightInkRect, lineGapYs: gaps)
        return VisualPageLayout(
            pageIndex: pageIndex,
            mediaBox: mediaBox,
            tightInkRect: tightInkRect,
            slices: [singleSlice],
            isTwoColumn: false
        )
    }

    private func regionActiveRowRatio(
        pixels: [UInt8],
        width: Int,
        threshold: UInt8,
        c0: Int,
        c1: Int,
        r0: Int,
        r1: Int
    ) -> Double {
        guard c1 > c0, r1 > r0 else { return 0 }
        var activeRows = 0
        for r in r0...r1 {
            let off = r * width
            for c in c0...c1 where pixels[off + c] < threshold {
                activeRows += 1
                break
            }
        }
        return Double(activeRows) / Double(r1 - r0 + 1)
    }

    // MARK: - k2pdfopt-Style Visual Word-Wrap Reflow (Zero OCR, Crisp Original Glyphs & Intact Figures)

    public struct PlacedWordHitBox: Hashable, Sendable {
        /// Logical rect in reflowed scroll view points (origin top-left, Y increases downward).
        public let viewRect: CGRect
        /// Exact source rect on the original `PDFPage` in `.mediaBox` coordinates (origin bottom-left).
        public let pdfRect: CGRect

        public init(viewRect: CGRect, pdfRect: CGRect) {
            self.viewRect = viewRect
            self.pdfRect = pdfRect
        }
    }

    public struct VisualReflowedPage: @unchecked Sendable {
        public let cgImage: CGImage
        public let logicalSize: CGSize
        public let pixelScale: CGFloat
        /// Y positions (in logical top-down UI points) between wrapped rows for clean step-scrolling & Reading Ruler.
        public let rowBreakYs: [CGFloat]
        public let wordHitBoxes: [PlacedWordHitBox]
    }

    private struct WordSliceSpec {
        let pdfRect: CGRect
        let ascentPt: CGFloat
    }

    private enum ExtractedSegment {
        case figure(pdfRect: CGRect)
        case textLine(words: [WordSliceSpec], startsParagraph: Bool, baseFontHeightPt: CGFloat)
    }

    /// Renders a PDF page into a crisp, word-wrapped mobile reading canvas at `zoomMultiplier` (e.g. 1.5x...2.5x)
    /// purely by slicing inter-line and inter-word pixel whitespace (0% OCR — symbols, math, and diagrams stay intact).
    public func renderReflowedPage(
        _ page: PDFPage,
        pageIndex: Int,
        targetWidthPt: CGFloat,
        zoomMultiplier: CGFloat = 1.85,
        annotations: [AnnotationItem] = [],
        screenScale: CGFloat = 2.5
    ) -> VisualReflowedPage? {
        let layout = analyzePage(page, pageIndex: pageIndex, padding: 3.0)
        let cropRect = layout.tightInkRect
        guard cropRect.width > 20, cropRect.height > 20, targetWidthPt > 120 else {
            return nil
        }

        // 1. Segment words & intact figure blocks at 2.0 px/pt grayscale (~0.6 MB, < 5 ms)
        let segScale: CGFloat = 2.0
        let segW = max(16, Int(ceil(cropRect.width * segScale)))
        let segH = max(16, Int(ceil(cropRect.height * segScale)))
        var gray = [UInt8](repeating: 255, count: segW * segH)
        guard let grayCtx = CGContext(
            data: &gray,
            width: segW,
            height: segH,
            bitsPerComponent: 8,
            bytesPerRow: segW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        grayCtx.setFillColor(gray: 1.0, alpha: 1.0)
        grayCtx.fill(CGRect(x: 0, y: 0, width: CGFloat(segW), height: CGFloat(segH)))
        grayCtx.saveGState()
        grayCtx.scaleBy(x: segScale, y: segScale)
        grayCtx.translateBy(x: -cropRect.minX, y: -cropRect.minY)
        page.draw(with: .mediaBox, to: grayCtx)
        grayCtx.restoreGState()

        let segments = extractPageSegments(
            gray: gray,
            segW: segW,
            segH: segH,
            segScale: segScale,
            cropRect: cropRect,
            slices: layout.slices
        )
        guard !segments.isEmpty else { return nil }

        // 2. Compute reflowed 2D placement in logical UI points
        let sideMarginPt: CGFloat = 14.0
        let topBottomMarginPt: CGFloat = 18.0
        let availWidthPt = max(80.0, targetWidthPt - sideMarginPt * 2.0)
        let clampedZoom = max(1.2, min(2.8, zoomMultiplier))

        struct DrawOp {
            let viewRect: CGRect
            let pdfRect: CGRect
            let isWord: Bool
        }

        var drawOps: [DrawOp] = []
        var rowBreakYs: [CGFloat] = []
        var cursorY: CGFloat = topBottomMarginPt

        for (segIdx, seg) in segments.enumerated() {
            switch seg {
            case .figure(let figPDFRect):
                if segIdx > 0 { cursorY += 10.0 }
                let desiredW = min(availWidthPt, figPDFRect.width * clampedZoom)
                let scaleFactor = desiredW / max(1.0, figPDFRect.width)
                let drawH = figPDFRect.height * scaleFactor
                let drawX = sideMarginPt + max(0, (availWidthPt - desiredW) * 0.5)
                let vRect = CGRect(x: drawX, y: cursorY, width: desiredW, height: drawH)
                drawOps.append(DrawOp(viewRect: vRect, pdfRect: figPDFRect, isWord: false))
                cursorY += drawH + 10.0
                rowBreakYs.append(cursorY - 5.0)

            case .textLine(let wordSpecs, let startsParagraph, let baseFontHeightPt):
                guard !wordSpecs.isEmpty else { continue }
                if startsParagraph && segIdx > 0 {
                    cursorY += round(baseFontHeightPt * clampedZoom * 0.52)
                }

                let spacePt = max(4.5, round(baseFontHeightPt * clampedZoom * 0.34))
                let lineLeadingPt = max(5.0, round(baseFontHeightPt * clampedZoom * 0.36))
                let firstIndentPt: CGFloat = startsParagraph ? min(18.0, availWidthPt * 0.06) : 0.0

                struct PendingRowWord {
                    let x: CGFloat
                    let w: CGFloat
                    let h: CGFloat
                    let ascent: CGFloat
                    let pdfRect: CGRect
                }

                var currentRow: [PendingRowWord] = []
                var cursorX = sideMarginPt + firstIndentPt

                func commitCurrentRow() {
                    guard !currentRow.isEmpty else { return }
                    let maxAscent = currentRow.map(\.ascent).max() ?? 0
                    var maxBottom: CGFloat = 0
                    for item in currentRow {
                        let y = cursorY + max(0, maxAscent - item.ascent)
                        let vRect = CGRect(x: item.x, y: y, width: item.w, height: item.h)
                        drawOps.append(DrawOp(viewRect: vRect, pdfRect: item.pdfRect, isWord: true))
                        maxBottom = max(maxBottom, y + item.h - cursorY)
                    }
                    cursorY += maxBottom + lineLeadingPt
                    rowBreakYs.append(cursorY - lineLeadingPt * 0.5)
                    currentRow.removeAll(keepingCapacity: true)
                }

                for spec in wordSpecs {
                    let wordPDF = spec.pdfRect
                    var wPt = wordPDF.width * clampedZoom
                    var hPt = wordPDF.height * clampedZoom
                    var ascPt = spec.ascentPt * clampedZoom
                    if wPt > availWidthPt {
                        let shrink = availWidthPt / wPt
                        wPt = availWidthPt
                        hPt *= shrink
                        ascPt *= shrink
                    }

                    if !currentRow.isEmpty && (cursorX + wPt) > (sideMarginPt + availWidthPt + 0.5) {
                        commitCurrentRow()
                        cursorX = sideMarginPt
                    }

                    currentRow.append(PendingRowWord(x: cursorX, w: wPt, h: hPt, ascent: ascPt, pdfRect: wordPDF))
                    cursorX += wPt + spacePt
                }

                commitCurrentRow()
            }
        }

        let totalHeightPt = max(160.0, ceil(cursorY + topBottomMarginPt))

        // 3. Render crisp high-DPI source crop of tightInkRect once, then blit word sub-images into output canvas
        let outScale = min(2.6, max(2.0, screenScale))
        // Cap output height safely below Quartz limits (max 16384 px)
        let effectiveOutScale = (totalHeightPt * outScale > 14_000) ? (14_000 / totalHeightPt) : outScale
        let srcScale = min(4.0, max(2.6, clampedZoom * effectiveOutScale))

        let srcW = max(16, Int(ceil(cropRect.width * srcScale)))
        let srcH = max(16, Int(ceil(cropRect.height * srcScale)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let srcCtx = CGContext(
            data: nil,
            width: srcW,
            height: srcH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        srcCtx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        srcCtx.fill(CGRect(x: 0, y: 0, width: CGFloat(srcW), height: CGFloat(srcH)))
        srcCtx.interpolationQuality = .high
        srcCtx.saveGState()
        srcCtx.scaleBy(x: srcScale, y: srcScale)
        srcCtx.translateBy(x: -cropRect.minX, y: -cropRect.minY)
        page.draw(with: .mediaBox, to: srcCtx)
        srcCtx.restoreGState()

        guard let srcCGImage = srcCtx.makeImage() else { return nil }

        let outW = max(16, Int(ceil(targetWidthPt * effectiveOutScale)))
        let outH = max(16, Int(ceil(totalHeightPt * effectiveOutScale)))
        guard let outCtx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        outCtx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        outCtx.fill(CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH)))
        outCtx.interpolationQuality = .high

        let pageHighlights = annotations.filter { $0.pageIndex == pageIndex && $0.kind == .highlight }
        var hitBoxes: [PlacedWordHitBox] = []
        hitBoxes.reserveCapacity(drawOps.count)

        for op in drawOps {
            // Map op.pdfRect -> pixel rect in srcCGImage (origin top-left)
            let pxX = (op.pdfRect.minX - cropRect.minX) * srcScale
            let pxY = (cropRect.maxY - op.pdfRect.maxY) * srcScale
            let pxW = op.pdfRect.width * srcScale
            let pxH = op.pdfRect.height * srcScale
            let cropPx = CGRect(x: pxX, y: pxY, width: pxW, height: pxH)
                .integral
                .intersection(CGRect(x: 0, y: 0, width: srcW, height: srcH))
            guard !cropPx.isNull, cropPx.width >= 1, cropPx.height >= 1,
                  let subCG = srcCGImage.cropping(to: cropPx) else { continue }

            // Map top-down op.viewRect -> Quartz bottom-up rect in outCtx
            let destX = op.viewRect.minX * effectiveOutScale
            let destW = op.viewRect.width * effectiveOutScale
            let destH = op.viewRect.height * effectiveOutScale
            let destQuartzY = CGFloat(outH) - (op.viewRect.minY * effectiveOutScale) - destH
            let destRect = CGRect(x: destX, y: destQuartzY, width: destW, height: destH)

            outCtx.draw(subCG, in: destRect)

            // Overlay any saved highlight that covers this word
            if let matchedHighlight = matchingHighlight(for: op.pdfRect, in: pageHighlights) {
                let rgba = highlightRGBAComponents(for: matchedHighlight.color)
                outCtx.saveGState()
                outCtx.setBlendMode(.multiply)
                outCtx.setFillColor(red: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
                outCtx.fill(destRect.insetBy(dx: -1.5, dy: -1.0))
                outCtx.restoreGState()
            }

            if op.isWord {
                hitBoxes.append(PlacedWordHitBox(viewRect: op.viewRect, pdfRect: op.pdfRect))
            }
        }

        guard let finalImage = outCtx.makeImage() else { return nil }
        return VisualReflowedPage(
            cgImage: finalImage,
            logicalSize: CGSize(width: targetWidthPt, height: totalHeightPt),
            pixelScale: effectiveOutScale,
            rowBreakYs: rowBreakYs,
            wordHitBoxes: hitBoxes
        )
    }

    private func extractPageSegments(
        gray: [UInt8],
        segW: Int,
        segH: Int,
        segScale: CGFloat,
        cropRect: CGRect,
        slices: [VisualColumnSlice]
    ) -> [ExtractedSegment] {
        let threshold: UInt8 = 236
        var allSegments: [ExtractedSegment] = []

        for slice in slices {
            let c0 = max(0, min(segW - 1, Int(floor((slice.rect.minX - cropRect.minX) * segScale))))
            let c1 = max(c0, min(segW - 1, Int(ceil((slice.rect.maxX - cropRect.minX) * segScale)) - 1))
            let r0 = max(0, min(segH - 1, Int(floor((cropRect.maxY - slice.rect.maxY) * segScale))))
            let r1 = max(r0, min(segH - 1, Int(ceil((cropRect.maxY - slice.rect.minY) * segScale)) - 1))
            guard c1 > c0 + 6, r1 > r0 + 6 else { continue }

            let dustTol = max(0, (c1 - c0 + 1) / 110)

            // 1. Find raw horizontal ink bands [bandR0...bandR1]
            var rawBands: [(r0: Int, r1: Int)] = []
            var r = r0
            while r <= r1 {
                var dark = 0
                let off = r * segW
                for c in c0...c1 where gray[off + c] < threshold {
                    dark += 1
                    if dark > dustTol { break }
                }
                if dark <= dustTol {
                    r += 1
                    continue
                }
                let startR = r
                while r <= r1 {
                    var d = 0
                    let o = r * segW
                    for c in c0...c1 where gray[o + c] < threshold {
                        d += 1
                        if d > dustTol { break }
                    }
                    if d <= dustTol { break }
                    r += 1
                }
                rawBands.append((startR, r - 1))
            }

            guard !rawBands.isEmpty else { continue }

            // 2. Merge diacritic / dot / accent mini-bands (e.g. i, İ, ö, ü, ğ, ş) into adjacent main line band
            let maxAccentHeightPx = max(2, Int(round(3.6 * segScale)))
            let maxAccentGapPx = max(2, Int(round(2.3 * segScale)))
            var bands: [(r0: Int, r1: Int)] = []
            for b in rawBands {
                if var prev = bands.last {
                    let prevH = prev.r1 - prev.r0 + 1
                    let currH = b.r1 - b.r0 + 1
                    let gap = b.r0 - prev.r1 - 1
                    if gap <= maxAccentGapPx && (prevH <= maxAccentHeightPx || currH <= maxAccentHeightPx) {
                        prev.r1 = b.r1
                        bands[bands.count - 1] = prev
                        continue
                    }
                }
                bands.append(b)
            }

            let normalHeights = bands
                .map { $0.r1 - $0.r0 + 1 }
                .filter { $0 >= Int(4.5 * segScale) && $0 <= Int(24.0 * segScale) }
                .sorted()
            let medianBandH = normalHeights.isEmpty
                ? max(12, Int(11.0 * segScale))
                : normalHeights[normalHeights.count / 2]
            let medianLinePt = CGFloat(medianBandH) / segScale

            // 3. Segment each band into either an intact figure/table OR baseline-aligned words
            var prevBandR1: Int?
            var prevLineLastC1: Int?
            let colWidthPx = max(1, c1 - c0 + 1)

            // Merge consecutive text lines into continuous paragraphs, breaking only on real paragraph boundaries!
            var pendingParagraphWords: [WordSliceSpec] = []
            var pendingFontHeightPt: CGFloat = medianLinePt

            func flushParagraph() {
                guard !pendingParagraphWords.isEmpty else { return }
                allSegments.append(
                    .textLine(
                        words: pendingParagraphWords,
                        startsParagraph: true,
                        baseFontHeightPt: pendingFontHeightPt
                    )
                )
                pendingParagraphWords.removeAll(keepingCapacity: true)
            }

            for band in bands {
                let bandH = band.r1 - band.r0 + 1
                // Ignore 1px horizontal scan-speckle noise
                if bandH < max(2, Int(2.2 * segScale)) { continue }

                // Tall multi-line diagrams, truth tables, proof trees -> keep 100% intact!
                if bandH > Int(Double(medianBandH) * 2.25) {
                    flushParagraph()
                    let figRect = pdfRectForSegBox(
                        c0: c0, c1: c1, r0: band.r0, r1: band.r1,
                        segW: segW, segH: segH, segScale: segScale, cropRect: cropRect, padPt: 2.0
                    )
                    allSegments.append(.figure(pdfRect: figRect))
                    prevBandR1 = band.r1
                    prevLineLastC1 = nil
                    continue
                }

                // Extract horizontal word runs inside [c0...c1] for this line band
                let minWordSpacePx = max(4, Int(round(Double(bandH) * 0.22)))
                var wordCols: [(w0: Int, w1: Int)] = []
                var c = c0
                while c <= c1 {
                    var hasInk = false
                    for rr in band.r0...band.r1 where gray[rr * segW + c] < threshold {
                        hasInk = true
                        break
                    }
                    if !hasInk {
                        c += 1
                        continue
                    }
                    let wStart = c
                    var wEnd = c
                    var whiteRun = 0
                    c += 1
                    while c <= c1 {
                        var colHasInk = false
                        for rr in band.r0...band.r1 where gray[rr * segW + c] < threshold {
                            colHasInk = true
                            break
                        }
                        if colHasInk {
                            wEnd = c
                            whiteRun = 0
                        } else {
                            whiteRun += 1
                            if whiteRun >= minWordSpacePx {
                                break
                            }
                        }
                        c += 1
                    }
                    wordCols.append((wStart, wEnd))
                }

                guard let firstWord = wordCols.first, let lastWord = wordCols.last else { continue }

                // Detect paragraph / display-line breaks from vertical gap, first-line indent, or short previous line
                let vGapPx = prevBandR1.map { band.r0 - $0 - 1 } ?? (medianBandH * 2)
                let leftIndentPx = firstWord.w0 - c0
                let prevRightShortPx = prevLineLastC1.map { c1 - $0 } ?? 0

                let isNewParagraph = pendingParagraphWords.isEmpty
                    || vGapPx > Int(Double(medianBandH) * 0.72)
                    || leftIndentPx > Int(Double(medianBandH) * 0.90)
                    || prevRightShortPx > Int(Double(colWidthPx) * 0.18)
                    || bandH > Int(Double(medianBandH) * 1.25)

                if isNewParagraph && !pendingParagraphWords.isEmpty {
                    flushParagraph()
                }
                if pendingParagraphWords.isEmpty {
                    pendingFontHeightPt = max(7.0, CGFloat(bandH) / segScale)
                }

                // Detect baseline row inside [band.r0 ... band.r1] so words from different original lines align on a flat baseline
                var rowInkCounts = [Int](repeating: 0, count: bandH)
                var maxRowInk = 0
                var peakIdx = 0
                for rr in band.r0...band.r1 {
                    var cnt = 0
                    let off = rr * segW
                    for cc in firstWord.w0...lastWord.w1 where gray[off + cc] < threshold {
                        cnt += 1
                    }
                    let localIdx = rr - band.r0
                    rowInkCounts[localIdx] = cnt
                    if cnt >= maxRowInk {
                        maxRowInk = cnt
                        peakIdx = localIdx
                    }
                }
                var baselineRow = band.r0 + peakIdx
                let baseCutoff = max(1, Int(Double(maxRowInk) * 0.28))
                for localIdx in peakIdx..<bandH where rowInkCounts[localIdx] >= baseCutoff {
                    baselineRow = band.r0 + localIdx
                }
                let bandAscentPt = CGFloat(baselineRow - band.r0 + 1) / segScale + 0.9

                for w in wordCols {
                    let wRect = pdfRectForSegBox(
                        c0: w.w0, c1: w.w1, r0: band.r0, r1: band.r1,
                        segW: segW, segH: segH, segScale: segScale, cropRect: cropRect, padPt: 0.9
                    )
                    pendingParagraphWords.append(WordSliceSpec(pdfRect: wRect, ascentPt: bandAscentPt))
                }

                prevBandR1 = band.r1
                prevLineLastC1 = lastWord.w1
            }

            flushParagraph()
        }

        return allSegments
    }

    private func pdfRectForSegBox(
        c0: Int,
        c1: Int,
        r0: Int,
        r1: Int,
        segW: Int,
        segH: Int,
        segScale: CGFloat,
        cropRect: CGRect,
        padPt: CGFloat
    ) -> CGRect {
        let x0 = cropRect.minX + CGFloat(c0) / segScale - padPt
        let x1 = cropRect.minX + CGFloat(c1 + 1) / segScale + padPt
        let y0 = cropRect.minY + CGFloat(segH - 1 - r1) / segScale - padPt
        let y1 = cropRect.minY + CGFloat(segH - r0) / segScale + padPt
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
            .intersection(cropRect)
    }

    private func matchingHighlight(
        for wordRect: CGRect,
        in annotations: [AnnotationItem]
    ) -> AnnotationItem? {
        for item in annotations {
            for r in item.rects {
                let inter = r.cgRect.intersection(wordRect)
                if !inter.isNull,
                   inter.width >= wordRect.width * 0.32,
                   inter.height >= wordRect.height * 0.30 {
                    return item
                }
            }
        }
        return nil
    }

    private func highlightRGBAComponents(for color: HighlightColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        switch color {
        case .yellow: return (0.98, 0.88, 0.32, 0.55)
        case .blue:   return (0.45, 0.74, 0.98, 0.45)
        case .pink:   return (0.98, 0.54, 0.68, 0.45)
        case .green:  return (0.46, 0.88, 0.58, 0.45)
        case .purple: return (0.76, 0.58, 0.96, 0.45)
        }
    }
}
