import AppKit
import CoreGraphics
import CoreML
import CoreText
import Foundation
import PDFKit
import Vision

public struct OCRTextBlock: Codable, Hashable, Sendable {
    public let text: String
    /// Bounding box in PDF page mediaBox coordinates (origin bottom-left).
    public let rect: HighlightRect

    public init(text: String, rect: HighlightRect) {
        self.text = text
        self.rect = rect
    }
}

public struct OCRPageResult: Codable, Hashable, Sendable {
    public let pageIndex: Int
    public let fullText: String
    public let blocks: [OCRTextBlock]
    public let updatedAt: Date

    public init(
        pageIndex: Int,
        fullText: String,
        blocks: [OCRTextBlock],
        updatedAt: Date = Date()
    ) {
        self.pageIndex = pageIndex
        self.fullText = fullText
        self.blocks = blocks
        self.updatedAt = updatedAt
    }
}

public enum VisionOCRError: Error, LocalizedError {
    case pageRenderFailed
    case documentOpenFailed
    case pdfExportFailed

    public var errorDescription: String? {
        switch self {
        case .pageRenderFailed:
            return "Sayfa OCR için görüntüye dönüştürülemedi."
        case .documentOpenFailed:
            return "PDF dosyası OCR işlemi için açılamadı."
        case .pdfExportFailed:
            return "Aranabilir PDF dışa aktarılamadı."
        }
    }
}

public final class VisionOCRService: @unchecked Sendable {
    public static let defaultLanguages = ["en-US", "tr-TR", "de-DE", "fr-FR"]

    public init() {}

    /// Runs 100% offline Apple Vision accurate text recognition on a single PDFPage.
    public func recognizeText(
        on page: PDFPage,
        pageIndex: Int,
        languages: [String] = VisionOCRService.defaultLanguages,
        renderScale: CGFloat = 2.5
    ) throws -> OCRPageResult {
        let mediaBox = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let pageTransform = page.transform(for: .mediaBox)
        guard let cgImage = renderPageToCGImage(page, mediaBox: mediaBox, scale: renderScale) else {
            throw VisionOCRError.pageRenderFailed
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // Fallback to CPU-only execution if GPU/ANE is unavailable (e.g. headless/sandboxed CLI)
            let cpuRequest = VNRecognizeTextRequest()
            cpuRequest.recognitionLevel = .accurate
            cpuRequest.usesLanguageCorrection = true
            cpuRequest.automaticallyDetectsLanguage = true
            cpuRequest.recognitionLanguages = languages
            if let cpuDevice = MLComputeDevice.allComputeDevices.first(where: {
                if case .cpu = $0 { return true }
                return false
            }) {
                cpuRequest.setComputeDevice(cpuDevice, for: .main)
            }
            try handler.perform([cpuRequest])
            return buildOCRResult(
                from: cpuRequest.results ?? [],
                mediaBox: mediaBox,
                rotation: rotation,
                pageTransform: pageTransform,
                pageIndex: pageIndex
            )
        }

        return buildOCRResult(
            from: request.results ?? [],
            mediaBox: mediaBox,
            rotation: rotation,
            pageTransform: pageTransform,
            pageIndex: pageIndex
        )
    }

    private func buildOCRResult(
        from observations: [VNRecognizedTextObservation],
        mediaBox: CGRect,
        rotation: Int,
        pageTransform: CGAffineTransform,
        pageIndex: Int
    ) -> OCRPageResult {
        var blocks: [OCRTextBlock] = []
        blocks.reserveCapacity(observations.count)
        let displaySize = (rotation == 90 || rotation == 270)
            ? CGSize(width: mediaBox.height, height: mediaBox.width)
            : mediaBox.size
        let inverseTransform = pageTransform.inverted()

        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Vision normalized coordinates have origin at bottom-left, same as display mediaBox
            let box = obs.boundingBox
            let pdfRect: CGRect
            if rotation == 0 {
                pdfRect = CGRect(
                    x: mediaBox.minX + box.origin.x * mediaBox.width,
                    y: mediaBox.minY + box.origin.y * mediaBox.height,
                    width: box.size.width * mediaBox.width,
                    height: box.size.height * mediaBox.height
                )
            } else {
                let dispRect = CGRect(
                    x: box.origin.x * displaySize.width,
                    y: box.origin.y * displaySize.height,
                    width: box.size.width * displaySize.width,
                    height: box.size.height * displaySize.height
                )
                pdfRect = dispRect.applying(inverseTransform)
            }
            blocks.append(OCRTextBlock(text: text, rect: HighlightRect(cgRect: pdfRect)))
        }

        // Sort reading order: top-to-bottom (descending Y), then left-to-right (ascending X)
        blocks.sort { lhs, rhs in
            let yDiff = abs(lhs.rect.y - rhs.rect.y)
            if yDiff > max(lhs.rect.height, rhs.rect.height) * 0.5 {
                return lhs.rect.y > rhs.rect.y
            }
            return lhs.rect.x < rhs.rect.x
        }

        let rawJoined = blocks.map(\.text).joined(separator: "\n")
        let normalizedFullText = PDFTextNormalizer.normalize(rawJoined)

        return OCRPageResult(
            pageIndex: pageIndex,
            fullText: normalizedFullText,
            blocks: blocks
        )
    }

    /// Exports a new searchable PDF file with invisible selectable text layer overlaid at exact OCR coordinates.
    /// The original PDF is never modified.
    public func exportSearchablePDF(
        sourceURL: URL,
        ocrPages: [Int: OCRPageResult],
        destinationURL: URL
    ) throws {
        guard let sourceDoc = PDFDocument(url: sourceURL) else {
            throw VisionOCRError.documentOpenFailed
        }

        let firstBox = sourceDoc.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        var initialMediaBox = firstBox

        guard let ctx = CGContext(destinationURL as CFURL, mediaBox: &initialMediaBox, nil) else {
            throw VisionOCRError.pdfExportFailed
        }

        for pageIndex in 0..<sourceDoc.pageCount {
            guard let page = sourceDoc.page(at: pageIndex) else { continue }
            var mediaBox = page.bounds(for: .mediaBox)
            var cropBox = page.bounds(for: .cropBox)
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size),
                kCGPDFContextCropBox: Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size)
            ]
            ctx.beginPDFPage(pageInfo as CFDictionary)

            // 1. Draw original page untouched
            ctx.saveGState()
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            // 2. Overlay invisible selectable OCR text layer if available for this page
            if let ocrPage = ocrPages[pageIndex] {
                drawInvisibleTextLayer(ocrPage.blocks, in: ctx)
            }

            ctx.endPDFPage()
        }

        ctx.closePDF()

        // 3. Preserve original page rotation, link annotations, and outline (TOC) in exported PDF
        if let exportedDoc = PDFDocument(url: destinationURL) {
            var didModify = false
            for pageIndex in 0..<min(sourceDoc.pageCount, exportedDoc.pageCount) {
                guard let srcPage = sourceDoc.page(at: pageIndex),
                      let dstPage = exportedDoc.page(at: pageIndex) else { continue }
                if srcPage.rotation != 0 {
                    dstPage.rotation = srcPage.rotation
                    didModify = true
                }
                for ann in srcPage.annotations where ann.type == "Link" {
                    let cloned = PDFAnnotation(bounds: ann.bounds, forType: .link, withProperties: nil)
                    if let dest = ann.destination,
                       let destPage = dest.page {
                        let targetIdx = sourceDoc.index(for: destPage)
                        if targetIdx != NSNotFound, let dstTarget = exportedDoc.page(at: targetIdx) {
                            cloned.destination = PDFDestination(page: dstTarget, at: dest.point)
                            dstPage.addAnnotation(cloned)
                            didModify = true
                        }
                    } else if let urlAction = ann.action as? PDFActionURL, let url = urlAction.url {
                        cloned.action = PDFActionURL(url: url)
                        dstPage.addAnnotation(cloned)
                        didModify = true
                    } else if let gotoAction = ann.action as? PDFActionGoTo,
                              let destPage = gotoAction.destination.page {
                        let targetIdx = sourceDoc.index(for: destPage)
                        if targetIdx != NSNotFound, let dstTarget = exportedDoc.page(at: targetIdx) {
                            cloned.action = PDFActionGoTo(destination: PDFDestination(page: dstTarget, at: gotoAction.destination.point))
                            dstPage.addAnnotation(cloned)
                            didModify = true
                        }
                    }
                }
            }
            if let srcRoot = sourceDoc.outlineRoot,
               let clonedRoot = cloneOutline(srcRoot, from: sourceDoc, to: exportedDoc) {
                exportedDoc.outlineRoot = clonedRoot
                didModify = true
            }
            if didModify {
                exportedDoc.write(to: destinationURL)
            }
        }
    }

    private func cloneOutline(
        _ node: PDFOutline,
        from sourceDoc: PDFDocument,
        to targetDoc: PDFDocument
    ) -> PDFOutline? {
        let copy = PDFOutline()
        copy.label = node.label
        if let dest = node.destination ?? (node.action as? PDFActionGoTo)?.destination,
           let srcPage = dest.page {
            let idx = sourceDoc.index(for: srcPage)
            if idx != NSNotFound, let dstPage = targetDoc.page(at: idx) {
                copy.destination = PDFDestination(page: dstPage, at: dest.point)
            }
        }
        for i in 0..<node.numberOfChildren {
            if let child = node.child(at: i),
               let clonedChild = cloneOutline(child, from: sourceDoc, to: targetDoc) {
                copy.insertChild(clonedChild, at: copy.numberOfChildren)
            }
        }
        return copy
    }

    /// High-magnification (8x), language-correction-free Vision OCR on tight single-line patches around a click point.
    /// Designed specifically to read tiny 5-6pt superscript footnote markers (e.g. `.⁷` misread as `.'` or `¹` as `I`).
    /// Pass `earlyStop` to stop immediately as soon as a valid footnote marker resolves (skips remaining crops).
    public func recognizeMicroSuperscript(
        at pagePoint: CGPoint,
        on page: PDFPage,
        earlyStop: ((String) -> Bool)? = nil
    ) -> [String] {
        let mediaBox = page.bounds(for: .mediaBox)
        let lineBounds = page.selectionForLine(at: pagePoint)?.bounds(for: page)
        let hasValidLine = lineBounds.map { !$0.isEmpty && $0.height >= 4 && $0.height <= 28 } ?? false

        let crops: [CGRect]
        if let lb = lineBounds, hasValidLine {
            // Clip vertically to the exact clicked text line so adjacent lines above/below never pollute OCR.
            let vMin = lb.minY - 1.5
            let vMax = lb.maxY + 2.5
            let supMinY = max(lb.minY + lb.height * 0.18, pagePoint.y - 4.0)
            crops = [
                // 1) Isolated superscript patch centered on click (reads pure `7`, `12`, `*`, etc.)
                CGRect(x: pagePoint.x - 4.5, y: supMinY, width: 9.5, height: max(6.0, vMax - supMinY)),
                // 2) Left-biased single-line patch (captures preceding word/date + superscript, e.g. `-20.⁷`, excluding next word)
                CGRect(x: pagePoint.x - 22.0, y: vMin, width: 27.0, height: max(8.0, vMax - vMin)),
                // 3) Centered single-line patch (forgiving of ±5pt horizontal click offset)
                CGRect(x: pagePoint.x - 12.0, y: vMin, width: 24.0, height: max(8.0, vMax - vMin))
            ]
        } else {
            // Pure scanned page without PDF text layer
            crops = [
                CGRect(x: pagePoint.x - 5.0, y: pagePoint.y - 3.0, width: 11.0, height: 10.0),
                CGRect(x: pagePoint.x - 20.0, y: pagePoint.y - 5.0, width: 26.0, height: 13.0),
                CGRect(x: pagePoint.x - 12.0, y: pagePoint.y - 5.0, width: 24.0, height: 14.0)
            ]
        }

        var candidates: [String] = []
        for rawCrop in crops {
            let clamped = rawCrop.intersection(mediaBox)
            guard !clamped.isNull, clamped.width >= 4, clamped.height >= 4 else { continue }
            guard let cgImage = renderPaddedCropToCGImage(page, cropRect: clamped, scale: 8.0, quietZonePx: 32) else {
                continue
            }

            let observations = performMicroRecognition(on: cgImage)
            for obs in observations {
                for cand in obs.topCandidates(3) {
                    let s = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty && !candidates.contains(s) {
                        candidates.append(s)
                        if earlyStop?(s) == true {
                            return candidates
                        }
                    }
                }
            }
        }
        return candidates
    }

    private func performMicroRecognition(on cgImage: CGImage) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.05
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            // Fallback to CPU-only execution if GPU/ANE is unavailable
            let cpuRequest = VNRecognizeTextRequest()
            cpuRequest.recognitionLevel = .accurate
            cpuRequest.usesLanguageCorrection = false
            cpuRequest.minimumTextHeight = 0.05
            cpuRequest.recognitionLanguages = ["en-US"]
            if let cpuDevice = MLComputeDevice.allComputeDevices.first(where: {
                if case .cpu = $0 { return true }
                return false
            }) {
                cpuRequest.setComputeDevice(cpuDevice, for: .main)
            }
            do {
                try handler.perform([cpuRequest])
                return cpuRequest.results ?? []
            } catch {
                return []
            }
        }
    }

    // MARK: - Private Helpers

    private func renderPaddedCropToCGImage(
        _ page: PDFPage,
        cropRect: CGRect,
        scale: CGFloat,
        quietZonePx: Int
    ) -> CGImage? {
        let rotation = ((page.rotation % 360) + 360) % 360
        let pageTransform = page.transform(for: .mediaBox)
        let displayCrop = rotation == 0 ? cropRect : cropRect.applying(pageTransform)
        guard displayCrop.width > 0.5, displayCrop.height > 0.5 else { return nil }

        let contentW = max(1, Int(ceil(displayCrop.width * scale)))
        let contentH = max(1, Int(ceil(displayCrop.height * scale)))
        let totalW = contentW + quietZonePx * 2
        let totalH = contentH + quietZonePx * 2

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: totalW,
            height: totalH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))

        ctx.saveGState()
        ctx.clip(to: CGRect(x: quietZonePx, y: quietZonePx, width: contentW, height: contentH))
        ctx.translateBy(x: CGFloat(quietZonePx), y: CGFloat(quietZonePx))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -displayCrop.minX, y: -displayCrop.minY)
        if rotation != 0 {
            ctx.concatenate(pageTransform)
        }
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private func renderPageToCGImage(_ page: PDFPage, mediaBox: CGRect, scale: CGFloat) -> CGImage? {
        guard mediaBox.width > 1, mediaBox.height > 1 else { return nil }
        let rotation = ((page.rotation % 360) + 360) % 360
        let displaySize = (rotation == 90 || rotation == 270)
            ? CGSize(width: mediaBox.height, height: mediaBox.width)
            : mediaBox.size
        let pixelWidth = max(1, Int(ceil(displaySize.width * scale)))
        let pixelHeight = max(1, Int(ceil(displaySize.height * scale)))

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

        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        if rotation == 0 {
            ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
        } else {
            ctx.concatenate(page.transform(for: .mediaBox))
        }
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private func drawInvisibleTextLayer(_ blocks: [OCRTextBlock], in ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)

        for block in blocks {
            let rect = block.rect.cgRect
            guard rect.width > 1, rect.height > 1 else { continue }

            let fontSize = max(4.0, rect.height * 0.85)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
            let attrStr = NSAttributedString(string: block.text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)

            let scaleX: CGFloat = lineWidth > 1 ? max(0.25, min(4.0, rect.width / CGFloat(lineWidth))) : 1.0

            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(
                a: scaleX, b: 0,
                c: 0, d: 1,
                tx: rect.minX, ty: rect.minY + rect.height * 0.15
            )
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        ctx.restoreGState()
    }
}
