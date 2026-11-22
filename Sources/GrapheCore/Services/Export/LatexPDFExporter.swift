import AppKit
import Foundation

public enum LatexExportScope: Equatable, Sendable {
    case fullNotebook
    case singlePage(UUID)
}

public enum LatexExportError: LocalizedError, Sendable {
    case engineNotFound
    case compilationFailed(logTail: String)
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .engineNotFound:
            return "Sistemde LaTeX motoru (xelatex) bulunamadı. PDF üretebilmek için MacTeX/BasicTeX kurulu olmalı veya menüden '.tex Kaynağını Kaydet' seçeneğini kullanabilirsiniz."
        case .compilationFailed(let logTail):
            let trimmed = logTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "LaTeX PDF derlemesi başarısız oldu."
            }
            return "LaTeX PDF derlemesi başarısız oldu:\n\(trimmed)"
        case .emptyDocument:
            return "Dışa aktarılacak not veya vurgu bulunamadı."
        }
    }
}

public struct LatexBuildArtifact: Sendable {
    public let texSource: String
    public let imageFiles: [(sourcePath: String, assetName: String)]

    public init(texSource: String, imageFiles: [(sourcePath: String, assetName: String)]) {
        self.texSource = texSource
        self.imageFiles = imageFiles
    }
}

public struct LatexPDFExporter: Sendable {
    public init() {}

    /// Finds `xelatex` (preferred for full Turkish & Unicode support) on macOS.
    public static func findXeLaTeXExecutable() -> URL? {
        let candidates = [
            "/Library/TeX/texbin/xelatex",
            "/usr/local/texlive/2026/bin/universal-darwin/xelatex",
            "/usr/local/texlive/2025/bin/universal-darwin/xelatex",
            "/usr/local/texlive/2024/bin/universal-darwin/xelatex",
            "/opt/homebrew/bin/xelatex",
            "/usr/local/bin/xelatex"
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("xelatex").path
                if fm.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    /// Generates clean, classic academic LaTeX source (`.tex`) for a book's notebook (falling back to highlights if notebook is empty).
    public func generateLatex(
        document: LibraryDocumentRecord,
        sections: [NotebookSection],
        pagesBySection: [UUID: [NotebookPage]],
        containersByPage: [UUID: [NoteContainer]],
        fallbackAnnotations: [AnnotationItem] = [],
        scope: LatexExportScope = .fullNotebook,
        preferredFontFamily: String? = nil,
        exportDate: Date = Date()
    ) -> LatexBuildArtifact {
        var imageFiles: [(sourcePath: String, assetName: String)] = []
        var imageCounter = 0

        let filteredSections: [NotebookSection]
        let filteredPagesBySection: [UUID: [NotebookPage]]
        switch scope {
        case .fullNotebook:
            filteredSections = sections
            filteredPagesBySection = pagesBySection
        case .singlePage(let targetPageID):
            var matchedSections: [NotebookSection] = []
            var matchedPages: [UUID: [NotebookPage]] = [:]
            for sec in sections {
                let pages = (pagesBySection[sec.id] ?? []).filter { $0.id == targetPageID }
                if !pages.isEmpty {
                    matchedSections.append(sec)
                    matchedPages[sec.id] = pages
                }
            }
            filteredSections = matchedSections
            filteredPagesBySection = matchedPages
        }

        let hasAnyContainer = filteredSections.contains { sec in
            (filteredPagesBySection[sec.id] ?? []).contains { page in
                !(containersByPage[page.id] ?? []).isEmpty
            }
        }

        let useFallbackAnnotations = !hasAnyContainer && !fallbackAnnotations.isEmpty && scope == .fullNotebook

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "tr_TR")
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .none
        let dateText = dateFormatter.string(from: exportDate)

        var subtitleParts: [String] = []
        if let publisher = document.publisher?.trimmingCharacters(in: .whitespacesAndNewlines), !publisher.isEmpty {
            subtitleParts.append(publisher)
        }
        if let year = document.year {
            subtitleParts.append("\(year)")
        }
        subtitleParts.append(dateText)

        let escapedTitle = Self.escapeLaTeX(document.title)
        let headerTitle = Self.escapeLaTeX(Self.truncate(document.title, maxLength: 68))

        let fontSetupLine: String
        if let fam = preferredFontFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fam.isEmpty,
           fam != NotebookFontCatalog.systemKey {
            let safeFont = fam.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            fontSetupLine = "\\IfFontExistsTF{\(safeFont)}{\\setmainfont{\(safeFont)}}{\\IfFontExistsTF{Palatino}{\\setmainfont{Palatino}}{\\IfFontExistsTF{Georgia}{\\setmainfont{Georgia}}{}}}"
        } else {
            fontSetupLine = "\\IfFontExistsTF{Palatino}{\\setmainfont{Palatino}}{\\IfFontExistsTF{Georgia}{\\setmainfont{Georgia}}{}}"
        }

        var out: [String] = []
        out.append("""
\\documentclass[11pt,a4paper]{article}
\\usepackage[top=2.5cm, bottom=2.5cm, left=2.7cm, right=2.7cm]{geometry}
\\usepackage{fontspec}
\(fontSetupLine)
\\usepackage{parskip}
\\usepackage{xcolor}
\\usepackage{framed}
\\usepackage{graphicx}
\\usepackage{amssymb}
\\usepackage{fancyhdr}
\\usepackage{lastpage}
\\usepackage{titlesec}
\\usepackage[hidelinks]{hyperref}
""")
        out.append(#"""

\definecolor{grapheInk}{HTML}{1A1A1A}
\definecolor{grapheMuted}{HTML}{666666}
\definecolor{grapheRule}{HTML}{D4D4D4}
\definecolor{grapheQuoteBar}{HTML}{B0B0B0}

\color{grapheInk}
\linespread{1.18}
\setlength{\parindent}{0pt}
\setlength{\parskip}{0.55em}

\titleformat{\section}{\Large\bfseries\color{grapheInk}}{}{0pt}{}[\vspace{2pt}{\color{grapheRule}\titlerule[0.4pt]}]
\titleformat{\subsection}{\large\bfseries\color{grapheInk}}{}{0pt}{}
\titleformat{\subsubsection}{\normalsize\bfseries\color{grapheInk}}{}{0pt}{}
\titlespacing*{\section}{0pt}{1.6em}{0.6em}
\titlespacing*{\subsection}{0pt}{1.2em}{0.4em}

\newenvironment{graphequote}{%
  \def\FrameCommand{{\color{grapheQuoteBar}\vrule width 1.6pt}\hspace{10pt}}%
  \MakeFramed{\advance\hsize-\width \FrameRestore}%
  \small\color{grapheInk}%
}{%
  \endMakeFramed%
}

\pagestyle{fancy}
\fancyhf{}
\renewcommand{\headrulewidth}{0.4pt}
\renewcommand{\headrule}{\hbox to\headwidth{\color{grapheRule}\leaders\hrule height \headrulewidth\hfill}}
\fancyhead[L]{\footnotesize\color{grapheMuted}\textit{\grapheHeaderTitle}}
\fancyfoot[C]{\footnotesize\color{grapheMuted}\thepage\ / \pageref{LastPage}}
\fancypagestyle{plain}{%
  \fancyhf{}%
  \renewcommand{\headrulewidth}{0pt}%
  \fancyfoot[C]{\footnotesize\color{grapheMuted}\thepage\ / \pageref{LastPage}}%
}

\renewcommand{\contentsname}{İçindekiler}
"""#)

        out.append("\\newcommand{\\grapheHeaderTitle}{\(headerTitle)}")
        out.append("")
        out.append("\\begin{document}")
        out.append("\\thispagestyle{plain}")
        out.append("")

        // Clean academic title header block
        out.append("{\\LARGE\\bfseries \(escapedTitle)}\\par")
        if let author = document.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            out.append("\\vspace{0.25em}")
            out.append("{\\large\\color{grapheMuted} \(Self.escapeLaTeX(author))}\\par")
        }
        out.append("\\vspace{0.2em}")
        out.append("{\\small\\color{grapheMuted} \(Self.escapeLaTeX(subtitleParts.joined(separator: " · ")))}\\par")
        out.append("\\vspace{0.6em}")
        out.append("{\\color{grapheRule}\\hrule height 0.6pt}")
        out.append("\\vspace{1.0em}")
        out.append("")

        // Table of contents when there are 2+ sections
        if !useFallbackAnnotations && filteredSections.count >= 2 {
            out.append("{\\small\\tableofcontents}")
            out.append("\\vspace{0.8em}")
            out.append("{\\color{grapheRule}\\hrule height 0.4pt}")
            out.append("\\vspace{1.0em}")
            out.append("")
        }

        if useFallbackAnnotations {
            let sorted = fallbackAnnotations.sorted {
                if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
                return $0.createdAt < $1.createdAt
            }
            let grouped = Dictionary(grouping: sorted, by: \.pageIndex)
            for pageIndex in grouped.keys.sorted() {
                guard let items = grouped[pageIndex], !items.isEmpty else { continue }
                out.append("\\section*{Sayfa \(pageIndex + 1)}")
                for item in items {
                    if item.kind == .highlight {
                        let q = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !q.isEmpty {
                            out.append("\\begin{graphequote}")
                            out.append("{\\footnotesize\\color{grapheMuted}[s. \(pageIndex + 1) · \(Self.escapeLaTeX(item.color.meaningLabel))]}\\par")
                            out.append("\\vspace{0.2em}")
                            out.append(Self.convertPlainTextToLaTeX(q))
                            out.append("\\end{graphequote}")
                        }
                        let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !note.isEmpty {
                            out.append(Self.convertPlainTextToLaTeX(note))
                            out.append("")
                        }
                    } else {
                        let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !note.isEmpty {
                            out.append(Self.convertPlainTextToLaTeX(note))
                            out.append("")
                        }
                    }
                }
            }
        } else if !hasAnyContainer {
            out.append("{\\color{grapheMuted}\\textit{Bu belge için henüz not veya vurgu eklenmemiş.}}")
        } else {
            let showSectionHeaders = filteredSections.count > 1 || (filteredSections.first?.title != "Genel Notlar")
            for section in filteredSections {
                let pages = filteredPagesBySection[section.id] ?? []
                let nonEmptyPages = pages.filter { !(containersByPage[$0.id] ?? []).isEmpty }
                if nonEmptyPages.isEmpty { continue }

                if showSectionHeaders {
                    out.append("\\section{\(Self.escapeLaTeX(section.title))}")
                    out.append("")
                }

                let showPageHeaders = nonEmptyPages.count > 1 || (nonEmptyPages.first?.title != "Sayfa 1") || !showSectionHeaders
                for page in nonEmptyPages {
                    if showPageHeaders {
                        let cmd = showSectionHeaders ? "\\subsection" : "\\section"
                        out.append("\(cmd){\(Self.escapeLaTeX(page.title))}")
                        out.append("")
                    }

                    let rawContainers = containersByPage[page.id] ?? []
                    let rows = Self.groupContainersIntoRows(rawContainers)

                    for row in rows {
                        if row.count == 1, let container = row.first {
                            let block = renderContainerBlock(
                                container,
                                inColumn: false,
                                imageFiles: &imageFiles,
                                imageCounter: &imageCounter
                            )
                            if !block.isEmpty {
                                out.append(block)
                                out.append("")
                            }
                        } else if row.count > 1 {
                            // Side-by-side layout matching the user's OneNote 2D canvas arrangement
                            let totalWidth = max(1.0, row.reduce(0.0) { $0 + max(120.0, $1.width) })
                            let gapFraction = 0.03
                            let availableFraction = max(0.5, 1.0 - gapFraction * Double(row.count - 1))

                            var columnBlocks: [(fraction: Double, body: String)] = []
                            for container in row {
                                let body = renderContainerBlock(
                                    container,
                                    inColumn: true,
                                    imageFiles: &imageFiles,
                                    imageCounter: &imageCounter
                                )
                                if !body.isEmpty {
                                    let rawRatio = max(120.0, container.width) / totalWidth
                                    columnBlocks.append((fraction: rawRatio, body: body))
                                }
                            }

                            if columnBlocks.count == 1, let only = columnBlocks.first {
                                out.append(only.body)
                                out.append("")
                            } else if columnBlocks.count > 1 {
                                let sumRatios = max(0.01, columnBlocks.reduce(0.0) { $0 + $1.fraction })
                                out.append("\\noindent")
                                for (idx, col) in columnBlocks.enumerated() {
                                    let widthFrac = max(0.18, (col.fraction / sumRatios) * availableFraction)
                                    let widthStr = String(format: "%.3f", widthFrac)
                                    out.append("\\begin{minipage}[t]{\(widthStr)\\linewidth}")
                                    out.append("\\vspace{0pt}")
                                    out.append(col.body)
                                    out.append("\\end{minipage}%")
                                    if idx < columnBlocks.count - 1 {
                                        out.append("\\hfill%")
                                    }
                                }
                                out.append("")
                                out.append("\\vspace{0.7em}")
                                out.append("")
                            }
                        }
                    }
                }
            }
        }

        out.append("")
        out.append("\\end{document}")
        out.append("")

        return LatexBuildArtifact(
            texSource: out.joined(separator: "\n"),
            imageFiles: imageFiles
        )
    }

    // MARK: - 2D Canvas Row Grouping & Container Rendering

    /// Groups OneNote containers whose vertical intervals overlap into horizontal rows (sorted left-to-right),
    /// preserving side-by-side placements from the freeform canvas in the exported LaTeX PDF.
    public static func groupContainersIntoRows(_ containers: [NoteContainer]) -> [[NoteContainer]] {
        let sorted = containers.sorted { lhs, rhs in
            if abs(lhs.y - rhs.y) > 4 { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }
        var rows: [(minY: Double, maxY: Double, items: [NoteContainer])] = []

        for item in sorted {
            let itemTop = item.y
            let itemBottom = item.y + max(40.0, item.height)

            if let idx = rows.firstIndex(where: { row in
                let overlapTop = max(row.minY, itemTop)
                let overlapBottom = min(row.maxY, itemBottom)
                let overlap = overlapBottom - overlapTop
                let minHeight = min(row.maxY - row.minY, itemBottom - itemTop)
                // Treat as same horizontal row if vertical spans overlap meaningfully (or tops are within 36pt)
                return overlap > minHeight * 0.25 || abs(row.minY - itemTop) <= 36
            }) {
                rows[idx].items.append(item)
                rows[idx].minY = min(rows[idx].minY, itemTop)
                rows[idx].maxY = max(rows[idx].maxY, itemBottom)
            } else {
                rows.append((minY: itemTop, maxY: itemBottom, items: [item]))
            }
        }

        return rows
            .sorted { $0.minY < $1.minY }
            .map { $0.items.sorted { $0.x < $1.x } }
    }

    private func renderContainerBlock(
        _ container: NoteContainer,
        inColumn: Bool,
        imageFiles: inout [(sourcePath: String, assetName: String)],
        imageCounter: inout Int
    ) -> String {
        var lines: [String] = []
        switch container.kind {
        case .pdfQuote:
            let quote = container.quoteText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !quote.isEmpty {
                if inColumn {
                    // Inside a minipage, use a lightweight left-bordered parbox-safe layout (MakeFramed cannot nest in minipage)
                    lines.append("{\\footnotesize\\color{grapheMuted}\(container.sourcePageIndex.map { "[s. \($0 + 1)]" } ?? "[Alıntı]")}\\par")
                    lines.append("\\vspace{0.15em}")
                    lines.append("\\begingroup\\small\\leftskip=8pt\\color{grapheInk}\\textit{\(Self.convertPlainTextToLaTeX(quote))}\\par\\endgroup")
                } else {
                    lines.append("\\begin{graphequote}")
                    if let srcPage = container.sourcePageIndex {
                        lines.append("{\\footnotesize\\color{grapheMuted}[s. \(srcPage + 1)]}\\par")
                        lines.append("\\vspace{0.15em}")
                    }
                    lines.append(Self.convertPlainTextToLaTeX(quote))
                    lines.append("\\end{graphequote}")
                }
            }
            let bodyTex = Self.convertRichContentToLaTeX(rtfData: container.rtfData, plainText: container.plainText)
            if !bodyTex.isEmpty {
                if !lines.isEmpty { lines.append("\\vspace{0.3em}") }
                lines.append(bodyTex)
            }

        case .richText:
            let bodyTex = Self.convertRichContentToLaTeX(rtfData: container.rtfData, plainText: container.plainText)
            if !bodyTex.isEmpty {
                lines.append(bodyTex)
            }

        case .image:
            if let path = container.imagePath, FileManager.default.fileExists(atPath: path) {
                imageCounter += 1
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                let safeExt = ["png", "jpg", "jpeg", "pdf"].contains(ext) ? ext : "png"
                let assetName = String(format: "img_%03d.%@", imageCounter, safeExt)
                imageFiles.append((sourcePath: path, assetName: assetName))
                if inColumn {
                    lines.append("\\includegraphics[width=\\linewidth,height=0.38\\textheight,keepaspectratio]{\(assetName)}")
                } else {
                    lines.append("\\begin{center}")
                    lines.append("\\includegraphics[width=0.88\\linewidth,height=0.45\\textheight,keepaspectratio]{\(assetName)}")
                    lines.append("\\end{center}")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Compiles generated LaTeX source into a PDF using `xelatex` (2 passes for TOC & LastPage) off the main thread.
    public func compileToPDF(
        artifact: LatexBuildArtifact,
        outputPDFURL: URL
    ) async throws {
        guard let xelatexURL = Self.findXeLaTeXExecutable() else {
            throw LatexExportError.engineNotFound
        }

        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let workDir = fm.temporaryDirectory
                .appendingPathComponent("graphe-latex-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(at: workDir)
            }

            let texURL = workDir.appendingPathComponent("document.tex")
            try artifact.texSource.write(to: texURL, atomically: true, encoding: .utf8)

            for img in artifact.imageFiles {
                let dst = workDir.appendingPathComponent(img.assetName)
                if fm.fileExists(atPath: img.sourcePath) {
                    try? fm.copyItem(at: URL(fileURLWithPath: img.sourcePath), to: dst)
                }
            }

            // Run 2 passes so \tableofcontents and \pageref{LastPage} resolve accurately.
            var lastOutput = ""
            for _ in 0..<2 {
                let process = Process()
                process.executableURL = xelatexURL
                process.currentDirectoryURL = workDir
                process.arguments = [
                    "-interaction=nonstopmode",
                    "-halt-on-error",
                    "document.tex"
                ]
                var env = ProcessInfo.processInfo.environment
                let texBin = xelatexURL.deletingLastPathComponent().path
                env["PATH"] = "\(texBin):/usr/local/bin:/usr/bin:/bin"
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                lastOutput = String(data: data, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    let errorLines = lastOutput
                        .components(separatedBy: .newlines)
                        .filter { $0.hasPrefix("!") || $0.contains("Error") || $0.contains("l.") }
                        .suffix(12)
                        .joined(separator: "\n")
                    let tail = errorLines.isEmpty
                        ? lastOutput.components(separatedBy: .newlines).suffix(12).joined(separator: "\n")
                        : errorLines
                    throw LatexExportError.compilationFailed(logTail: tail)
                }
            }

            let builtPDF = workDir.appendingPathComponent("document.pdf")
            guard fm.fileExists(atPath: builtPDF.path) else {
                throw LatexExportError.compilationFailed(logTail: "document.pdf oluşturulamadı.")
            }

            if fm.fileExists(atPath: outputPDFURL.path) {
                try fm.removeItem(at: outputPDFURL)
            }
            try fm.copyItem(at: builtPDF, to: outputPDFURL)
        }.value
    }

    // MARK: - Rich Text (RTF) & Plain Text -> LaTeX Conversion

    public static func convertRichContentToLaTeX(rtfData: Data?, plainText: String) -> String {
        if let data = rtfData,
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil),
           !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return convertAttributedStringToLaTeX(attributed)
        }
        let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return convertPlainTextToLaTeX(trimmed)
    }

    private static func convertAttributedStringToLaTeX(_ attributed: NSAttributedString) -> String {
        let fullStr = attributed.string as NSString
        guard fullStr.length > 0 else { return "" }

        var rawLines: [(range: NSRange, text: String)] = []
        var idx = 0
        while idx < fullStr.length {
            let lineRange = fullStr.lineRange(for: NSRange(location: idx, length: 0))
            let rawLine = fullStr.substring(with: lineRange)
                .trimmingCharacters(in: CharacterSet.newlines)
            let contentRange = NSRange(location: lineRange.location, length: (rawLine as NSString).length)
            rawLines.append((range: contentRange, text: rawLine))
            idx = NSMaxRange(lineRange)
        }

        enum ListKind { case none, bullet, numbered }
        var currentList: ListKind = .none
        var output: [String] = []

        func closeListIfNeeded() {
            switch currentList {
            case .bullet: output.append("\\end{itemize}")
            case .numbered: output.append("\\end{enumerate}")
            case .none: break
            }
            currentList = .none
        }

        for entry in rawLines {
            let trimmed = entry.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                closeListIfNeeded()
                if output.last != "" {
                    output.append("")
                }
                continue
            }

            // Bullet list ("• " or "- ")
            if let prefixLen = bulletPrefixLength(in: entry.text) {
                if currentList != .bullet {
                    closeListIfNeeded()
                    output.append("\\begin{itemize}")
                    currentList = .bullet
                }
                let subRange = NSRange(
                    location: entry.range.location + prefixLen,
                    length: max(0, entry.range.length - prefixLen)
                )
                let itemTex = renderInlineRuns(attributed, in: subRange)
                output.append("  \\item \(itemTex)")
                continue
            }

            // Numbered list ("1. ", "2. ", ...)
            if let prefixLen = numberedPrefixLength(in: entry.text) {
                if currentList != .numbered {
                    closeListIfNeeded()
                    output.append("\\begin{enumerate}")
                    currentList = .numbered
                }
                let subRange = NSRange(
                    location: entry.range.location + prefixLen,
                    length: max(0, entry.range.length - prefixLen)
                )
                let itemTex = renderInlineRuns(attributed, in: subRange)
                output.append("  \\item \(itemTex)")
                continue
            }

            closeListIfNeeded()

            // Detect H1/H2/H3 by dominant font size on the line
            var maxFontSize: CGFloat = 13
            var isWholeLineBold = true
            attributed.enumerateAttributes(in: entry.range, options: []) { attrs, _, _ in
                if let font = attrs[.font] as? NSFont {
                    maxFontSize = max(maxFontSize, font.pointSize)
                    let traits = NSFontManager.shared.traits(of: font)
                    if !traits.contains(.boldFontMask) {
                        isWholeLineBold = false
                    }
                } else {
                    isWholeLineBold = false
                }
            }

            if maxFontSize >= 18.5 {
                output.append("\\subsection*{\(escapeLaTeX(trimmed))}")
            } else if maxFontSize >= 15.0 {
                output.append("\\subsubsection*{\(escapeLaTeX(trimmed))}")
            } else if maxFontSize >= 13.8 && isWholeLineBold {
                output.append("\\paragraph*{\(escapeLaTeX(trimmed))}")
            } else {
                output.append(renderInlineRuns(attributed, in: entry.range))
            }
        }

        closeListIfNeeded()
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderInlineRuns(_ attributed: NSAttributedString, in range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let fullStr = attributed.string as NSString
        var pieces: [String] = []

        attributed.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            let raw = fullStr.substring(with: subRange)
            guard !raw.isEmpty else { return }

            let escaped = escapeLaTeX(raw)
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isBold = traits.contains(.boldFontMask)
            let isItalic = traits.contains(.italicFontMask)
            let underlineVal = (attrs[.underlineStyle] as? Int) ?? 0
            let isUnderline = underlineVal != 0

            // Avoid wrapping pure whitespace in formatting macros
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                pieces.append(escaped)
                return
            }

            var formatted = escaped
            if isBold { formatted = "\\textbf{\(formatted)}" }
            if isItalic { formatted = "\\textit{\(formatted)}" }
            if isUnderline { formatted = "\\underline{\(formatted)}" }
            pieces.append(formatted)
        }

        return pieces.joined()
    }

    public static func convertPlainTextToLaTeX(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        enum ListKind { case none, bullet, numbered }
        var currentList: ListKind = .none
        var output: [String] = []

        func closeListIfNeeded() {
            switch currentList {
            case .bullet: output.append("\\end{itemize}")
            case .numbered: output.append("\\end{enumerate}")
            case .none: break
            }
            currentList = .none
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                closeListIfNeeded()
                if output.last != "" {
                    output.append("")
                }
                continue
            }
            if let prefixLen = bulletPrefixLength(in: line) {
                if currentList != .bullet {
                    closeListIfNeeded()
                    output.append("\\begin{itemize}")
                    currentList = .bullet
                }
                let content = (line as NSString).substring(from: prefixLen)
                output.append("  \\item \(escapeLaTeX(content))")
            } else if let prefixLen = numberedPrefixLength(in: line) {
                if currentList != .numbered {
                    closeListIfNeeded()
                    output.append("\\begin{enumerate}")
                    currentList = .numbered
                }
                let content = (line as NSString).substring(from: prefixLen)
                output.append("  \\item \(escapeLaTeX(content))")
            } else {
                closeListIfNeeded()
                output.append(escapeLaTeX(line))
            }
        }
        closeListIfNeeded()
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bulletPrefixLength(in line: String) -> Int? {
        let ns = line as NSString
        var offset = 0
        while offset < ns.length && ns.character(at: offset) == 32 { offset += 1 }
        let rest = ns.substring(from: offset)
        if rest.hasPrefix("• ") {
            return offset + ("• " as NSString).length
        }
        if rest.hasPrefix("- ") {
            return offset + 2
        }
        return nil
    }

    private static func numberedPrefixLength(in line: String) -> Int? {
        let ns = line as NSString
        var offset = 0
        while offset < ns.length && ns.character(at: offset) == 32 { offset += 1 }
        let startDigits = offset
        while offset < ns.length {
            let ch = ns.character(at: offset)
            if ch >= 48 && ch <= 57 { offset += 1 } else { break }
        }
        guard offset > startDigits, offset + 1 < ns.length else { return nil }
        if ns.character(at: offset) == 46 && ns.character(at: offset + 1) == 32 { // ". "
            return offset + 2
        }
        return nil
    }

    public static func escapeLaTeX(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count + 16)
        for ch in input {
            switch ch {
            case "\\": result.append("\\textbackslash{}")
            case "{": result.append("\\{")
            case "}": result.append("\\}")
            case "$": result.append("\\$")
            case "&": result.append("\\&")
            case "%": result.append("\\%")
            case "#": result.append("\\#")
            case "_": result.append("\\_")
            case "~": result.append("\\textasciitilde{}")
            case "^": result.append("\\textasciicircum{}")
            case "☐": result.append("$\\square$")
            case "☑": result.append("$\\boxtimes$")
            case "\u{00A0}": result.append("~")
            default: result.append(ch)
            }
        }
        return result
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let idx = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<idx]) + "…"
    }
}
