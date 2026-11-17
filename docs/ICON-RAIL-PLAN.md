# Stitch — Icon Rail Plan (document window sidebar)

Replaces the document window's toolbar-only layout with a sidebar: a 56 pt **rail** of six icons and a 222 pt **panel** beside it that the icons switch between. Chosen from eight explored layouts ("variant E").

- Exploration (all eight): https://claude.ai/artifact/Q6ar5mVnvmhLFzw1ovwKPD
- The rail, panel by panel (the design this plan builds): https://claude.ai/artifact/9PCvvzZmKT8MVP9inx5bKg

**Status (2026-11-12): built, Steps 1–9.** Where the build differs from the steps below:
- Auto-fold is at 860 pt (unfold past 920), not 760/820: the toolbar needs about 600 pt beside a 278 pt sidebar. The sidebar's minimum is 230 pt so the selection card fits.
- History entries carry their `UndoManager` group; changes made in one event undo (and show as undone) together.
- History lives on `EditSession` (`session.history`), not `DocumentUI`.
- Return-to-next in To-Do is left out: Return already commits text boxes and edits on the page.
- The scan note also shows as a toast, since it comes from a click on the page while another panel may be open.

**How to use this plan:** give Claude Code one step at a time: *"Read docs/ICON-RAIL-PLAN.md and do Step 1 only. Run scripts/test.sh when done."* Every step leaves the app working and ends with a "Done when" check. Steps 2–8 each depend only on Step 1, except where a step says otherwise.

---

## What's decided

| Area | Decision |
|---|---|
| Layout | `NSSplitViewController`: a sidebar item (rail + panel) and the content item (today's `DocumentView` with the `PDFView`). |
| Panels | Pages ⌘1, To-Do ⌘2, Sign ⌘3, My Info ⌘4, History ⌘5, Find ⌘F. In a new **View › Sidebar** submenu. |
| Folding | Clicking the active icon, ⌃⌘S or the rail's bottom button folds the sidebar. Folded, the rail floats over the canvas's leading edge, and the traffic lights move into the toolbar as with any collapsed sidebar. Windows narrower than about 760 pt fold on their own. |
| Which panel opens | To-Do when the document has anything to do; Pages otherwise. Each window remembers its own. |
| Save Copy | Stays the blue toolbar button (⌘S). No panel has its own Save. |
| Unsaved | macOS's tab dot (`isDocumentEdited`, as today), "Edited" under the title, and a dot on the History icon that also shows when folded. |
| Edit Text | Stays a toolbar toggle (⌥⌘E). While on, a pill above the page says so with a Done button. Find's Replace uses the same engine. |
| Selected item | Its settings show in a card at the bottom of the sidebar. The floating format bar stays only for when the sidebar is folded. |
| Banners | XFA, digitally signed and scan banners become notes at the top of To-Do. Nothing covers the page. |
| Toolbar | Title, zoom, Edit Text, Text, Date, Sign, undo/redo, Save Copy. My Info ▾ moves into its panel (Step 6). |
| Look | Floating Liquid Glass sidebar on macOS 26 (what `NSSplitViewItem(sidebarWithViewController:)` gets for free); `.regularMaterial` before. System colors and SF Symbols only, light and dark. |
| Menu bar panel | Unchanged. |

---

## Shape of the code

```
DocumentWindowController
 └─ contentViewController = DocumentSplitController (NSSplitViewController)       new
     ├─ sidebar item:  NSHostingController(SidebarView)                             new
     │    SidebarView = HStack { RailView, panel(ui.panel), SelectionCard? }
     └─ content item:  NSHostingController(DocumentView)                            today's view
          DocumentView + overlay(alignment: .leading) { RailView } when folded
```

`DocumentUI` (already `@Observable`, one per window) gains the sidebar's state, so every panel and the rail read one model:

```swift
enum SidebarPanel: String, CaseIterable { case pages, todo, sign, myInfo, history, find }
var panel: SidebarPanel = .pages
var isFolded = false
var todo: TodoList = .empty          // Step 4
var history: [HistoryEntry] = []     // Step 7
var historyCursor = 0                // entries before this index are applied
var find: FindState = .init()        // Step 8
```

Panels call the existing `DocumentWindowController` methods (`placeSignature`, `insertDate`, `fillMatchingFields`, `updateSelectedTextBox`, …). They don't touch `EditSession` or `StitchPDFView` directly. Anything that decides something (what counts as a to-do, which fields match, how history entries group) goes in nonisolated, unit-tested engine code, the way `AutoFill` and `TextLayout` are now.

New files at a glance:

```
Stitch/Document/DocumentSplitController.swift   split view, fold/unfold, auto-fold width
Stitch/Document/Sidebar/SidebarView.swift       rail + switchable panel + selection card
Stitch/Document/Sidebar/RailView.swift          icons, badges, tooltips (also used folded)
Stitch/Document/Sidebar/PagesPanel.swift
Stitch/Document/Sidebar/TodoPanel.swift
Stitch/Document/Sidebar/SignPanel.swift
Stitch/Document/Sidebar/MyInfoPanel.swift
Stitch/Document/Sidebar/HistoryPanel.swift
Stitch/Document/Sidebar/FindPanel.swift
Stitch/Document/Sidebar/SelectionCard.swift     TextFormatBar's controls, moved
Stitch/Engine/TodoFinder.swift                  spots to sign/initial/date + empty fields (pure)
Stitch/Engine/HistoryLog.swift                  entries, cursor, grouping (pure)
Stitch/Engine/FindReplace.swift                 replace a match inside a TextBlock's text (pure)
StitchTests/SidebarTests.swift                  TodoFinder, HistoryLog, FindReplace, AutoFill.plan
```

---

## Step 1 — The split view and the rail
*Size: M. Everything after this depends on it.*

**Actions**
- Add `DocumentSplitController`: a sidebar item (`NSSplitViewItem(sidebarWithViewController:)`, min 200, preferred 278, max 380 pt) and a content item hosting today's `DocumentView`. `DocumentWindowController` sets it as `contentViewController` instead of the plain `NSHostingView`, and `windowWillClose` releases it the same way the hosting view is released today.
- Add `SidebarView` with `RailView` (six buttons and a fold button at the bottom; the active one tinted with the accent) and placeholder panels that show only their title.
- Add `SidebarPanel`, `panel` and `isFolded` to `DocumentUI`. Clicking the active icon folds (`sidebarItem.animator().isCollapsed = true`); clicking any icon while folded opens that panel.
- Folded state: overlay `RailView` on the content's leading edge, below the toolbar and tabs, in a glass capsule (`.glassEffect` behind `if #available(macOS 26, *)`, `.regularMaterial` otherwise). The page stays centered in the full width.
- Toolbar: add `.toggleSidebar` and `.sidebarTrackingSeparator` so the tools sit over the content. My Info ▾ stays in the toolbar until Step 6 replaces it with its panel.
- Commands: a View › Sidebar submenu with Pages ⌘1 … History ⌘5, Find ⌘F (opens the panel for now) and Show/Hide Sidebar ⌃⌘S. (⇧⌘1 is already "Stitch Window"; ⌘0 and ⌘9 are zoom, so ⌘1–⌘5 are free.)
- Auto-fold: on window resize, fold when the window is narrower than 760 pt and unfold again past 820 pt, but only if the person didn't fold it themselves. Raise `window.minSize` width from 520 to 600.
- Remember the open panel and fold state per window (in the controller; nothing is written to disk yet).
- `scripts/winshot.sh document` keeps working and shows the rail.

**Tests:** none new beyond the build; this step is wiring. Run every existing test.

**Done when** a PDF opens with the rail and an empty Pages panel; ⌘1–⌘5 and ⌃⌘S work; folding leaves a floating rail; every existing feature (signing, text boxes, Edit Text, forms, Save Copy, undo, tabs, quit review) works exactly as before; `scripts/winshot.sh document light` and `dark` both look right.

---

## Step 2 — Pages panel
*Size: S.*

**Actions**
- Thumbnails from `pdfView.document` with `PDFPage.thumbnail(of:for:)`, which draws annotations, so placed signatures and text boxes show up. Cache them per page in a small `@MainActor` cache keyed by page index.
- Invalidate only what changed: the pages from `session.onWorkingCopyChanged`, and the overlay's page from `onOverlaysChanged` (compare the old and new overlay lists' pages).
- `LazyVStack` so a 100-page PDF stays instant; 92 pt wide thumbnails, the page number under each, the current page ringed in the accent color (follow `.PDFViewPageChanged`).
- Under each page: "N changes" (overlays plus text edits on that page). The "Initials to do" label arrives with Step 4.
- Click to `pdfView.go(to:)`.

**Done when** the Pages panel scrolls smoothly through a 100-page PDF, follows the current page, and a new signature shows up in its page's thumbnail within a second.

---

## Step 3 — Selection card (the format bar moves)
*Size: S.*

**Actions**
- Move `TextFormatBar`'s controls into `SelectionCard`: size stepper, bold, ink (black, blue, red swatches instead of the popup), white background, delete. Same bindings: `updateSelectedTextBox`, `deleteSelection`.
- Show it pinned at the bottom of the sidebar when `ui.selectedTextBox != nil`, under whichever panel is open; the panel above shrinks to make room.
- Signatures and initials get a card too: a size slider (scales the overlay's rect around its center, one "Resize" undo step when the drag ends) and Delete. Ink color for signatures waits until `Overlay.Kind` carries a color through `StampRenderer`; leave it out for now.
- `ui.selectedTextBox` becomes a more general `ui.selection` (text box, signature or initials) so the card knows which controls to show.
- Keep the floating `TextFormatBar` only when `ui.isFolded`.

**Done when** selecting a text box shows its card in the sidebar and no bar floats over the page; folding brings the floating bar back; every change is still one undo step.

---

## Step 4 — To-Do panel
*Size: L. Needs Step 2 for the page labels.*

**Actions**
- `TodoFinder` (pure, in Engine). Inputs: each page's text blocks (`EditSession.blocks(onPage:)`), its form widgets (name, type, rect, value, whether it's a signature field) and the overlays. Output: `[TodoItem]` in page order, each with a kind (`signature`, `initials`, `date`, `field`), page, rect (PDF user space), label and whether it's done.
  - Signature and initials spots: PDF signature fields, plus text blocks that read like a signature label ("Signature", "Sign here", "Tenant signature", "Initials", "Initial here") next to a run of underscores, or directly under or beside a blank stretch. The spot is the blank stretch.
  - Date spots: "Date" labels in the same rows as a signature spot.
  - Fields: empty text widgets. Checkboxes and radio buttons are left out.
  - Done: a spot is done when an overlay of the right kind overlaps it (or sits within 12 pt); a field is done when it has a value.
  - It will miss some spots on odd layouts. That's acceptable: the panel lists what it finds, and the person still sees the page.
- Recompute on overlay changes, form edits (the existing `textDidEndEditing` observer) and working-copy changes; text blocks are already cached per page.
- Panel: progress bar ("4 of 9 done"), sections Sign and Fill in, a highlighted Next row with a Go button. Return in the panel goes to the next open item. Clicking a row scrolls there and rings the spot for about 1.5 s (a temporary layer over `pdfView.documentView`, never an annotation, so it can't end up in a saved file).
- "Initial all N pages": places initials on every open initials spot, sized to the spot, inside one `undoManager.beginUndoGrouping()` so it's one undo step. One Touch ID prompt for the lot.
- Rail badge: the number left; a green check at zero.
- Banners move here: `ui.banners` render as notes at the top of the panel; the banner overlay in `DocumentView` goes. A new warning also badges the To-Do icon so it isn't missed when another panel is open.
- On open, `ui.panel = .todo` when there's anything to do, else `.pages`.
- Pages panel shows "Initials to do" / "Sign here" under the pages that have open items.

**Tests:** `TodoFinder` on `Fixtures`-built PDFs: a lease page with "Tenant signature ______" and "Date ______" finds two spots; an initials footer on every page finds one per page; a signature overlay over a spot marks it done; a filled widget is done, an empty one isn't; a scanned page (no text) yields only its widgets.

**Done when** opening a real lease lists its signature, date and initials spots and empty fields, Go walks through them, "Initial all" fills every initials spot as one undo, and the count reaches zero when everything is done.

---

## Step 5 — Sign panel and drag to place
*Size: M.*

**Actions**
- Cards for Signature and Initials (rendered with `Signature.draw`), Today (the formatted date) and an empty Text Box. With nothing saved, the card is a "Create Signature…" button that calls `createSignature`.
- Touch ID: cards show blurred with a "Touch ID to show" button until `BiometricGate.authorize` succeeds; after that they stay visible while the window is key and the grace period (`BiometricGate.graceSeconds`) lasts.
- Drag: each card is `.draggable` with an `NSItemProvider` carrying a small Codable payload (`signature`, `initials`, `date`, `textBox`, or `profile(item, addressIndex)` for Step 6) under a private UTType (`com.stitch.place-item`).
- `StitchPDFView` registers for that type: `draggingUpdated` draws a drop preview at the right size (and outlines a signature widget when over one); `performDragOperation` converts the point with `page(for:nearest:)` and `convert(_:to:)`, then calls one new controller entry point, `place(_ item: PlaceItem, page: Int, at point: CGPoint)`.
- Refactor `placeSignature`, `insertDate` and `insertText` to go through `place(...)` with an optional target spot, so the toolbar, menus, Insert shortcuts and drops share one path. Dropping on a signature widget or a To-Do spot fits the item to it.
- Click to arm: clicking a card sets a new `StitchPDFView.Tool.place(PlaceItem)`, with a stamp cursor; the next click on the page places it; Esc cancels.
- "On this document" list: signing overlays with their page; click to jump and select.

**Done when** you can sign the lease by dragging the signature onto the line, initial every page by click-to-arm, and each placement is one undo step; the Sign ▾ toolbar menu and ⌥⌘S still work.

---

## Step 6 — My Info panel
*Size: M. Uses Step 5's drag and `place(...)`.*

**Actions**
- `AutoFill.plan(fields:profile:address:) -> [FieldMatch]` (pure): for each text widget, the matched `ProfileItem`, its value and whether the field is already filled. `fillMatchingFields` uses it instead of its own loop, so the panel shows exactly what Fill will do.
- Make Fill My Info undoable: record each widget's previous value and register one "Fill My Info" undo that restores them (it isn't undoable today, and History in Step 7 needs it).
- Panel: Home / Work (one segment per saved address), then each non-empty detail as a pill (drag or click to insert, through `place(.profile(...))`; dropping a pill on a form field fills that field). Then "Matching fields here" from `plan`, with a "Fill N Matching Fields" button (⌥⌘F). Hovering a match outlines its field on the page.
- "Edit My Info…" opens Settings at Your Info (`SettingsOpener.open(tab: .yourInfo)`).
- Remove My Info ▾ from the toolbar; Fill My Info (⌥⌘F) stays in the Insert menu.
- Touch ID before values show, the same as Step 5.

**Tests:** `AutoFill.plan` on a fixture with Phone, Email, Emergency Contact and an already-filled Email: two matches, one already filled, one unmatched. Fill then undo restores the original values.

**Done when** the panel shows which fields will be filled before you press Fill, Fill and its undo work, and dragging "Email" onto a field fills it.

---

## Step 7 — History panel
*Size: M. Best after Steps 5 and 6, so every change has an entry.*

**Actions**
- `UndoManager` can't list its stack, so `EditSession` keeps its own: `HistoryLog` (pure) holds `[HistoryEntry]` (action name, page, short summary, kind, time) and a cursor. Every place that calls `changed()` also appends an entry; a new change after undos drops the undone entries, matching `UndoManager`.
- Follow undo and redo through `NSUndoManagerDidUndoChange` / `DidRedoChange` for this session's `undoManager` and move the cursor, so ⌘Z, the toolbar and the menu all keep the panel right.
- Summaries: "Signed", "Added “Alex Moreno”", "Changed “24 hours’” to “48 hours’”", "Filled 2 fields from My Info". Consecutive Edit Text changes on one page group into one expandable row ("5 text edits on p. 2"); a group is still several undo steps.
- Panel: oldest first, "Opened the original" at the top, the current entry marked **Now**, undone entries greyed with "⇧⌘Z". Clicking a row undoes or redoes until the cursor is there. Hovering a row outlines its overlay or edited text on the page.
- Save adds a "Saved copy: Name_signed.pdf" milestone; the "Not saved" chip and the rail's dot follow `ui.isDirty`.
- "Revert to Original…" asks first, then undoes everything (one call per step, so it can be redone).
- Typing straight into the PDF's own form fields still isn't an undo step (PDFKit handles it); show those as one "Typed in N fields" entry built from `FormBridge.changes`, without a click-to-go-back.

**Tests:** `HistoryLog`: append, undo, redo, a new change after an undo truncates, grouping of same-page text edits, cursor after a save.

**Done when** the panel matches ⌘Z/⇧⌘Z step for step through a mixed session (signature, text box, Edit Text, fill, delete), clicking an old row steps back to it, and the dot clears after Save Copy.

---

## Step 8 — Find panel
*Size: M.*

**Actions**
- Search with `PDFDocument.findString(_:withOptions:)` on a background-friendly cadence (debounced 200 ms as you type); Aa toggles `.caseInsensitive` off. Results grouped by page, each with about 40 characters of context (`PDFSelection.extend(atStart:)`/`extend(atEnd:)`), the match in bold.
- `pdfView.highlightedSelections` shows every match; the current one is also `setCurrentSelection` + `scrollSelectionToVisible`. ⌘F opens the panel and focuses the field; ⌘G / ⇧⌘G step; Esc clears.
- Replace: for the current match, find the `TextBlock` that contains it (convert the selection's bounds from PDF user space to display space with `MuPDFDocument.PageInfo`), then let `FindReplace` (pure) replace that occurrence inside `block.text` and call `commitText`. Match on the text itself, not on character offsets, since PDFKit's and MuPDF's text can differ slightly (ligatures, spaces).
- Replace All: one undo group and one working-copy rebuild. Add `EditSession.commitTexts(_:)` that takes several block edits and calls `setTextEdits` once.
- On a scanned page (no text blocks) Replace says so instead of failing silently.

**Tests:** `FindReplace`: replace the second "notice" in a block, case-insensitive, with a ligature ("ﬁ") in the block text; no match leaves the block untouched.

**Done when** finding "notice" in a three-page lease lists every match with context, stepping works with ⌘G, and Replace / Replace All change the PDF's text as one undo step each, saved correctly by Save Copy.

---

## Step 9 — Folded rail polish and check
*Size: S.*

**Actions**
- Rail tooltips with name, shortcut and a one-line status ("5 left · next: Emergency contact", "Not saved").
- Edit Text pill above the page while the tool is on (Done button, Esc), replacing the toast.
- Demo states for `scripts/winshot.sh`: `document` (Pages), `document-todo`, `document-sign`, `document-history`, `document-find`, `document-folded`, each light and dark, so the person can check every panel without Screen Recording.
- VoiceOver: rail buttons get labels and their shortcuts; badges are read out ("To-Do, 5 left").
- Update `CLAUDE.md` (Layout: `Stitch/Document/Sidebar/`, the new engine files) and `docs/SIGN-AND-EDIT-PLAN.md` "Later versions" (page tools now go in the Pages panel's hover buttons and context menu).

**Done when** a real lease can be opened, filled, signed, initialled, reviewed in History and saved without touching the toolbar's menus, in light and dark, with the sidebar open or folded.

---

## Risks and how they're handled

- **Finding signature spots on flat PDFs is a guess.** `TodoFinder` stays conservative (labels next to underscores or blanks) and is tested on real-looking fixtures; a miss only means a shorter list, never a wrong change.
- **History drifting from `UndoManager`.** The panel moves its cursor from `UndoManager`'s own notifications instead of guessing, and `HistoryLog` is tested against the same sequences of change, undo and redo.
- **Drag from SwiftUI into an AppKit `PDFView`.** One private UTType, one drop entry point (`place(...)`), and the existing placement geometry (`PageGeometry`, `placement(upright:)`) keep rotated pages right.
- **Thumbnails on long PDFs.** Lazy rendering, a per-page cache, and invalidating only changed pages.
- **Width on a 13-inch screen.** Auto-fold under 760 pt and the floating rail when folded; the sidebar is resizable down to 200 pt.
- **macOS 14–15.** No Liquid Glass: the sidebar and folded rail fall back to `.regularMaterial`; everything else is the same.
