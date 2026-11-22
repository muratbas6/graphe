import AppKit
import CoreGraphics
import Foundation
import PDFKit

private final class AutoCropDocumentCache: NSObject {
    var originalCropBoxes: [Int: CGRect]?
    var computedUniformRect: CGRect?
    var referenceMediaBoxSize: CGSize?
}

public final class AutoCropService: @unchecked Sendable {
    private let lock = NSLock()
    /// Weak-keyed cache per PDFDocument so closed documents are automatically reclaimed with zero ABA/leak risk.
    private let documentCaches = NSMapTable<PDFDocument, AutoCropDocumentCache>.weakToStrongObjects()

    public init() {}

    private func cacheUnlocked(for document: PDFDocument) -> AutoCropDocumentCache {
        if let existing = documentCaches.object(forKey: document) {
            return existing
        }
        let created = AutoCropDocumentCache()
        documentCaches.setObject(created, forKey: document)
        return created
    }

    /// Computes a consistent ink bounding box across sampled pages of the document,
    /// leaving generous padding so academic margins disappear cleanly without clipping text.
    public func computeCropRect(
        for document: PDFDocument,
        padding: CGFloat = 18.0
    ) -> CGRect? {
        lock.lock()
        if let cached = documentCaches.object(forKey: document)?.computedUniformRect {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let pageCount = document.pageCount
        guard pageCount > 0 else { return nil }

        // Sample up to 10 representative pages (skipping cover page 0 when document has > 3 pages)
        let sampleIndices: [Int]
        if pageCount <= 10 {
            sampleIndices = Array(0..<pageCount)
        } else {
            let start = 1
            let end = pageCount - 1
            let step = max(1, (end - start) / 9)
            sampleIndices = stride(from: start, through: end, by: step).prefix(10).map { $0 }
        }

        var unionRect: CGRect?
        var referenceMediaBox: CGRect?

        for idx in sampleIndices {
            guard let page = document.page(at: idx) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            if referenceMediaBox == nil {
                referenceMediaBox = mediaBox
            } else if let ref = referenceMediaBox, !sizesRoughlyMatch(mediaBox.size, ref.size) {
                // Skip outlier page sizes (e.g. fold-out landscape maps) when building uniform rect
                continue
            }
            if let inkBox = detectInkBoundingBox(on: page, mediaBox: mediaBox) {
                if let existing = unionRect {
                    unionRect = existing.union(inkBox)
                } else {
                    unionRect = inkBox
                }
            }
        }

        guard let baseBox = referenceMediaBox, let ink = unionRect else {
            return nil
        }

        let padded = ink.insetBy(dx: -padding, dy: -padding).intersection(baseBox)
        // Guard against degenerate dust-speck crops (at least 12% of page dimensions)
        guard !padded.isNull,
              padded.width >= baseBox.width * 0.12,
              padded.height >= baseBox.height * 0.12 else {
            return baseBox
        }

        lock.lock()
        let entry = cacheUnlocked(for: document)
        entry.computedUniformRect = padded
        entry.referenceMediaBoxSize = baseBox.size
        lock.unlock()
        return padded
    }

    /// Applies non-destructive in-memory auto-crop to all pages of the document (never modifies PDF on disk).
    @discardableResult
    public func applyAutoCrop(to document: PDFDocument, padding: CGFloat = 18.0) -> Bool {
        guard let targetRect = computeCropRect(for: document, padding: padding) else {
            return false
        }

        lock.lock()
        let entry = cacheUnlocked(for: document)
        let needsSaveOriginals = entry.originalCropBoxes == nil
        var saved: [Int: CGRect] = entry.originalCropBoxes ?? [:]
        let refSize = entry.referenceMediaBoxSize
        lock.unlock()

        for idx in 0..<document.pageCount {
            guard let page = document.page(at: idx) else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            if needsSaveOriginals {
                saved[idx] = page.bounds(for: .cropBox)
            }
            let effectiveRect: CGRect
            if let refSize, !sizesRoughlyMatch(mediaBox.size, refSize),
               let pageInk = detectInkBoundingBox(on: page, mediaBox: mediaBox) {
                effectiveRect = pageInk.insetBy(dx: -padding, dy: -padding).intersection(mediaBox)
            } else {
                effectiveRect = targetRect.intersection(mediaBox)
            }
            if !effectiveRect.isNull && effectiveRect.width > 40 && effectiveRect.height > 40 {
                page.setBounds(effectiveRect, for: .cropBox)
            }
        }

        if needsSaveOriginals {
            lock.lock()
            cacheUnlocked(for: document).originalCropBoxes = saved
            lock.unlock()
        }
        return true
    }

    /// Restores exact original cropBox bounds for every page in the document.
    public func restoreOriginalMargins(for document: PDFDocument) {
        lock.lock()
        let saved = documentCaches.object(forKey: document)?.originalCropBoxes
        lock.unlock()

        guard let saved else { return }
        for idx in 0..<document.pageCount {
            guard let page = document.page(at: idx) else { continue }
            if let original = saved[idx] {
                page.setBounds(original, for: .cropBox)
            } else {
                page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
            }
        }
    }

    public func evictCache(for document: PDFDocument) {
        lock.lock()
        documentCaches.removeObject(forKey: document)
        lock.unlock()
    }

    private func sizesRoughlyMatch(_ a: CGSize, _ b: CGSize) -> Bool {
        guard a.width > 1, a.height > 1, b.width > 1, b.height > 1 else { return false }
        let wRatio = abs(a.width - b.width) / max(a.width, b.width)
        let hRatio = abs(a.height - b.height) / max(a.height, b.height)
        return wRatio <= 0.15 && hRatio <= 0.15
    }

    // MARK: - Grayscale Ink Detection

    public func detectInkBoundingBox(on page: PDFPage, mediaBox: CGRect) -> CGRect? {
        guard mediaBox.width > 1, mediaBox.height > 1 else { return nil }

        let rotation = ((page.rotation % 360) + 360) % 360
        let displaySize = (rotation == 90 || rotation == 270)
            ? CGSize(width: mediaBox.height, height: mediaBox.width)
            : mediaBox.size

        // Render at low resolution (~180px wide) for ultra-fast (<5ms/page) ink detection
        let scale = min(0.5, 180.0 / displaySize.width)
        let width = max(16, Int(ceil(displaySize.width * scale)))
        let height = max(16, Int(ceil(displaySize.height * scale)))

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
            return nil
        }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let pageTransform = page.transform(for: .mediaBox)
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        if rotation == 0 {
            ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
        } else {
            ctx.concatenate(pageTransform)
        }
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        // Find ink bounds (ignore 2px outer border artifacts common in scanned books)
        let threshold: UInt8 = 240
        let border = 2
        var minX = width
        var maxX = -1
        var minRow = height
        var maxRow = -1

        for row in border..<(height - border) {
            let rowOffset = row * width
            for col in border..<(width - border) {
                if pixels[rowOffset + col] < threshold {
                    if col < minX { minX = col }
                    if col > maxX { maxX = col }
                    if row < minRow { minRow = row }
                    if row > maxRow { maxRow = row }
                }
            }
        }

        guard maxX > minX, maxRow > minRow else {
            return nil
        }

        // CGContext memory row 0 is TOP of image, while display/PDF Y=0 is BOTTOM
        let dispMinX = CGFloat(minX) / scale
        let dispMaxX = CGFloat(maxX + 1) / scale
        let dispMinY = CGFloat(height - 1 - maxRow) / scale
        let dispMaxY = CGFloat(height - minRow) / scale

        if rotation == 0 {
            return CGRect(
                x: mediaBox.minX + dispMinX,
                y: mediaBox.minY + dispMinY,
                width: max(1, dispMaxX - dispMinX),
                height: max(1, dispMaxY - dispMinY)
            )
        } else {
            let dispRect = CGRect(
                x: dispMinX,
                y: dispMinY,
                width: max(1, dispMaxX - dispMinX),
                height: max(1, dispMaxY - dispMinY)
            )
            return dispRect.applying(pageTransform.inverted()).intersection(mediaBox)
        }
    }
}
