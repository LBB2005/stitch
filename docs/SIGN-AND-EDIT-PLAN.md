# Stitch — Sign & Edit Plan

Adds signing, form filling and PDF editing to the existing Stitch app, so Stitch replaces Acrobat as well as Adobe's combiner. Built on top of what's already in `~/code/stitch` (commit `0b29290`, Excel/CSV merging). Nothing that works today changes; the menu bar panel stays as it is and gains a way to open documents.

**How to use this plan:** give Claude Code one step at a time: *"Read docs/SIGN-AND-EDIT-PLAN.md and do Step 1 only. Run scripts/test.sh when done."* Each step leaves the app working and ends with a "Done when" check.

---

## What's decided

| Area | Decision |
|---|---|
| Where | Inside Stitch. The popover stays; PDFs open in a real document window. |
| Version 1 | Signing + form filling + text editing. Everything else comes after. |
| Windows | One window, each PDF a tab (native macOS tabs). |
| Toolbar | One slim row across the top (`NSToolbar`, `.unifiedCompact`). |
| Signature | Draw on the trackpad, or type in a script font. Plus initials. |
| Touch ID | Required before a saved signature or initials go onto a page. |
| Auto-fill | Name, email, phone, several addresses (pick per form), student ID, date of birth. Stored only on this Mac, in the Keychain. |
| Editing | Click any text and type. MuPDF does the real editing. |
| Saving | Always a copy next to the original (`Lease_signed.pdf`). The original is never written to. |
| Opening | Default PDF app, Finder right-click, drag onto the menu bar icon, the popover. |
| Shortcuts | Keyboard shortcuts for signature, initials, date, text box, my info; recent files in the popover. |
| AI | None. Everything stays offline. |
| Audience | Just Liam. (MuPDF's AGPL license is fine for that; see Risks.) |

---

## What already exists and gets reused

The current code is in good shape for this. These pieces carry over directly:

- **`OutputNaming.uniqueURL`** — never overwrites; every saved copy goes through it.
- **`Workspace`** — per-job temp folders; each open document gets one for its working copy.
- **`PDFTools`** (`PDFAssembler.swift`) — open/locked checks, page geometry, `draw(_:in:)` for redrawing pages as vectors.
- **`Pipeline` pattern** — temp file → finished file → move to a unique name at the end. Save Copy follows the same shape.
- **`Theme` / `Components.swift`** — buttons, wells, colors; the document window uses the same look.
- **`ThumbnailStore`**, **`OCRService`**, **`PDFShrinker`**, **`Arrangement`** — reused later for page tools, scanning and compress.
- **`Preferences`**, **`Notifier`**, **`DemoMode` + `scripts/shot.sh`**, the XCTest setup and `Fixtures`.

What has to change in the app's structure:

- Stitch is a menu-bar-only app (`LSUIElement`). Document windows need a Dock icon and menu bar menus, so Stitch switches to `.regular` activation when the first document window opens and back to `.accessory` when the last one closes.
- The app has no main menu today (only an empty `Settings` scene). File/Edit/Insert/View menus get added with SwiftUI `.commands` on that scene, sending actions to the frontmost document window.
- `CLAUDE.md` says "no third-party packages". MuPDF becomes the one exception.

---

## How editing works (architecture)

Each open PDF has an **`EditSession`** (`@MainActor @Observable`, like `AppModel`). It is the single source of truth:

- `original: URL` — read once, never written.
- `textEdits: [TextEdit]` — changes to text already in the PDF (page, box, new text, font, size, color).
- `overlays: [Overlay]` — things placed on top: signature, initials, text box, date, my-info field (page, rect, kind, content). Movable and deletable until saved.
- `formValues: [String: FormValue]` — typed into the PDF's own form fields.
- An `UndoManager` covering all three.

Rendering and saving:

1. **Working copy** = original + `textEdits`, applied by MuPDF into the document's temp folder. After each text edit, only that page is re-applied and reloaded in the viewer, so what you see is what gets saved.
2. **Viewer** = PDFKit's `PDFView` showing the working copy, with overlays drawn as Stitch's own `PDFAnnotation` subclass (display only) and form fields using PDFKit's built-in widgets.
3. **Save Copy** = working copy → MuPDF sets form values → MuPDF stamps each overlay onto its page as vector content → write → move to `OutputNaming.uniqueURL` next to the original.

MuPDF's three jobs:

- **Read text layout:** "structured text" gives text blocks, lines and characters with font name, size, color and position. This is what makes "click text to edit" possible.
- **Remove old text:** redaction set to remove *only text* (images and drawings left alone: `PDF_REDACT_IMAGE_NONE`, `PDF_REDACT_LINE_ART_NONE`, text `PDF_REDACT_TEXT_REMOVE`, no black boxes).
- **Stamp new content:** Stitch draws each piece of new content (edited text, signature, date, text box) with CoreText/CoreGraphics into a tiny one-page PDF in the temp folder (fonts embed automatically, signatures stay vectors). MuPDF then places that page onto the target page as a Form XObject at the right spot.

PDFKit keeps doing what it's good at: displaying, scrolling, zooming, selection, form widgets, thumbnails.

---

## Step 0 — Housekeeping and quick checks
*Size: S. No new features.*

**Actions**
- Push the unpushed commit `0b29290` to GitHub (it's only on the Mac).
- Decide on `STATUS.md` (untracked): commit it or add it to `.gitignore`.
- `docs/SPEC.md`: add a "Part 2: Sign & Edit" section that points here. In "Out of scope for v1", mark Finder right-click, recent files, splitting and rotating as moving into Part 2 / later.
- `CLAUDE.md`: add the new folders (`Stitch/Document/`, `Stitch/Signing/`, `Stitch/Engine/MuPDF/`), the MuPDF exception and its AGPL note, and extend the originals rule: *opening a PDF never writes to it; Save always makes a new file.*
- Three throwaway checks (delete the code after), each answering one yes/no question:
  1. A Debug build signed with "Flow Dev" can show a Touch ID prompt (`LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`).
  2. It can write and read a login-Keychain item (`SecItemAdd` / `SecItemCopyMatching`, generic password, service `com.liamblackshawbrown.Stitch`).
  3. MuPDF builds as static libraries for arm64 and links into a tiny test target.

**Done when** all three checks pass and the docs are updated. If check 1 or 2 fails, stop and decide how to handle it (see Risks) before Step 4.

---

## Step 1 — The document window (viewer only)
*Size: M. You can open a PDF and read it; no tools work yet.*

**Actions**
- New folder `Stitch/Document/`:
  - `DocumentController.swift` — opens PDFs into windows, tracks them, switches activation policy (`.regular` while any window is open, `.accessory` when none), avoids opening the same file twice (brings its tab forward instead).
  - `DocumentWindowController.swift` — one per PDF. `NSWindow` with `tabbingMode = .preferred` and a shared `tabbingIdentifier`, so PDFs join one window as tabs. Window title = file name. Remembers window size.
  - `DocumentToolbar.swift` — `NSToolbar`, `.unifiedCompact`. For now: zoom out/in, fit width, and a disabled **Save Copy** button. Later steps add the tools.
  - `PDFCanvas.swift` — `NSViewRepresentable` around a `StitchPDFView: PDFView` subclass (continuous scroll, auto-scale, light/dark-safe page shadow). Later steps add click and drag handling here.
  - `DocumentView.swift` — SwiftUI root for the window content.
  - `EditSession.swift` — the model described above, with only `original`, the page count and the working-copy URL filled in for now.
- `StitchApp.swift`: add `.commands` to the `Settings` scene: File → Open… (⌘O), Open Recent, Close Tab (⌘W), Save Copy (⌘S, disabled until there are changes), Save Copy As… (⇧⌘S); standard Edit and Window menus.
- Password-protected PDFs: ask for the password (`PDFDocument.unlock`) instead of failing like the merge flow does.
- `DemoMode`: add `-StitchDemo document`, which opens a sample PDF in a window. `scripts/shot.sh`: support capturing the document window.

**Done when** ⌘O from the menu opens a PDF in a tabbed window, a second PDF joins as a tab, the Dock icon appears and disappears with the windows, and light and dark mode both look right.

---

## Step 2 — Opening from everywhere
*Size: S–M.*

**Actions**
- `Info.plist` (through `project.yml`): `CFBundleDocumentTypes` for `com.adobe.pdf`, role Editor, `LSHandlerRank` = Alternate (so Stitch never takes over until you choose it).
- `AppDelegate`: `application(_:open:)` sends PDFs to `DocumentController` (double-click, Open With, Dock drop).
- Settings (panel): **"Make Stitch the default PDF app"** row → `NSWorkspace.shared.setDefaultApplication(at:toOpen: .pdf)`; shows "Stitch is your PDF app" once set.
- Finder right-click: Finder's **Open With → Stitch** works from the document types. Also add a Services entry (`NSServices`) **"Sign or Edit with Stitch"** for PDFs. Note in Settings that it may need switching on once in System Settings → Keyboard → Keyboard Shortcuts → Services.
- Popover (`HomeView`):
  - Empty screen: an **"Open PDF to Sign or Edit…"** button under Choose Files…, and a **Recent** list (last 5 PDFs opened or saved, with their thumbnails; click to reopen).
  - Files loaded: when the list holds PDFs, add an **"Open to Sign & Edit"** button next to the Convert buttons (opens each PDF as a tab). Dragging onto the menu bar icon keeps working as it does now; this button is the way into editing.
- Menu bar icon right-click menu: add "Open PDF…" above "Settings…".
- Recents: store file bookmarks in `Preferences` (Stitch isn't sandboxed, so plain bookmark data works and survives renames/moves), and also call `NSDocumentController.shared.noteNewRecentDocumentURL` so File → Open Recent and the Dock menu match.

**Done when** a PDF opens in Stitch from a Finder double-click (once Stitch is the default), Open With, the Services menu, the popover button and the Recent list.

---

## Step 3 — MuPDF engine and Save Copy
*Size: L. The biggest technical step. No visible editing yet, but Save Copy works end to end.*

**Actions**
- Add MuPDF as a git submodule at `vendor/mupdf`, pinned to the latest 1.28.x release tag.
- `scripts/build-mupdf.sh`: builds `libmupdf.a` and `libmupdf-third.a` for arm64 (no X11/GL viewer parts) into `build/mupdf/`; skips the build if the libraries are already there. `scripts/build.sh`, `test.sh` and `install.sh` call it first. Optional: build with fewer bundled fonts to keep the app small.
- `project.yml`: header and library search paths, `OTHER_LDFLAGS = -lmupdf -lmupdf-third`, and the shim as a C module.
- `Stitch/Engine/MuPDF/` — a **small C shim** (`StitchMuPDF.h/.c` + `module.modulemap`). MuPDF reports errors with `setjmp`/`longjmp`, which must never jump through Swift code, so **every** MuPDF call lives in C inside `fz_try`/`fz_catch` and returns a status plus an error message. The shim exposes only what Stitch needs:
  - open (with password), save (with cleanup), close
  - structured text for one page → blocks/lines/characters with font name, size, color, box
  - remove text inside rectangles (text only, images and drawings kept)
  - place page 1 of another PDF onto a page at a rectangle (Form XObject)
  - set a form field's value by name; list form fields (name, type, page, rect)
  - "bake" annotations/fields into page content (for an optional Flatten later)
- `MuPDFDocument.swift` — Swift wrapper: `nonisolated`, `throws`, one MuPDF context per document, only ever used from one task at a time.
- `Stitch/Engine/SaveCopy.swift` — the save pipeline: working copy → form values → overlays → write in the temp folder → move to the final name. Naming: `<name>_signed.pdf` when anything signed is on it, else `<name>_edited.pdf`, through `OutputNaming.uniqueURL`. Saves **next to the original**; if that folder can't be written (Mail attachments, read-only disks), saves to the Settings folder (Downloads) and says so.
- Wire Save Copy (⌘S) in the toolbar and menu. After saving, a small toast in the window: "Saved Lease_signed.pdf · Show in Finder". Later saves in the same tab update that same copy (it's Stitch's own file), never the original.
- Closing a tab with unsaved changes asks: **Save Copy / Don't Save / Cancel**.

**Tests** (`StitchTests/MuPDFTests.swift`, new `Fixtures` helpers for a PDF with an image and text, and one with form fields)
- Open → save round trip keeps every page.
- Structured text finds "Alpha page 1" with roughly the right font size and position.
- Removing text in a rect removes those words, keeps other words, and keeps the image.
- Placing a stamp PDF makes its text readable (`PDFPage.string`) at the right spot.
- Save Copy never changes the original (SHA-256 before and after, like `testMixedMergeNeverTouchesOriginalsOrOverwrites`), adds ` (2)` instead of overwriting, and falls back to Downloads when the folder is read-only.

**Done when** the tests pass and Save Copy on an unchanged PDF writes `X_edited.pdf` next to it.

---

## Step 4 — Signatures and initials
*Size: M–L.*

**Actions**
- New folder `Stitch/Signing/`:
  - `SignatureStore.swift` — stores signature and initials as **vector strokes** (or font + text for typed ones), Codable, in the login Keychain (Step 0 check 2).
  - `BiometricGate.swift` — `LAContext` Touch ID prompt ("Stitch wants to use your signature"), falling back to the Mac password. Asked once per placement; optional "don't ask again for 5 minutes".
  - `SignaturePad.swift` — a sheet in the document window with two tabs:
    - **Draw:** sign by dragging, *or* Preview-style **finger on the trackpad** (`allowedTouchTypes = [.indirect]`, `NSTouch.normalizedPosition`, press any key to finish). Smooths strokes, Clear / Done.
    - **Type:** type "Liam Blackshaw-Brown", pick from script fonts that ship with macOS (SignPainter, Snell Roundhand, Bradley Hand, Apple Chancery, Savoye LET).
    - The same sheet makes the initials.
- Toolbar: **Sign ▾** (Signature, Initials, Create/Change Signature…). Placing: Touch ID → the signature appears where you last clicked (or in the middle of the visible page) → drag to move, corner handles to resize (keeps its shape), Delete key removes it.
- `Stitch/Document/OverlayAnnotation.swift` — `PDFAnnotation` subclass that draws overlays in the viewer; `StitchPDFView` handles hit-testing, dragging and resizing them.
- Save: each signature is drawn as vectors into a stamp PDF and placed by MuPDF (Step 3).
- Panel Settings: a **Signatures** row (shows both, Change…, Delete).

**Tests:** strokes encode/decode; a stamped signature stays vector (no image added to the page); the saved file is named `_signed`.

**Done when** you can make a signature once, then sign a lease with Touch ID, move it into place, and save `Lease_signed.pdf`.

---

## Step 5 — Text boxes, dates and keyboard shortcuts
*Size: M.*

**Actions**
- Toolbar: **Text** (click anywhere to type; font size, bold, color; optional white background, which is also how you cover and retype on scanned pages) and **Date** (today's date; format chosen in Settings, default `11/11/2026`).
- Overlays are movable, resizable and undoable like signatures.
- An **Insert** menu with shortcuts (shown in toolbar tooltips):

| Action | Shortcut |
|---|---|
| Place signature | ⌥⌘S |
| Place initials | ⌥⌘I |
| Today's date | ⌥⌘D |
| Text box | ⌥⌘T |
| Fill my info… | ⌥⌘F |
| Save Copy / Save Copy As… | ⌘S / ⇧⌘S |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Open / Close tab | ⌘O / ⌘W |
| Zoom in / out / actual size | ⌘+ / ⌘− / ⌘0 |

**Done when** you can fill out a flat (no form fields) PDF with text boxes and dates using only the keyboard and a few clicks, then undo all of it.

---

## Step 6 — Forms and auto-fill
*Size: M.*

**Actions**
- Form fields: type straight into the PDF's own fields (PDFKit widgets in `StitchPDFView`); values go into `EditSession.formValues` and are written by MuPDF on save. Checkboxes and dropdowns included.
- `Stitch/Signing/Profile.swift` — your info (name, email, phone, addresses with labels like "School" and "Mailing", student ID, date of birth), stored in the Keychain like signatures.
- Panel Settings → **Your Info** screen to edit it (fits the 340 pt panel as a scrolling list).
- `Stitch/Engine/AutoFill.swift` — pure, unit-tested matching from field names to profile items ("First Name", "fname", "Applicant Email", "Phone #", "DOB", "Date of Birth", "Student ID", "USC ID", "Street Address", "City", "Zip"…). Toolbar **My Info ▾ → Fill Matching Fields** fills what it can, highlights what it filled, and asks which address to use when a form has address fields.
- For flat PDFs: **My Info ▾** lists each item; picking one drops it as a text box where you clicked.
- Touch ID before showing or filling profile data.

**Tests:** a table of real-world field names → the right profile item; filled values survive Save Copy and read back from the saved file.

**Done when** a fillable school form fills itself in one click and saves with the values in place.

---

## Step 7 — Click to edit existing text
*Size: L. The hardest feature.*

**Actions**
- `Stitch/Engine/TextLayout.swift` — turns MuPDF's structured text into `TextBlock`s (box, lines, font name with the subset prefix like `ABCDEF+` stripped, size, color). Cached per page.
- `Stitch/Engine/FontMatcher.swift` — matches a PDF font to an installed one (exact PostScript name → same family and weight → serif/sans fallback: Times / Helvetica). Embedded fonts are usually partial copies missing letters the original didn't use, so new text always uses an installed font.
- In `StitchPDFView`: hovering real text shows an I-beam and a faint outline of its block. Clicking opens an inline editor (`NSTextView` over the block, in the matched font, size and color). Return commits, Shift-Return adds a line, Esc cancels.
- On commit: a `TextEdit` is added → MuPDF removes the old text in the block's box (text only) → the new text is drawn into a stamp PDF with CoreText in the same box → placed → the page reloads. If the new text is longer: shrink it down to 80% of the original size, then let the box grow downward, and show a small warning if it now overlaps other content.
- Scanned pages have no real text to edit: clicking one shows "This page is a scan — use a text box with a white background to cover and retype" (and later, OCR).
- Undo re-applies the remaining edits to that page from the original.

**Tests:** editing one word changes only that word in `PDFPage.string`; the other text and the images on the page are still there; a longer replacement stays inside the page; undo restores the original text.

**Done when** fixing a typo, a name or a date looks seamless, and a rewritten paragraph stays in its place.

---

## Step 8 — Version 1 polish and real-world check
*Size: M.*

**Actions**
- Undo/redo across every kind of change; unsaved-changes dot on tabs.
- Light and dark mode on every new screen; screenshots of each with `scripts/shot.sh`.
- Speed: opening a 100-page PDF should feel instant; working-copy updates only touch the changed page.
- Run it on real documents: a lease, a USC form, a freelance contract, a scanned page, a password-protected PDF, a digitally signed PDF (warn that editing invalidates its digital signature).
- Update `docs/SPEC.md`, `CLAUDE.md` and `STATUS.md`; `scripts/install.sh` to /Applications.

**Done when** Stitch is your default PDF app and you've used it instead of Acrobat for a week.

---

## Later versions (after v1)

In order of usefulness; each reuses code that already exists.

1. **Highlights and comments** — PDFKit highlight/note annotations, saved through the same pipeline.
2. **Page tools** — a page-thumbnail sidebar in the document window (`PDFThumbnailView` + the existing `Arrangement`): drag to reorder, rotate, delete, extract pages to a new PDF, split one PDF into several.
3. **Compress** — the existing `PDFShrinker` behind a toolbar button ("Shrink to under 10 MB").
4. **Convert and protect** — PDF → images (CoreGraphics render), PDF → Word (MuPDF's Word export or LibreOffice, which Stitch already uses), password-protect (PDFKit's user/owner password write options).
5. **Scanning** — iPhone camera through Continuity Camera ("Import from iPhone → Scan Documents" gives a PDF directly), photos and screenshots through the existing `ImageConverter`, and searchable text through the existing `OCRService`.
6. **Flatten on save** (optional setting) — bake form fields and overlays so nothing can be changed afterwards.

---

## Risks and how they're handled

- **Touch ID / Keychain with a self-signed build.** Keychain items that require Touch ID on their own need a paid Apple developer team. Plan: Stitch asks for Touch ID itself (`LAContext`) and keeps the data in the login Keychain. Fine for a personal app. Step 0 confirms it works before any signing code is written.
- **Fonts when editing.** PDFs usually embed partial fonts, so rewritten text uses the closest installed font. Common fonts (Helvetica, Times, Arial) will look identical; unusual ones may look slightly different.
- **MuPDF license (AGPL).** Free for personal use. If Stitch were ever shared or sold, its source would have to be published, or a commercial MuPDF license bought.
- **MuPDF and Swift.** Errors that jump through Swift code crash the app, so every MuPDF call stays inside the C shim. This rule goes in `CLAUDE.md`.
- **Unusual PDFs.** XFA forms (some government forms) aren't supported by PDFKit or MuPDF; Stitch says so and still lets you use text boxes. Password-protected PDFs ask for the password. Digitally signed PDFs get a warning before editing.
- **App size.** MuPDF adds tens of MB; building it with fewer bundled fonts keeps that down.

---

## New and changed files at a glance

```
vendor/mupdf/                       git submodule (pinned release)
scripts/build-mupdf.sh              new
project.yml                         MuPDF linking, document types, Services
Stitch/Resources/Info.plist         generated changes from project.yml
Stitch/App/StitchApp.swift          menus (.commands), open-file handling
Stitch/App/Preferences.swift        recents, date format, default-app state
Stitch/Document/                    new: DocumentController, DocumentWindowController,
                                    DocumentToolbar, DocumentView, PDFCanvas,
                                    EditSession, Overlay, OverlayAnnotation, InlineTextEditor
Stitch/Signing/                     new: SignatureStore, BiometricGate, SignaturePad, Profile
Stitch/Engine/MuPDF/                new: StitchMuPDF.h/.c, module.modulemap, MuPDFDocument.swift
Stitch/Engine/SaveCopy.swift        new
Stitch/Engine/TextLayout.swift      new
Stitch/Engine/FontMatcher.swift     new
Stitch/Engine/StampRenderer.swift   new (CoreText/CoreGraphics → one-page stamp PDFs)
Stitch/Engine/AutoFill.swift        new
Stitch/Views/HomeView.swift         Open button, Recent list, "Open to Sign & Edit"
Stitch/Views/SettingsView.swift     Default PDF app, Signatures, Your Info, date format
Stitch/Panel/PanelController.swift  "Open PDF…" in the right-click menu
StitchTests/                        MuPDFTests, SaveCopyTests, AutoFillTests, SigningTests,
                                    EditSessionTests; new Fixtures helpers
docs/SPEC.md, CLAUDE.md             updated in Step 0 and Step 8
```
