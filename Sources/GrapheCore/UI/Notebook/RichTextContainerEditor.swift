import AppKit
import SwiftUI

public enum RichTextFormatAction: Equatable, Sendable {
    case heading1
    case heading2
    case heading3
    case body
    case bold
    case italic
    case underline
    case bulletList
    case numberedList
    case checkbox
    case textColor(NSColor)
    case highlightColor(NSColor?)
    case fontFamily(String)

    public static func == (lhs: RichTextFormatAction, rhs: RichTextFormatAction) -> Bool {
        switch (lhs, rhs) {
        case (.heading1, .heading1), (.heading2, .heading2), (.heading3, .heading3),
             (.body, .body), (.bold, .bold), (.italic, .italic), (.underline, .underline),
             (.bulletList, .bulletList), (.numberedList, .numberedList), (.checkbox, .checkbox):
            return true
        case (.fontFamily(let a), .fontFamily(let b)):
            return a == b
        default:
            return false
        }
    }
}

public struct RichTextFormatCommand: Identifiable {
    public let id = UUID()
    public let targetContainerID: UUID
    public let action: RichTextFormatAction

    public init(targetContainerID: UUID, action: RichTextFormatAction) {
        self.targetContainerID = targetContainerID
        self.action = action
    }
}

public final class GrapheRichTextView: NSTextView {
    public var onPasteImage: ((NSImage) -> Void)?
    public var onFocusGained: (() -> Void)?
    public var placeholderString: String = "" {
        didSet {
            if oldValue != placeholderString {
                needsDisplay = true
            }
        }
    }
    public var placeholderColor: NSColor = .secondaryLabelColor {
        didSet {
            if oldValue != placeholderColor {
                needsDisplay = true
            }
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !placeholderString.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: placeholderColor
            ]
            let padding = textContainer?.lineFragmentPadding ?? 5
            let point = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
            (placeholderString as NSString).draw(at: point, withAttributes: attrs)
        }
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusGained?()
        }
        return ok
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let oldWindowUM = window?.undoManager {
            // Güvenlik ağı: pencereden ayrılırken pencere geçmişinde bize ait kayıt bırakma.
            oldWindowUM.removeAllActions(withTarget: self)
            if let storage = textStorage {
                oldWindowUM.removeAllActions(withTarget: storage)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // If clipboard has an image and NO plain string (e.g. macOS screenshot), route to canvas image container
        let hasString = pb.string(forType: .string)?.isEmpty == false
        if !hasString, let image = NSImage(pasteboard: pb), image.size.width > 1, image.size.height > 1 {
            onPasteImage?(image)
            return
        }
        super.paste(sender)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIdx = characterIndexForInsertion(at: point)
        let nsStr = string as NSString
        if charIdx < nsStr.length {
            let ch = nsStr.substring(with: NSRange(location: charIdx, length: 1))
            if ch == "☐" || ch == "☑" {
                let replacement = ch == "☐" ? "☑" : "☐"
                let range = NSRange(location: charIdx, length: 1)
                if shouldChangeText(in: range, replacementString: replacement) {
                    textStorage?.replaceCharacters(in: range, with: replacement)
                    didChangeText()
                }
                return
            }
        }
        super.mouseDown(with: event)
    }
}

public struct RichTextContainerEditor: NSViewRepresentable {
    public let containerID: UUID
    public let rtfData: Data?
    public let plainText: String
    public let placeholder: String
    public let textColor: NSColor
    public let defaultFontFamily: String
    public let shouldFocus: Bool
    public let formatCommand: RichTextFormatCommand?
    public let onFocus: () -> Void
    public let onContentChanged: (Data?, String) -> Void
    public let onRequiredHeightChanged: ((CGFloat) -> Void)?
    public let onPasteImage: (NSImage) -> Void

    public init(
        containerID: UUID,
        rtfData: Data?,
        plainText: String,
        placeholder: String = "Yazmaya başlayın...",
        textColor: NSColor = .labelColor,
        defaultFontFamily: String = NotebookFontCatalog.systemKey,
        shouldFocus: Bool = false,
        formatCommand: RichTextFormatCommand? = nil,
        onFocus: @escaping () -> Void = {},
        onContentChanged: @escaping (Data?, String) -> Void,
        onRequiredHeightChanged: ((CGFloat) -> Void)? = nil,
        onPasteImage: @escaping (NSImage) -> Void = { _ in }
    ) {
        self.containerID = containerID
        self.rtfData = rtfData
        self.plainText = plainText
        self.placeholder = placeholder
        self.textColor = textColor
        self.defaultFontFamily = defaultFontFamily
        self.shouldFocus = shouldFocus
        self.formatCommand = formatCommand
        self.onFocus = onFocus
        self.onContentChanged = onContentChanged
        self.onRequiredHeightChanged = onRequiredHeightChanged
        self.onPasteImage = onPasteImage
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingPersist()
        coordinator.ownUndoManager.removeAllActions()
        if let tv = coordinator.textView {
            tv.window?.undoManager?.removeAllActions(withTarget: tv)
            if let storage = tv.textStorage {
                tv.window?.undoManager?.removeAllActions(withTarget: storage)
            }
            tv.delegate = nil
        }
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = GrapheRichTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let baseFont = NotebookFontCatalog.nsFont(family: defaultFontFamily, size: 13)
        textView.font = baseFont
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.placeholderString = placeholder
        textView.placeholderColor = textColor.withAlphaComponent(0.38)

        if shouldFocus, !context.coordinator.didAutoFocus {
            context.coordinator.didAutoFocus = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        } else if !shouldFocus {
            context.coordinator.didAutoFocus = false
        }
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: textColor
        ]
        textView.onFocusGained = {
            context.coordinator.parent.onFocus()
        }
        textView.onPasteImage = { image in
            context.coordinator.parent.onPasteImage(image)
        }

        context.coordinator.textView = textView
        loadInitialContent(into: textView)
        context.coordinator.loadedContainerID = containerID
        context.coordinator.lastAppliedInkColor = textColor
        context.coordinator.lastAppliedFontFamily = defaultFontFamily

        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        if context.coordinator.loadedContainerID != containerID {
            context.coordinator.cancelPendingPersist()
            context.coordinator.loadedContainerID = containerID
            loadInitialContent(into: textView)
            context.coordinator.ownUndoManager.removeAllActions()
        }

        if context.coordinator.lastAppliedInkColor != textColor {
            context.coordinator.lastAppliedInkColor = textColor
            adaptNeutralInkColors(in: textView, to: textColor)
        }

        if context.coordinator.lastAppliedFontFamily != defaultFontFamily {
            context.coordinator.lastAppliedFontFamily = defaultFontFamily
            let updatedBase = NotebookFontCatalog.nsFont(family: defaultFontFamily, size: 13)
            var typing = textView.typingAttributes
            typing[.font] = updatedBase
            textView.typingAttributes = typing
            textView.font = updatedBase
            textView.needsDisplay = true
        }

        textView.insertionPointColor = textColor
        textView.placeholderString = placeholder
        textView.placeholderColor = textColor.withAlphaComponent(0.38)

        if shouldFocus, !context.coordinator.didAutoFocus {
            context.coordinator.didAutoFocus = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        } else if !shouldFocus {
            context.coordinator.didAutoFocus = false
        }

        if let cmd = formatCommand,
           cmd.targetContainerID == containerID,
           context.coordinator.lastCommandID != cmd.id {
            context.coordinator.lastCommandID = cmd.id
            context.coordinator.apply(action: cmd.action, on: textView)
        }
    }

    private func loadInitialContent(into textView: NSTextView) {
        if let rtfData,
           let attr = try? NSAttributedString(
               data: rtfData,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ),
           attr.length > 0 {
            textView.textStorage?.setAttributedString(attr)
        } else if !plainText.isEmpty {
            let attr = NSAttributedString(
                string: plainText,
                attributes: [
                    .font: NotebookFontCatalog.nsFont(family: defaultFontFamily, size: 13),
                    .foregroundColor: textColor
                ]
            )
            textView.textStorage?.setAttributedString(attr)
        } else {
            textView.string = ""
        }
        adaptNeutralInkColors(in: textView, to: textColor)
    }

    /// Updates default neutral ink runs (black/white/gray/sepia-brown) to match the current paper theme
    /// while preserving explicit user-chosen colors (red, blue, green, purple).
    private func adaptNeutralInkColors(in textView: NSTextView, to targetColor: NSColor) {
        var typing = textView.typingAttributes
        typing[.foregroundColor] = targetColor
        textView.typingAttributes = typing
        textView.textColor = targetColor

        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard let existing = value as? NSColor else {
                storage.addAttribute(.foregroundColor, value: targetColor, range: range)
                return
            }
            if isNeutralInkColor(existing) {
                storage.addAttribute(.foregroundColor, value: targetColor, range: range)
            }
        }
        storage.endEditing()
    }

    private func isNeutralInkColor(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        let maxC = max(rgb.redComponent, max(rgb.greenComponent, rgb.blueComponent))
        let minC = min(rgb.redComponent, min(rgb.greenComponent, rgb.blueComponent))
        let saturation = maxC > 0.001 ? (maxC - minC) / maxC : 0
        // Treat grays, black, white, and warm dark sepia-brown (low saturation or very dark) as neutral default ink
        if saturation < 0.25 { return true }
        if maxC < 0.30 { return true }
        return false
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextContainerEditor
        weak var textView: GrapheRichTextView?
        var loadedContainerID: UUID?
        var lastCommandID: UUID?
        var lastAppliedInkColor: NSColor?
        var lastAppliedFontFamily: String?
        var didAutoFocus: Bool = false
        private var debounceTask: Task<Void, Never>?
        /// Her kutunun KENDİ geri alma geçmişi. Pencerenin ortak NSUndoManager'ı kullanılmaz;
        /// böylece kutu/editör yok edildiğinde pencerede sahipsiz (dangling) undo kaydı kalmaz.
        let ownUndoManager = UndoManager()

        init(_ parent: RichTextContainerEditor) {
            self.parent = parent
        }

        public func undoManager(for view: NSTextView) -> UndoManager? {
            ownUndoManager
        }

        public func textDidChange(_ notification: Notification) {
            textView?.needsDisplay = true
            schedulePersist()
        }

        public func textDidEndEditing(_ notification: Notification) {
            debounceTask?.cancel()
            debounceTask = nil
            if let tv = textView {
                emitCurrentContent(from: tv)
            }
        }

        func cancelPendingPersist() {
            debounceTask?.cancel()
            debounceTask = nil
        }

        private func schedulePersist() {
            debounceTask?.cancel()
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, let tv = self.textView else { return }
                self.emitCurrentContent(from: tv)
            }
        }

        private func emitCurrentContent(from tv: NSTextView) {
            let plain = tv.string
            let fullRange = NSRange(location: 0, length: (tv.textStorage?.length ?? 0))
            let rtf = try? tv.textStorage?.data(
                from: fullRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            if let layoutManager = tv.layoutManager, let textContainer = tv.textContainer {
                layoutManager.ensureLayout(for: textContainer)
                let usedHeight = layoutManager.usedRect(for: textContainer).height + tv.textContainerInset.height * 2 + 10
                parent.onRequiredHeightChanged?(usedHeight)
            }
            parent.onContentChanged(rtf, plain)
        }

        func apply(action: RichTextFormatAction, on tv: NSTextView) {
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let fontManager = NSFontManager.shared

            let baseFam = parent.defaultFontFamily
            switch action {
            case .heading1:
                applyFont(NotebookFontCatalog.nsFont(family: baseFam, size: 20, weight: .bold), to: tv, lineScope: true)
            case .heading2:
                applyFont(NotebookFontCatalog.nsFont(family: baseFam, size: 16, weight: .semibold), to: tv, lineScope: true)
            case .heading3:
                applyFont(NotebookFontCatalog.nsFont(family: baseFam, size: 14, weight: .semibold), to: tv, lineScope: true)
            case .body:
                applyFont(NotebookFontCatalog.nsFont(family: baseFam, size: 13, weight: .regular), to: tv, lineScope: true)
            case .bold:
                toggleFontTrait(.boldFontMask, on: tv, fontManager: fontManager)
            case .italic:
                toggleFontTrait(.italicFontMask, on: tv, fontManager: fontManager)
            case .underline:
                toggleUnderline(on: tv)
            case .bulletList:
                prefixSelectedLines(with: "• ", on: tv, nsStr: nsStr, selection: sel)
            case .numberedList:
                prefixSelectedLinesNumbered(on: tv, nsStr: nsStr, selection: sel)
            case .checkbox:
                prefixSelectedLines(with: "☐ ", on: tv, nsStr: nsStr, selection: sel)
            case .fontFamily(let family):
                applyFontFamily(family, on: tv, fontManager: fontManager)
            case .textColor(let color):
                if sel.length > 0 {
                    if tv.shouldChangeText(in: sel, replacementString: nil) {
                        tv.textStorage?.addAttribute(.foregroundColor, value: color, range: sel)
                    }
                } else {
                    var attrs = tv.typingAttributes
                    attrs[.foregroundColor] = color
                    tv.typingAttributes = attrs
                }
            case .highlightColor(let color):
                if sel.length > 0 {
                    if tv.shouldChangeText(in: sel, replacementString: nil) {
                        if let color {
                            tv.textStorage?.addAttribute(.backgroundColor, value: color, range: sel)
                        } else {
                            tv.textStorage?.removeAttribute(.backgroundColor, range: sel)
                        }
                    }
                } else {
                    var attrs = tv.typingAttributes
                    attrs[.backgroundColor] = color
                    tv.typingAttributes = attrs
                }
            }

            tv.didChangeText()
            emitCurrentContent(from: tv)
        }

        private func applyFontFamily(_ family: String, on tv: NSTextView, fontManager: NSFontManager) {
            let sel = tv.selectedRange()
            if sel.length == 0 {
                let current = (tv.typingAttributes[.font] as? NSFont) ?? NotebookFontCatalog.nsFont(family: parent.defaultFontFamily, size: 13)
                let traits = fontManager.traits(of: current)
                var updated = NotebookFontCatalog.nsFont(family: family, size: current.pointSize)
                if traits.contains(.boldFontMask) { updated = fontManager.convert(updated, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) { updated = fontManager.convert(updated, toHaveTrait: .italicFontMask) }
                var attrs = tv.typingAttributes
                attrs[.font] = updated
                tv.typingAttributes = attrs
                return
            }
            guard let storage = tv.textStorage,
                  tv.shouldChangeText(in: sel, replacementString: nil) else { return }
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: sel) { val, range, _ in
                let cur = (val as? NSFont) ?? NotebookFontCatalog.nsFont(family: parent.defaultFontFamily, size: 13)
                let traits = fontManager.traits(of: cur)
                var converted = NotebookFontCatalog.nsFont(family: family, size: cur.pointSize)
                if traits.contains(.boldFontMask) { converted = fontManager.convert(converted, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) { converted = fontManager.convert(converted, toHaveTrait: .italicFontMask) }
                storage.addAttribute(.font, value: converted, range: range)
            }
            storage.endEditing()
        }

        private func applyFont(_ font: NSFont, to tv: NSTextView, lineScope: Bool) {
            let sel = tv.selectedRange()
            let targetRange: NSRange
            if sel.length > 0 {
                targetRange = sel
            } else if lineScope, tv.string.count > 0 {
                targetRange = (tv.string as NSString).lineRange(for: sel)
            } else {
                var attrs = tv.typingAttributes
                attrs[.font] = font
                tv.typingAttributes = attrs
                return
            }
            if tv.shouldChangeText(in: targetRange, replacementString: nil) {
                tv.textStorage?.addAttribute(.font, value: font, range: targetRange)
            }
            var attrs = tv.typingAttributes
            attrs[.font] = font
            tv.typingAttributes = attrs
        }

        private func toggleFontTrait(_ trait: NSFontTraitMask, on tv: NSTextView, fontManager: NSFontManager) {
            let sel = tv.selectedRange()
            if sel.length == 0 {
                let current = (tv.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                let hasTrait = fontManager.traits(of: current).contains(trait)
                let updated = hasTrait
                    ? fontManager.convert(current, toNotHaveTrait: trait)
                    : fontManager.convert(current, toHaveTrait: trait)
                var attrs = tv.typingAttributes
                attrs[.font] = updated
                tv.typingAttributes = attrs
                return
            }
            guard let storage = tv.textStorage,
                  tv.shouldChangeText(in: sel, replacementString: nil) else { return }
            let firstFont = (storage.attribute(.font, at: sel.location, effectiveRange: nil) as? NSFont)
                ?? NSFont.systemFont(ofSize: 13)
            let removeTrait = fontManager.traits(of: firstFont).contains(trait)
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: sel) { val, range, _ in
                let f = (val as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                let converted = removeTrait
                    ? fontManager.convert(f, toNotHaveTrait: trait)
                    : fontManager.convert(f, toHaveTrait: trait)
                storage.addAttribute(.font, value: converted, range: range)
            }
            storage.endEditing()
        }

        private func toggleUnderline(on tv: NSTextView) {
            let sel = tv.selectedRange()
            if sel.length == 0 {
                let current = (tv.typingAttributes[.underlineStyle] as? Int) ?? 0
                var attrs = tv.typingAttributes
                attrs[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
                tv.typingAttributes = attrs
                return
            }
            guard let storage = tv.textStorage,
                  tv.shouldChangeText(in: sel, replacementString: nil) else { return }
            let current = (storage.attribute(.underlineStyle, at: sel.location, effectiveRange: nil) as? Int) ?? 0
            let nextVal = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            storage.addAttribute(.underlineStyle, value: nextVal, range: sel)
        }

        private func prefixSelectedLines(with prefix: String, on tv: NSTextView, nsStr: NSString, selection: NSRange) {
            if nsStr.length == 0 {
                tv.insertText(prefix, replacementRange: selection)
                return
            }
            let lineRange = nsStr.lineRange(for: selection)
            let chunk = nsStr.substring(with: lineRange)
            let lines = chunk.components(separatedBy: "\n")
            let transformed = lines.enumerated().map { idx, line -> String in
                if idx == lines.count - 1 && line.isEmpty && chunk.hasSuffix("\n") {
                    return ""
                }
                if line.hasPrefix(prefix) {
                    return String(line.dropFirst(prefix.count))
                }
                return prefix + line
            }.joined(separator: "\n")
            if tv.shouldChangeText(in: lineRange, replacementString: transformed) {
                tv.textStorage?.replaceCharacters(in: lineRange, with: transformed)
            }
        }

        private func prefixSelectedLinesNumbered(on tv: NSTextView, nsStr: NSString, selection: NSRange) {
            if nsStr.length == 0 {
                tv.insertText("1. ", replacementRange: selection)
                return
            }
            let lineRange = nsStr.lineRange(for: selection)
            let chunk = nsStr.substring(with: lineRange)
            let lines = chunk.components(separatedBy: "\n")
            var num = 1
            let transformed = lines.enumerated().map { idx, line -> String in
                if idx == lines.count - 1 && line.isEmpty && chunk.hasSuffix("\n") {
                    return ""
                }
                defer { num += 1 }
                return "\(num). \(line)"
            }.joined(separator: "\n")
            if tv.shouldChangeText(in: lineRange, replacementString: transformed) {
                tv.textStorage?.replaceCharacters(in: lineRange, with: transformed)
            }
        }
    }
}
