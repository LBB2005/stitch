# Menu Bar File Combiner — Spec (v2, final)

Working name: **Stitch** (rename anytime)

A native macOS menu bar app that merges PDFs, converts images, and prepares files for uploading to AI. It replaces the Adobe PDF combiner. Separate app from Loadout, same design bar: should look and feel Apple-made, with light and dark mode.

**Personal use only.** No App Store, no notarization, no sandbox. Build and run locally from Xcode; ad-hoc signing is fine. This keeps LibreOffice support simple.

**Originals are never modified, moved or deleted.** Every operation writes a new file.

## Tech stack
- Swift + SwiftUI, macOS 14+
- `NSStatusItem` (not plain `MenuBarExtra`) so the icon itself can accept dragged files
- PDFKit for merging, reordering and page thumbnails
- ImageIO / Core Image for HEIC, JPEG, PNG conversion
- Vision framework for OCR
- No network calls; everything runs locally

## Getting files in
1. **Drag onto the menu bar icon.** Icon highlights on hover and opens the panel with the files loaded.
2. **Click the icon** to open a small panel with:
   - a drop zone
   - a **Choose Files…** button that opens the Finder picker (multi-select, filtered to supported types)

## Choosing an action
Once files are loaded, the panel shows the file list and action buttons. Only buttons that make sense for the loaded files are enabled.
- **Merge to PDF** — combine everything into one PDF
- **Convert to JPEG** — each image (HEIC, PNG, etc.) becomes a JPEG
- **Convert to PDF** — each image becomes its own PDF, or all images into one PDF (toggle)

## Supported conversions (v1)
- Merge PDFs into one PDF
- HEIC → JPEG (keep orientation, strip location data by default)
- Images (HEIC, JPEG, PNG) → PDF, one image per page, page sized to the image
- Mixed merge: PDFs + images + Word/PowerPoint/Excel + CSV into one PDF
  - macOS has no built-in Office-to-PDF converter. Use LibreOffice in headless mode (`soffice --headless --convert-to pdf`) if installed; if not, show a one-time message explaining how to install it, and skip those files rather than failing the whole merge.
  - Excel (`.xlsx`, `.xls`, `.xlsm`, `.xlsb`, `.xltx`, `.ods`): every sheet, in tab order, each printed one page wide (landscape when wider than a portrait page) so columns never spill onto separate pages. `--convert-to` can't do this, so a small LibreOffice Python macro in Stitch's own LibreOffice profile sets each sheet's page style and exports; if it fails, fall back to the workbook's own print layout.
  - CSV/TSV: Stitch draws the table itself (no LibreOffice needed). First row is the header, repeated on every page. Columns always fit the page width: portrait if they fit, else landscape with text shrunk as needed (9 pt → never below 6 pt), then the widest columns wrap. Numeric columns are right-aligned. Delimiter detected (comma, semicolon, tab, Excel's `sep=` line); UTF-8/UTF-16 with BOM, else Windows Latin 1. Real text, so AI chats can read it.

## Reorder before merging
- Before a merge, show a grid of page thumbnails (one tile per file, expandable to individual pages)
- Drag to reorder files or pages; delete pages with a hover ✕
- **Smart default order:**
  - If the filenames share a common name with a number (e.g. `Lecture 1`, `Lecture 2`, `Lecture 10`, or `Week 3 Slides`, `Week 12 Slides`), sort them by that number using natural sort, so 10 comes after 9, not after 1
  - Otherwise, keep the order the files were added
  - Show a small label explaining which order was used ("Sorted by lecture number" / "Order added") with a one-click switch between them
- **Merge** button at the bottom finalizes

## Shrink to fit upload limits (quality-first)
- Only compress when the output is **over the target size**. Under the limit, the file is left untouched.
- Target size set in Settings (default 30 MB).
- When compressing:
  - Never touch text or vector content; only re-encode embedded images
  - Downsample images step by step (e.g. 300 → 220 → 150 DPI) and stop at the first step that fits
  - Never go below 150 DPI or JPEG quality 0.75; if it still doesn't fit, say so and offer to split into parts instead of degrading further
- Show before/after size

## OCR
- Toggle: **Make scans searchable**
- Runs Vision text recognition on pages/images with no text layer and adds an invisible text layer, so the visible page is unchanged
- Off by default for speed; remembers last setting

## Output
- Default save location: **Downloads**
- **Save to…** option in the panel opens a Finder save dialog for a one-off location
- **Name the file:** a filename field is always shown right above the Merge/Convert button, pre-filled and selected so you can just type over it
  - Pre-fill: if smart order detected a series, use it (e.g. `Lecture 1–3.pdf`); otherwise `Merged – YYYY-MM-DD HHmm.pdf`
  - If a file with that name exists, add ` (2)` rather than overwriting
- **Drag the result out:** after a merge/conversion, the finished file appears as a draggable tile in the panel. Drag it straight into a ChatGPT/Claude browser tab, an email, or Finder.
- Done screen also shows final size and **Reveal in Finder**; a system notification fires if the panel was closed

## Settings
- Default save folder
- Upload size target
- OCR on/off default
- Launch at login

## Out of scope for v1
- Finder right-click Quick Actions and keyboard shortcut → moved into Part 2 (Finder Open With / Services, Insert-menu shortcuts)
- Copy-to-clipboard for pasting into AI (drag-out covers this)
- Recent files list → moved into Part 2 (Recent PDFs in the Stitch window and File → Open Recent); watch folder still out
- Splitting PDFs, rotating pages → Part 2 "later versions" (page tools)
- App Store / sharing with others

## UI design — Direction A: Compact native popover
Mockups: https://claude.ai/artifact/CgqFda3vKZaizMbGhpt31a (artboard A, light and dark rows). Match it closely.

**Overall feel**
- One small popover under the menu bar icon, styled like Control Center / AirDrop (about 360pt wide)
- Frosted, semi-transparent material (`NSVisualEffectView` / SwiftUI `.ultraThinMaterial`), thin hairline border, rounded corners, soft shadow
- System font (SF Pro), SF Symbols for all icons
- Accent: system blue (`Color.accentColor`), so it adapts to light/dark automatically
- Light and dark follow the system setting

**Menu bar icon**
- Custom "two stacked pages" glyph, template image so it tints with the menu bar
- Turns blue while files are dragged over it; popover opens showing a "Release to add N files" target

**Screens, all inside the same popover**
1. **Empty:** drop zone (dashed rounded rectangle, icon, "Drop files here") and a **Choose Files…** button
2. **Files loaded:** list rows with file-type icon, name, size and a remove ✕; action buttons below (Merge to PDF, Convert to JPEG, Convert to PDF), invalid ones greyed out; the two toggles (Make scans searchable, Shrink to fit upload limit with before → after size); filename field and Downloads / Save to… picker
3. **Reorder:** pressing Merge to PDF swaps the popover content to a 4-column grid of page thumbnails (same panel, with a back arrow). Drag to reorder with a blue drop-position line; hover ✕ deletes a page; smart-order label at the top; **Merge** button at the bottom
4. **Done:** checkmark, filename, final size, draggable file tile for dropping into a chatbot, **Reveal in Finder**, and a "Start over" link

**Behavior**
- Transitions between screens are quick slide/crossfade animations inside the popover; the popover never opens a separate window
- The popover stays open while dragging the result out, and closes on click outside

## Build order
1. Menu bar icon + panel + Choose Files
2. Merge PDFs with smart order, reorder, filename field and drag-out result
3. HEIC → JPEG and images → PDF
4. Drag-onto-icon
5. Shrink-to-fit
6. OCR
7. Word/PowerPoint via LibreOffice
8. Settings + polish

---

# Part 2: Stitch as an app — Sign & Edit

Full plan and the decisions behind it: `docs/SIGN-AND-EDIT-PLAN.md`. Summary of what is built:

- **The menu bar icon and panel are unchanged.** Everything new lives in real windows; the panel only gains two right-click menu items (Open Stitch Window, Open PDF to Sign or Edit…).
- **Stitch window.** Opening Stitch by hand (Dock, Applications, Spotlight) shows it: *Sign & Edit a PDF* (Open PDF… or drop PDFs), *Merge & Convert* (choose or drop files; they go to the menu bar panel, which does the job as before), and Recent PDFs. Launched at login or to open a file, Stitch stays in the menu bar.
- **Dock icon.** Stitch is `.regular` (Dock icon, menu bar menus) while any Stitch window is open and `.accessory` again when the last one closes.
- **Document windows.** One window, each PDF a native tab, one slim `.unifiedCompact` toolbar: zoom, Edit Text, Text, Date, Sign ▾, My Info ▾, Save Copy.
- **Signing.** Signature and initials, drawn (mouse or a finger on the trackpad) or typed in a macOS script font, stored as vectors in the login Keychain. Touch ID (or the Mac password) before showing, changing or placing them: once each time a document window comes to the front, or with the optional grace in Settings, once per 5 minutes. Placed where you last clicked; drag to move, corner handles resize (keeps its shape), Delete removes, arrows nudge.
- **Text and dates.** Text boxes (size, bold, black/blue/red, optional white background to cover and retype on scans; Save Copy removes the text, scan pixels and drawings under a white box); today's date in the format chosen in Settings.
- **Forms and auto-fill.** Type into the PDF's own fields. *My Info → Fill Matching Fields* matches field names to your profile (name, email, phone, student ID, date of birth, several labelled addresses) and asks which address when there are several. Fields about other people (emergency contact, parent, employer…) are never filled. Profile stored in the Keychain; Touch ID before showing or using it.
- **Edit existing text.** Edit Text mode: hover shows the paragraph, click opens an editor in the closest installed font, size and color. MuPDF removes only that text (images and drawings stay) and the new text is stamped in place as real text. Longer text shrinks to at most 80%, then grows downward with a warning if it overlaps. Scanned pages say so and suggest a white text box.
- **Saving.** Save Copy (⌘S) always writes a new file next to the original: `Lease_signed.pdf` when anything signed is on it, else `Lease_edited.pdf`, adding ` (2)` instead of overwriting. Later saves in the same tab update that copy (never a different file put at that path since). A password-protected PDF's copy keeps the same password. Unwritable folders (Mail attachments, read-only disks) fall back to the panel's save folder (Downloads). Save Copy As… (⇧⌘S) picks any name except the original. Closing or quitting with changes asks Save Copy / Don't Save / Cancel.
- **Opening from everywhere.** Open… (⌘O), Open Recent, the Stitch window, Finder Open With, double-click once Stitch is the default PDF app (Settings), Finder → Services → *Sign or Edit with Stitch*, a drop on the Dock icon, the panel's right-click menu. Password-protected PDFs ask for the password. XFA forms and digitally signed PDFs show a warning banner.
- **Shortcuts (Insert menu).** Signature ⌥⌘S, Initials ⌥⌘I, Date ⇧⌘D (⌥⌘D is macOS's Dock shortcut), Text Box ⌥⌘T, Fill My Info ⌥⌘F, Edit Text ⌥⌘E; zoom ⌘+ ⌘− ⌘0, Fit Width ⌘9; Stitch Window ⇧⌘1.
- **Engine.** MuPDF 1.28.6 (git submodule `vendor/mupdf`, built statically by `scripts/build-mupdf.sh`), reached only through the C shim in `Stitch/Engine/MuPDF`. PDFKit still displays, scrolls, zooms, selects and runs form widgets. No network, no AI.
