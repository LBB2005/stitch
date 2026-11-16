# Stitch

## What this is
Native macOS menu bar app that merges PDFs, Office files and CSVs, converts images, and prepares files for uploading to AI chats, and (Part 2) a Dock app that signs, fills and edits PDFs. Replaces the Adobe PDF combiner and Acrobat. Personal use only: no App Store, no notarization, no sandbox. Full spec: `docs/SPEC.md`; Sign & Edit plan: `docs/SIGN-AND-EDIT-PLAN.md`. UI mockup (Direction A): https://claude.ai/artifact/CgqFda3vKZaizMbGhpt31a

## Goals
- Drop files on the menu bar icon (or click it) → Merge to PDF / Convert to JPEG / Convert to PDF.
- Arrange pages before merging (4-column thumbnail grid, smart numeric order for `Lecture 1…10`).
- Shrink to fit an upload limit, quality first (images only, 300 → 220 → 150 DPI, never lower; offer split instead).
- Optional OCR ("Make scans searchable") as an invisible text layer.
- Drag the result straight into a browser chat. Originals are never modified, moved or deleted (the one exception: renaming a document by clicking its title, which renames the file and nothing else).
- One Stitch window (no separate home page): launching shows the empty document window as the start canvas (drop a PDF to sign it, several files to merge them right there); ⌘K searches recent files, PDFs on the Mac and actions.

## Stack
Swift 6 + SwiftUI, macOS 14+, AppKit `NSStatusItem` + non-activating `NSPanel` (Liquid Glass on macOS 26, `NSVisualEffectView` before). PDFKit/CoreGraphics for merging, a Quartz filter for image-only recompression, ImageIO for HEIC/JPEG, Vision for OCR, LibreOffice (`soffice --headless`) for Word/PowerPoint/Excel if installed (Excel goes through a Python macro so sheets fit one page wide); CSVs are drawn by Stitch itself with CoreText. No network calls, no third-party packages — with one exception: **MuPDF** (git submodule `vendor/mupdf`, pinned to the 1.28.x maintenance branch (past 1.28.6), linked statically) for editing PDFs. MuPDF is AGPL: fine for personal use; if Stitch were ever shared or sold, its source would have to be published or a commercial MuPDF license bought.

## How to run
Run every command from the repo root (`~/code/stitch`).

```bash
git submodule update --init --recursive --depth 1   # once, after cloning (MuPDF)
scripts/build-mupdf.sh               # MuPDF → build/mupdf/lib (build/test/install call it; skips if built)
scripts/build.sh                     # xcodegen + Debug build, quiet output
scripts/test.sh                      # xcodegen + unit tests (pass -only-testing:StitchTests/PDFEngineTests to narrow)
scripts/install.sh                   # Release build → /Applications/Stitch.app and launch (needed for Open at login)
open build/DerivedData/Build/Products/Debug/Stitch.app    # run the Debug build
pkill -x Stitch                      # stop
scripts/shot.sh <empty|drop|files|arrange|done|settings> [light|dark]   # Debug screenshot → build/shots/
scripts/winshot.sh <app|app-merge|app-search|document|document-todo|document-rename|document-sign|document-myinfo|document-history|document-find|document-combine|document-folded|form|appsettings> [light|dark]   # Debug window draws itself → build/shots/ (no Screen Recording needed; it can't draw glass or vibrant sidebar text, so check dark sidebars in the app)
swift scripts/make-icon.swift        # redraw the app icon PNGs
```

`Stitch.xcodeproj` is generated and git-ignored. Edit `project.yml`, never the `.xcodeproj`.

## Layout
- `Stitch/Engine/` — pure, nonisolated, unit-tested: `SmartOrder`, `OutputNaming`, `ImageConverter`, `OfficeConverter`, `CSVConverter`, `PDFAssembler` (`PDFTools`), `OCRService`, `PDFShrinker`, `Pipeline` (every job end to end), `Thumbnails`, `Workspace` (temp dir).
- `Stitch/Model/` — `InputFile`/`FileKind`, `Arrangement` (the Arrange grid's order).
- `Stitch/App/` — `AppModel` (all state + actions, `@MainActor @Observable`), `Preferences`, `Services` (notifications, login item), `DemoMode` (Debug only).
- `Stitch/Panel/` — `PanelController` (status item, drag-onto-icon, panel sizing/dismissal), `MenuBarIcon`.
- `Stitch/Views/` — one file per panel screen; `Components` holds the shared styles from the mockup; `AppSettingsView` is the Stitch window's Settings (⌘,).
- `Stitch/Document/` — the Dock app: `DocumentController` (opens PDFs as tabs, recents, `.regular`/`.accessory` switching, quit review), `StartWindow` (the empty Stitch window: drop card, Recent, merging on the canvas via `MergeJob`; a PDF opened from it takes over the same NSWindow, and closing the last PDF hands the window back), `CommandBar` (⌘K: a child panel; recent files, Spotlight PDFs in the home folder, actions), `TitleView` (toolbar title; click to rename), `DocumentWindowController` + `DocumentToolbar` + `DocumentSplitController` (sidebar + PDF, folding) + `DocumentView` (one tab), `PDFCanvas` (`StitchPDFView`: overlays, Edit Text, inline editors; `FormBridge`), `EditSession` (one PDF's state + undo, single source of truth), `Overlay`/`OverlayAnnotation`, `InlineTextEditor`, `PlaceItem` (what panels drag or click onto a page).
- `Stitch/Document/Sidebar/` — the document window's icon-rail sidebar (`docs/ICON-RAIL-PLAN.md`): `SidebarView`, `RailView` (also the folded, floating rail), one file per panel (Pages, To-Do, Sign, My Info, History, Find, Combine: merge or convert from inside a document, its own `MergeJob`; a merged PDF opens in a new tab), `SelectionCard`, and `DocumentWindowController+Sidebar` (everything the panels ask of the window, including `place(...)`, the one path for putting anything on a page).
- `Stitch/Signing/` — `Signature` (vector strokes or typed), `SignatureStore` (Keychain) + `BiometricGate` (Touch ID), `SignaturePad`, `Profile`.
- `Stitch/Engine/MuPDF/` — `StitchMuPDF.h/.c` (C shim, the only code that calls MuPDF) + `module.modulemap`, `MuPDFDocument.swift` (Swift wrapper). Engine additions: `SaveCopy`, `StampRenderer`, `TextLayout`, `FontMatcher`, `AutoFill` (+ `plan`), `PageGeometry`, and for the sidebar `TodoFinder`, `HistoryLog`, `FindReplace` (tested in `SidebarTests`).

## Notes for Claude
- Keep secrets in .env; never commit API keys.
- Never write to an input file's location in a way that could replace it: outputs go through `OutputNaming.uniqueURL` (adds ` (2)`), Office files are converted from a copy in the work folder.
- Security fixes from `docs/audits/SECURITY-AUDIT.md`: Release is hardened (no `get-task-allow`), saved copies of password-protected PDFs keep their password, stamps close any `q`/`BT` the page leaves open, white cover boxes redact what's under them, PDF links ask first (http/https/mailto only), LibreOffice runs without internet access under `sandbox-exec`, and `build-mupdf.sh` rebuilds whenever the submodule commit changes.
- Opening a PDF never writes to it; Save always makes a new file (`SaveCopy` refuses the original's path). The viewer shows a working copy in the session's temp folder. Renaming from the title only moves the file (`EditSession.moved(to:)`) and never replaces an existing file.
- `-StitchDemo app-flow -saveFolder <dir>` (Debug) drives open-into-window, rename, close-to-start, merge and New Tab for real and writes PASS/FAIL lines to `<dir>/flow.txt`. Demo runs use their own empty Keychain entries, so no Keychain prompt stalls them.
- Every MuPDF call lives in the C shim inside `fz_try`/`fz_catch`: MuPDF's longjmp must never cross Swift code. Add new MuPDF features as shim functions returning a status + message.
- PDFKit and MuPDF place things in PDF user space; MuPDF's structured text is in display space (rotated, y down). `MuPDFDocument.PageInfo` converts; `PageGeometry` draws overlays upright on rotated pages.
- The menu bar panel's behaviour and look stay as they are; new Sign & Edit features go in the Stitch window and document tabs.
- Document window panels call `DocumentWindowController` methods, never `EditSession` or `StitchPDFView` directly. Every change goes through `EditSession` so History gets an entry; entries carry their `UndoManager` group, so changes made in one event undo together.
- Pipeline order matters: assemble → OCR → shrink → bookmarks (redrawing drops bookmarks and annotations; `PDFShrinker` restores links).
- OCR text must be stretched with a font matrix, not the text matrix, or PDFKit reads gaps as spaces.
- Jobs run in `Task.detached` from `AppModel.run`; engine code checks `Task.checkCancellation()`.
- Swift 6 strict concurrency; system colors and SF Symbols only in the UI; must look right in light and dark.
- `scripts/shot.sh` launches the Debug app with `-StitchDemo`; demo panels never take keyboard focus (they'd steal the person's typing).
- Unit tests run hosted in the app; `AppDelegate` skips startup side effects under XCTest.
