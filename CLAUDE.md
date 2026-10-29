# Stitch

## What this is
Native macOS menu bar app that merges PDFs, converts images, and prepares files for uploading to AI chats. Replaces the Adobe PDF combiner. Personal use only: no App Store, no notarization, no sandbox. Full spec: `docs/SPEC.md`. UI mockup (Direction A): https://claude.ai/artifact/CgqFda3vKZaizMbGhpt31a

## Goals
- Drop files on the menu bar icon (or click it) → Merge to PDF / Convert to JPEG / Convert to PDF.
- Arrange pages before merging (4-column thumbnail grid, smart numeric order for `Lecture 1…10`).
- Shrink to fit an upload limit, quality first (images only, 300 → 220 → 150 DPI, never lower; offer split instead).
- Optional OCR ("Make scans searchable") as an invisible text layer.
- Drag the result straight into a browser chat. Originals are never modified, moved or deleted.

## Stack
Swift 6 + SwiftUI, macOS 14+, AppKit `NSStatusItem` + non-activating `NSPanel` (Liquid Glass on macOS 26, `NSVisualEffectView` before). PDFKit/CoreGraphics for merging, a Quartz filter for image-only recompression, ImageIO for HEIC/JPEG, Vision for OCR, LibreOffice (`soffice --headless`) for Word/PowerPoint if installed. No network calls, no third-party packages.

## How to run
Run every command from the repo root (`~/code/stitch`).

```bash
scripts/build.sh                     # xcodegen + Debug build, quiet output
scripts/test.sh                      # xcodegen + unit tests (pass -only-testing:StitchTests/PDFEngineTests to narrow)
scripts/install.sh                   # Release build → /Applications/Stitch.app and launch (needed for Open at login)
open build/DerivedData/Build/Products/Debug/Stitch.app    # run the Debug build
pkill -x Stitch                      # stop
scripts/shot.sh <empty|drop|files|arrange|done|settings> [light|dark]   # Debug screenshot → build/shots/
swift scripts/make-icon.swift        # redraw the app icon PNGs
```

`Stitch.xcodeproj` is generated and git-ignored. Edit `project.yml`, never the `.xcodeproj`.

## Layout
- `Stitch/Engine/` — pure, nonisolated, unit-tested: `SmartOrder`, `OutputNaming`, `ImageConverter`, `OfficeConverter`, `PDFAssembler` (`PDFTools`), `OCRService`, `PDFShrinker`, `Pipeline` (every job end to end), `Thumbnails`, `Workspace` (temp dir).
- `Stitch/Model/` — `InputFile`/`FileKind`, `Arrangement` (the Arrange grid's order).
- `Stitch/App/` — `AppModel` (all state + actions, `@MainActor @Observable`), `Preferences`, `Services` (notifications, login item), `DemoMode` (Debug only).
- `Stitch/Panel/` — `PanelController` (status item, drag-onto-icon, panel sizing/dismissal), `MenuBarIcon`.
- `Stitch/Views/` — one file per screen; `Components` holds the shared styles from the mockup.

## Notes for Claude
- Keep secrets in .env; never commit API keys.
- Never write to an input file's location in a way that could replace it: outputs go through `OutputNaming.uniqueURL` (adds ` (2)`), Office files are converted from a copy in the work folder.
- Pipeline order matters: assemble → OCR → shrink → bookmarks (redrawing drops bookmarks and annotations; `PDFShrinker` restores links).
- OCR text must be stretched with a font matrix, not the text matrix, or PDFKit reads gaps as spaces.
- Jobs run in `Task.detached` from `AppModel.run`; engine code checks `Task.checkCancellation()`.
- Swift 6 strict concurrency; system colors and SF Symbols only in the UI; must look right in light and dark.
- `scripts/shot.sh` launches the Debug app with `-StitchDemo`; demo panels never take keyboard focus (they'd steal the person's typing).
- Unit tests run hosted in the app; `AppDelegate` skips startup side effects under XCTest.
