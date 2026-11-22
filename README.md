# Graphe

**Graphe** is a 100% native macOS academic deep-reading PDF reader, OneNote-style notebook (for both PDF-linked and standalone notes), LaTeX PDF exporter, and offline dictionary workspace — built from scratch in **Swift 6**, **SwiftUI**, and **AppKit** with **zero third-party SwiftPM dependencies**.

> 🇹🇷 Türkçe kullanım kılavuzu için: [docs/KULLANIM_KILAVUZU_TR.md](docs/KULLANIM_KILAVUZU_TR.md)

---

## Highlights

### Zen PDF Reader & Deep Reading
- **3 Seamless Reading Themes:** **Original**, **Sepia**, and **Night (Soft Dark)** — unified across the window chrome, sidebars, notebook canvas, footnote popovers, and PDF surface without sacrificing Retina vector text crispness.
- **2-Up Book Mode (`⇧⌘2`) & Split View (`⌘\` / `⇧⌘\`):** Read two pages side-by-side like a physical book, open the same PDF at two different pages, or compare two different books with **Synchronized Scrolling (`⌥⌘S`)**.
- **Auto-Crop Margins (`⇧⌘C`):** Non-destructively trims wide academic PDF margins on the fly.
- **Reading Ruler (`⇧⌘R`) & Keyboard Navigation:** Subtle horizontal reading guide plus smooth scrolling with `J` / `K` / `Space` / `Shift+Space`.
- **Command Palette (`⌘K`):** Jump to any page, book, standalone notebook, TOC section, theme, or action from the keyboard.
- **Smart Footnote & Endnote Previews:** Click inline footnote markers (including scanned/OCR books via 8x micro-zoom Vision OCR) to view sharp Retina previews without losing your place, or jump back with `⌘[` / `⌘]`.

### OneNote-Style Notebooks (PDF-Linked & Standalone)
- **Book Notebooks & Standalone Notebooks (`⌘N`):** Every PDF automatically gets its own multi-section, multi-page notebook — and you can also create **PDF-free standalone notebooks** in a dedicated full-canvas mode under the **Defterler** tab.
- **True 2D Freeform Canvas:** Click anywhere to start writing, drag and resize containers, choose **Plain / Dotted / Ruled / Grid** paper styles, and rely on automatic overlap avoidance + sibling push-down as containers grow.
- **Two-Way PDF ↔ Notebook Links:** Highlighting text in a PDF (`⌥1`–`⌥5`) creates a non-destructive highlight and appends a linked quote card with a clickable `[s. X]` badge. Clicking an existing highlight in the PDF jumps straight to and highlights its linked notebook card.
- **Rich Text, Images & Undo/Redo:** Headings (`H1`–`H3`), bold/italic/underline (`⌘B`/`⌘I`/`⌘U`), lists, interactive checkboxes, clipboard image paste (`⌘V`), and full per-container & canvas Undo/Redo (`⌘Z` / `⇧⌘Z`).
- **Custom Font Picker (`Aa`):** Automatically discovers user-installed fonts in `~/Library/Fonts` alongside curated serif, sans, and monospace families, applying them to both the notebook canvas and LaTeX PDF export.

### LaTeX PDF Export, Snapshot Tool & Obsidian Markdown
- **Academic LaTeX PDF Export (`⇧⌘E`):** Compiles any notebook page, section, or full notebook into a clean A4 academic PDF via `xelatex` (`fontspec`, styled left-bar quotes, rich text, embedded images, and 2D side-by-side `minipage` layout mirroring your canvas).
- **3x Retina Snapshot Tool (`⇧⌘X`):** Drag-select any figure, equation, or diagram on a PDF page (accurately honoring rotation and Auto-Crop) to copy it to the clipboard and insert it directly into your active notebook.
- **Obsidian-Ready Markdown (`.md`) & Citations:** Export highlights or notebooks with YAML frontmatter, and copy one-click **Chicago (`⇧⌘Y`)**, **APA 7**, **MLA**, or **BibTeX** citations.

### Offline Dictionary, Vision OCR, Vault Explorer & Spotify Mini Player
- **Offline Dictionaries & Translation:** Combines macOS built-in dictionaries, Apple's on-device Translation framework, and user-imported **StarDict** (`.ifo` / `.idx` / `.dict.dz` / `.syn`) dictionaries (`Option + Click` any word). Includes a built-in Vocabulary Notebook.
- **On-Device Apple Vision OCR:** OCR the current page (`⌥⌘O`), run background OCR across an entire book for FTS5 search, or export a searchable PDF with an invisible text layer.
- **Vault Explorer & SQLite FTS5:** Connect local folders, drag-and-drop organize PDFs, clean filenames & edit academic metadata, and search across all books, highlights, and notebooks in milliseconds. SHA-256 content tracking preserves your annotations even if files are moved or renamed.
- **Single-File Backup (`.graphebackup`):** Export and restore your entire database, notebooks, pasted images, and vocabulary list in one archive.
- **Spotify Mini Player:** Compact sidebar player with artwork, scrubbing, volume control, and optional **Spotify Web API (PKCE OAuth)** integration for browsing playlists and searching tracks without leaving your reading session.

---

## Requirements

- **macOS 15 (Sequoia)** or later
- **Swift 6.0+** (Xcode 16+ or Xcode Command Line Tools)
- **Optional — LaTeX PDF Export:** [`xelatex`](https://www.tug.org/mactex/) (MacTeX or BasicTeX) installed on your system
- **Optional — Offline StarDict Dictionaries:** Import your own StarDict `.ifo`/`.idx`/`.dict.dz` files via the Dictionary panel inside Graphe (no dictionaries are bundled in this repository)
- **Optional — Spotify Web API Playlists/Search:** Create a free app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) with Redirect URI `http://127.0.0.1:43821/callback` and enter your Client ID in the Spotify popover settings

---

## Build & Run

Clone the repository and build the native `.app` bundle:

```bash
git clone https://github.com/muratbas6/graphe.git
cd graphe
./Scripts/build_app.sh release
open build/Graphe.app
```

To copy it to your Applications folder:

```bash
cp -R build/Graphe.app /Applications/
```

### Run the Built-In Test Suite

Graphe includes a self-contained test suite (`GrapheSelfTest`) covering the database, FTS5 search, notebooks, undo/redo, StarDict parsing, citations, Auto-Crop, LaTeX export, and backups:

```bash
swift run GrapheSelfTest
```

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `⌘K` | Open Command Palette |
| `⌘O` / `⌘N` | Open PDF / New Standalone Notebook |
| `⌘W` / `⌘1`–`⌘9` | Close Active Tab / Switch Tabs |
| `⌘Z` / `⇧⌘Z` | Undo / Redo |
| `⌘F` / `⌘G` / `⇧⌘G` | Find in Document / Next / Previous |
| `J` / `K` / `Space` | Smooth Scroll Down / Up / Page Down |
| `⌘D` | Toggle Bookmark on Current Page |
| `⌘[` / `⌘]` | Navigate Back / Forward in Reading History |
| `⌥ + Click` | Look Up Word in Offline Dictionary |
| `⇧⌘H` or `⌥1`–`⌥5` | Highlight Selection & Send to Notebook |
| `⇧⌘X` | Snapshot / Region Crop Tool |
| `⇧⌘R` | Toggle Reading Ruler |
| `⇧⌘Y` | Copy Academic Citation (Chicago) |
| `⇧⌘2` | Toggle 2-Up Book View |
| `⌘\` / `⇧⌘\` | Open 2nd PDF Side-by-Side / Split Same PDF |
| `⌥⌘S` | Toggle Synchronized Scrolling |
| `⇧⌘C` | Toggle Auto-Crop Margins |
| `⌥⌘O` | Run Apple Vision OCR on Current Page |
| `⇧⌘E` | Export Notes (LaTeX PDF / Markdown) |
| `⌥⌘1` / `⌥⌘2` / `⇧⌘F` | Toggle Left Sidebar / Right Panel / Focus Mode |
| `⌘B` / `⌘I` / `⌘U` | Notebook Bold / Italic / Underline |
| `⌘V` / `Esc` | Paste Image to Canvas / Exit Container Focus |

---

## Project Structure

```text
Package.swift                  # Zero-dependency Swift 6 package manifest
Sources/
  Graphe/                      # App entry point (macOS SwiftUI lifecycle)
  GrapheCore/                  # Core library: Models, Storage (SQLite + FTS5),
                               # PDF/OCR/AutoCrop/Footnote services, Notebook &
                               # Font catalog, LaTeX exporter, StarDict, Spotify, UI
  GrapheSelfTest/              # Self-contained verification suite (20 test suites)
Scripts/
  build_app.sh                 # Builds & codesigns build/Graphe.app
Resources/
  AppIcon.icns                 # Application icon
docs/
  KULLANIM_KILAVUZU_TR.md      # Turkish user guide
```

---

## License

Graphe is free software released under the **GNU General Public License v3.0 (GPL-3.0)**. See [LICENSE](LICENSE) for details.
