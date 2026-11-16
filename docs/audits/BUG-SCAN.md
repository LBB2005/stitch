# Stitch bug scan: `sign-and-edit` (PR #1)

Scanned at commit `68cfef8` on 2026-11-16. This scan looks only at correctness; a separate session is doing the security audit. Nothing in the source was changed.

**How it was done.** The code was read area by area: Engine, MuPDF and canvas, App/Panel/Views, Document windows, and Sidebar plus Signing. Every High finding and most Medium ones were then re-checked against the source by hand. Where a bug is about logic, small standalone scripts (copies of the real functions) were run to prove it. Those scripts are in the session scratchpad and are not part of the repo.

**Status update, same day.** The security-audit session's uncommitted fixes have since changed some files:
- **H7 is fixed:** `SaveCopy.sameFile` now resolves symlinks, with a test.
- **All other findings are still open.**
- **Line numbers have moved** in the files that session edited. That includes `SaveCopy.swift`, `EditSession.swift`, `StampRenderer.swift`, `StitchMuPDF.c/.h`, `MuPDFDocument.swift`, `OfficeConverter.swift`, `ImageConverter.swift`, `SignatureStore.swift`, `PDFCanvas.swift` and `DocumentWindowController(+Sidebar).swift`. The line numbers below refer to commit `68cfef8`.
- **Changes to know about before fixing the rest:**
  - `SaveCopy.place`/`run` now use `moveItem` plus a retry for fresh names, and check `previousCopy` by file ID.
  - `EditSession.didSave` now takes a file ID, which matters for H1.
  - In `StitchMuPDF.c`, `smu_save`/`smu_place_pdf` changed and there is a new `smu_redact`, which matters for M3 and L5.
  - `OfficeConverter` now runs `soffice` through a `confine()` helper using `sandbox-exec`, which matters for M8 and L15.

- **CONFIRMED** means it was reproduced with a script or test, or proven by reading the whole code path end to end.
- **SUSPECTED** means it is plausible but was not proven.

## Build and tests

- `scripts/build.sh`: **BUILD SUCCEEDED**, with no Swift warnings.
- `scripts/test.sh`, run twice: **112 tests, 2 failures** both times. They are the same two known failures:
  - `PDFEngineTests.testAssembleFollowsPageOrderAndBookmarksEachFile` (EngineTests.swift:108, "XCTUnwrap failed … PDFOutline").
  - `PipelineTests.testMixedMergeNeverTouchesOriginalsOrOverwrites` (EngineTests.swift:245, "nil is not equal to Optional(2)").
- No other failures, and nothing flaky in these two runs.
- The first run's `PDFEngineTests` took **36 s**; the second took 5 s. A cold run that slow may explain the earlier run's 2 extra failures, if any test waits on a timeout.
- **The two "known" failures are a real user-facing bug, not just a test problem.** Merged PDFs get no bookmarks on this macOS. See H3; a fix that works is described there.

## Summary

| # | Severity | Area | Bug | Status |
|---|---|---|---|---|
| H1 | High | Document | Edits made while Save Copy is running get marked as saved, so Quit and Close lose them without asking | CONFIRMED |
| H2 | High | Engine | Shrink-to-fit and OCR drop every annotation except links: filled form fields, comments, Preview signatures | CONFIRMED |
| H3 | High | Engine | Merged PDFs have no bookmarks on macOS 27 (the two "known" test failures) | CONFIRMED |
| H4 | High | Document/Engine | Text-edit rebuilds and Save Copy write the same temp stamp files at the same time; a rebuild that has been superseded is never actually cancelled | CONFIRMED (the race); what breaks depends on timing |
| H5 | High | Document | When rebuilds are superseded, or several undos run in a row, the viewer is refreshed only for the last batch's pages, so other pages show stale text | CONFIRMED |
| H6 | High | App | Pressing Cancel in the menu bar panel still saves the file; a late cancel also yanks the next job off its Working screen | CONFIRMED (reproduced) |
| H7 | High | Engine | `SaveCopy.sameFile` doesn't follow symlinks, so a PDF opened through a symlink can have its original overwritten by Save Copy As | CONFIRMED (script); **fixed, uncommitted** |
| M1 | Medium | Document | `MergeJob` (start window and Combine): a cancelled run can still finish, open a tab, or overwrite the state of the next run | CONFIRMED |
| M2 | Medium | Document | Save and rebuild read the original from its path on disk, not from the snapshot taken at open | CONFIRMED |
| M3 | Medium | Engine | A later text edit's removal can erase letters an earlier edit just stamped | CONFIRMED (by reading MuPDF) |
| M4 | Medium | Engine | Stitch's own invisible OCR text counts as editable text, so Edit Text on a scan doubles the words | CONFIRMED |
| M5 | Medium | Sidebar | To-Do spots are wrong on rotated pages | CONFIRMED (script) |
| M6 | Medium | Sidebar | Replace keeps re-replacing the same match when the replacement contains the search term | CONFIRMED (script) |
| M7 | Medium | Engine | Internal links put back after shrinking point nowhere | CONFIRMED |
| M8 | Medium | Engine | LibreOffice: Cancel doesn't stop an Excel run, and two conversions at once break each other | CONFIRMED |
| M9 | Medium | Engine | Find & Replace eats letters around ligatures (ﬁ, ﬃ) | CONFIRMED (script) |
| M10 | Medium | Engine | Fill My Info uses the tooltip even when the field name says it belongs to someone else | CONFIRMED (script) |
| M11 | Medium | Document | Up to 200 pages of MuPDF text extraction run on the main thread when a document opens | CONFIRMED |
| M12 | Medium | App | A failed Merge or Split from Arrange or Done shows no error | CONFIRMED |
| M13 | Medium | App | The filename field keeps an old name while the file is saved under another one | CONFIRMED (reproduced) |
| M14 | Medium | App | "Left out" warnings stay after the file was converted on a retry | CONFIRMED |
| M15 | Medium | App | Back from Arrange quietly throws away page removals and the custom order | CONFIRMED (may be intended) |
| L1–L25 | Low | various | see the Low section | mixed |

---

## High

### H1. Edits made while a save is running are marked as saved, so Quit loses them without asking. CONFIRMED

- **Where:** `Stitch/Document/EditSession.swift:357-360` (`didSave`), called from `Stitch/Document/DocumentWindowController.swift:445`.
  ```swift
  func didSave(to url: URL) {
      savedCopy = url
      savedChangeCount = changeCount      // the count when the save FINISHES
      savedFormValues = formValues
  ```
- **Why:** the save request is a snapshot taken at `DocumentWindowController.swift:433`, and the copy is rendered in `Task.detached`. Editing stays possible meanwhile; `ui.isSaving` only shows a spinner.
- **To trigger:** on a large PDF, press ⌘S, then add a signature or text box while the spinner is showing.
- **What goes wrong:**
  - When the save finishes, `savedChangeCount` already includes the new signature. "Edited" clears and `isDocumentEdited` turns off.
  - Quit then sees nothing to save and quits, but the signature is not in the copy.
  - History's "Saved" marker lands after that change.
  - The same happens on close. The sheet's Save Copy path (`DocumentWindowController.swift:540-544`) sets `closeConfirmed = true` and calls `performClose` when the save ends, so anything done during that save is dropped with no second prompt.
- **Fix:**
  - Record `changeCount` and `formValues` when the request is built, pass them in as `didSave(to:savedCount:savedForm:)`, and store that snapshot.
  - On the close path, call `refreshDirty()` before `performClose` and ask again if the document is still dirty.

### H2. Shrink and OCR delete every annotation except links. CONFIRMED

- **Where:**
  - `Stitch/Engine/PDFShrinker.swift:49-57`. Pages are redrawn with `CGContext.drawPDFPage` (via `PDFTools.draw`, `PDFAssembler.swift:103-109`), which never draws annotations. `restoreLinks` (`:83-106`) then puts back only `annotation.type == "Link"`.
  - `Stitch/Engine/OCRService.swift:40-41`: `doc.removePage(at: index); doc.insert(replacement, at: index)`. The replacement page has no annotations.
- **To trigger:**
  - Shrink: it is on by default with a 30 MB limit. Merge something over the limit that contains a filled form. That includes Stitch's own Save Copy without "flatten", which keeps form values as widgets. Or a PDF with comments, highlights, text boxes or a Preview signature.
  - OCR: a scanned page that was filled or signed in Preview has no page text, so `needsOCR` is true and the page is replaced.
- **What goes wrong:** the filled values, comments and signatures vanish from the output, with no warning. This was proven by running the real `PDFShrinker.render` on a page with a filled text field and a FreeText box: both were gone.
- **Fix:** before redrawing, flatten annotations into the content. PDFKit's `PDFPage.draw(with:to:)` draws annotation appearances; `drawPDFPage` does not. Alternatively, copy every non-link annotation back the way links are. For OCR, either count annotation text in `needsOCR` or flatten the page's annotations into the replacement. At the very least, warn the user. Note that CLAUDE.md already mentions that redrawing drops annotations; with Sign & Edit producing filled forms, that now loses user data.

### H3. Merged PDFs get no bookmarks on macOS 27. CONFIRMED

- **Where:** `Stitch/Engine/PDFAssembler.swift:72-85` (`addOutline`).
  ```swift
  let doc = try open(src)
  …
  doc.outlineRoot = root
  guard doc.write(to: dst) else { throw Failure.writeFailed }
  ```
- **To trigger:** any merge of 2 or more files.
- **What goes wrong:** on macOS 27.2, writing a PDFDocument that was loaded from a file drops the outline set on it. The output has no `/Outlines` at all. Setting the root first, using GoTo actions, or writing through `dataRepresentation` all fail the same way.
- **This is exactly what the two "known" test failures detect.** It is a real regression for users: "bookmarks each file" is a headline feature in the spec.
- **Fix (proven in a script):** build a fresh `PDFDocument()`, insert copies of the source pages, set the outline on that document, then write it. The output's bookmarks resolve to pages 0 and 2. Once that works, the two tests should pass again.

### H4. Rebuilds and Save write the same temp stamp files at the same time, and a superseded rebuild keeps running. CONFIRMED (the race); what breaks depends on timing

- **Where:**
  - `Stitch/Engine/StampRenderer.swift:34`: `let url = workDir.appendingPathComponent("text-\(edit.id.uuidString).pdf")`, then write, `doc.place(url…)`, then `removeItem(at: url)`.
  - `Stitch/Document/EditSession.swift:318-339` (`rebuildWorkingCopy`).
  - `SaveCopy.render` (`SaveCopy.swift:51-53`), started from `DocumentWindowController.swift:427-435`.
- **Why:**
  - Every rebuild and every save re-renders every text edit into the session's single `workDir`, using the edit's stable id as the file name.
  - `rebuild?.cancel()` cancels only the outer `Task`. The inner `Task.detached` doesn't inherit cancellation, so its `Task.checkCancellation()` in `StampRenderer.apply` never fires, and superseded rebuilds keep writing those same files.
- **To trigger:** edit some text and press ⌘S while the inline editor is still open. `save()` calls `pdfView.commitEditing()`, which starts a rebuild, and `SaveCopy.run` starts right after on the same edits. Quick ⌘Z ⌘Z, or editing several blocks fast, races two rebuilds in the same way.
- **What goes wrong:**
  - One task deletes or rewrites `text-<id>.pdf` while the other is reading it.
  - Outcomes: "Couldn't save the copy", "Couldn't apply the edit", or worse, a save that succeeds but stamps an older rebuild's text (or nothing) where the edit should be.
  - Superseded rebuilds also leave `working-<gen>.pdf` files in the work folder until the tab closes, and burn CPU.
- **Fix:**
  - Use a fresh name for each stamp (`text-\(UUID()).pdf`), or a subfolder per render.
  - Keep the detached task's handle and cancel it (or run the work as a child task), so superseded rebuilds really stop; delete their output when they do.

### H5. A superseded rebuild's pages are never refreshed, so the viewer shows stale text. CONFIRMED

- **Where:** `Stitch/Document/EditSession.swift:318-339`. Each call captures its own `pages`; a superseded call exits at `guard … gen == generation`; the winning call reports only its own pages via `onWorkingCopyChanged?(url, pages)`. `DocumentWindowController.swift:185-192` and `PDFCanvas.swift:108-120` (`replacePages`) then swap only those pages.
- **To trigger:**
  - Edit text on page 1, then on page 3 before the first rebuild finishes.
  - Or use "Revert to Original…" or click an earlier History row (`goToHistory`, `DocumentWindowController+Sidebar.swift:389-402`), which runs `undo()` several times in a row. Every undo except the last is superseded.
- **What goes wrong:**
  - Page 1 keeps showing the old text (or text that was undone), and its thumbnail stays stale.
  - Find searches that stale text.
  - Retyping the same text doesn't help, because `commitText` returns early when the text is unchanged.
  - Save is still correct, since it re-applies every edit, but what is on screen no longer matches what gets saved. A failed rebuild loses its pages the same way.
- **Fix:** keep a `pendingPages: Set<Int>` in `EditSession`. Each call adds its pages to it; on success, pass the whole set and clear it; on failure, keep it.

### H6. Cancel in the menu bar panel still saves the file, and a late cancel derails the next job. CONFIRMED (reproduced)

- **Where:** `Stitch/App/AppModel.swift:415-418` and `430-434`; `Stitch/Engine/Pipeline.swift:100-103`, `125-126`, `164-168`.
  ```swift
  guard let self else { return }
  if Task.isCancelled {
      go(returnScreen, forward: false)   // returnScreen may now belong to a newer job
      return
  }
  ```
- **Why:**
  - Most of a merge's time is spent in steps that never check for cancellation: assemble writing the file, OCR writing, adding bookmarks, opening the result.
  - `Pipeline.merge` then runs `moveItem(at: final.url, to: dest)` with no check before it.
  - Convert to JPEG and per-image Convert to PDF also keep the outputs already written, and the new folder.
- **To trigger:** start a merge of a large PDF, press Cancel, then press Merge again within about a second.
- **What goes wrong:**
  - The cancelled merge still lands in the save folder.
  - When the first job finally unwinds, it calls `go(returnScreen)` while the second job is running. The panel flips from Working to Arrange; the second job's progress updates are dropped (the `screen == .working` guard at line 403); later the screen jumps to Done on its own.
  - The old job's progress can also show on the new job's screen.
  - Reproduced: `screen while job2 is still running: arrange`, `files saved to folder: 2`.
- **Fix:**
  - Give each run an id (`let id = UUID(); jobID = id`); have the progress and completion handlers ignore results whose id no longer matches.
  - In the cancelled branch, just return, since `cancelJob()` already navigated.
  - In `Pipeline`, call `try Task.checkCancellation()` right before every `moveItem` and `writeJPEG`. When a job is cancelled, delete the outputs (and the folder) that job created.

### H7. A PDF opened through a symlink can have its original overwritten by Save Copy As. CONFIRMED (script). FIXED, uncommitted

> **Fixed (uncommitted):** the security-audit session changed `sameFile` to call `standardizedFileURL.resolvingSymlinksInPath()` on both URLs before comparing their file identity, and added a test. The "moved in Finder" variant below is still worth checking.

- **Where:** `Stitch/Engine/SaveCopy.swift:123-131` (`sameFile`). `DocumentController.swift:91` keeps the URL as given: `EditSession(original: url, …)`.
  ```swift
  if let ia = (try? a.resourceValues(forKeys: keys))?.fileResourceIdentifier,
     let ib = (try? b.resourceValues(forKeys: keys))?.fileResourceIdentifier {
      return ia.isEqual(ib)
  }
  ```
- **Why:** the resource values of a symlink URL describe the link itself, not its target, so a symlink and its real file get different identifiers.
- **To trigger:** open `link.pdf`, a symlink to `Lease.pdf` (dragged in, or `open -a Stitch link.pdf`). Then choose Save Copy As…, pick `Lease.pdf` itself and confirm Replace.
- **What goes wrong:** the script shows `sameFile(link, real) == false`. The guard doesn't refuse, and `place` calls `replaceItemAt(real)`, overwriting the original. This breaks the "never overwrite an original" rule; it is the only overwrite path the scan found. (Case-only variants, `./` paths and symlinked parent folders were all handled correctly.)
- **Related, SUSPECTED:** if the original is moved in Finder while the tab is open, the identity lookup on the old path fails and the code falls back to comparing paths. Saving onto the file's new location would then not be refused.
- **Fix:** call `.resolvingSymlinksInPath()` on both URLs before reading `.fileResourceIdentifierKey`. Better still, record the original's file identity once at open and compare against that.

---

## Medium

### M1. A cancelled MergeJob can still finish, open a tab, or overwrite the next run's state. CONFIRMED (code path)

- **Where:** `Stitch/Document/MergeJob.swift:174` (progress guard) and `:197-207`. This is used by the start window and by the Combine panel.
  ```swift
  let outcome = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
  Workspace.remove(workDir)
  guard let self else { return }
  switch outcome {
  case .success(let value):
      result = value; phase = .done; onFinished?(value)
  ```
- **To trigger:**
  - Click Cancel near the end of a merge, after the last `checkCancellation` (during `finalizePDF` or `moveItem`; see H6).
  - Or Cancel, then Merge again right away. LibreOffice inputs or a large assemble make this easy to hit.
- **What goes wrong:**
  - The success branch never checks `Task.isCancelled`. After Cancel (or Clear) the output is written anyway, `phase` becomes `.done`, and `onFinished` opens it: in the start window (taking over the window) or as a new tab from Combine.
  - If a second run has started, the first task's late `phase = .ready` (on `CancellationError`) or `.done` lands in the middle of it. The Merge button re-enables and progress stops updating. The old task's progress updates also pass the `phase == .working` guard.
- **Fix:** add a run token (`runID = UUID()`) and check it in the progress and completion handlers. On a success that arrives after cancellation, delete the outputs and skip `onFinished`. Shares the Pipeline fix in H6.

### M2. Save and rebuild read the original from its path on disk, not the snapshot taken at open. CONFIRMED

- **Where:** `Stitch/Engine/SaveCopy.swift:52` (`MuPDFDocument(url: r.original, …)`) and `Stitch/Document/EditSession.swift:321-327` (the rebuild reads `original`). `EditSession.init` already makes a byte copy, `working-0.pdf` (`:74-77`), which stays for the life of the tab.
- **To trigger:**
  - Move or delete the original in Finder while its tab is open.
  - Or have another app overwrite it.
  - Or rename it from the title while a rebuild or save is in flight; both captured the old path.
- **What goes wrong:**
  - Moved or deleted: Save Copy fails. In the quit review, "Save Copies" replies false, so the only way out is Don't Save, which loses everything.
  - Overwritten: overlays and text edits placed against the old layout are applied to the new content, so the copy doesn't match what was on screen.
  - Renamed mid-flight: that rebuild or save fails.
- **Fix:** render and rebuild from `workDir/working-0.pdf` (with the same password). Use `original` only for naming and for picking the folder.

### M3. A later text edit's removal can erase letters an earlier edit just stamped. CONFIRMED (by reading MuPDF)

- **Where:** `Stitch/Engine/StampRenderer.swift:27-41`. Each edit runs `removeText`, then `place`, one edit after another.
- **Why:** MuPDF's redaction filter sets `instance_forms = 1` (vendor `pdf-clean.c:1110`), so it recurses into Form XObjects. Edit B's removal therefore also filters the `StitchStampN` form that edit A just placed.
- **To trigger:** edit block A so its new text grows into block B (or edit a block that sits very close to its neighbour), then edit block B.
- **What goes wrong:** the letters of A's new text that touch B's removal bands disappear, both in the viewer and in the saved copy.
- **Fix:** for each page, run all the removals first, then place all the stamps.

### M4. Stitch's own invisible OCR text counts as editable text. CONFIRMED (by reading)

- **Where:**
  - `Stitch/Engine/MuPDF/StitchMuPDF.c:125-154` (character extraction).
  - `Stitch/Engine/TextLayout.swift:69-100`.
  - `Stitch/Document/PDFCanvas.swift:381-384`.
  - `OCRService.swift:91` draws the OCR text in invisible render mode, and MuPDF's stext device still records it.
- **To trigger:** open a scan that Stitch made searchable and use Edit Text on it.
- **What goes wrong:**
  - The "This page is a scan…" hint never shows, because the page appears to have text.
  - Editing a line removes the invisible glyphs and stamps visible black text on top of the scanned image, whose words are still there. The words appear twice.
- **Fix:** pass the character's alpha up from the shim (`argb >> 24 == 0` means invisible) and leave invisible characters out of editable blocks. Keep them for Find.

### M5. To-Do spots are wrong on rotated pages. CONFIRMED (script using the real `TodoFinder.swift`)

- **Where:** `Stitch/Document/Sidebar/DocumentWindowController+Sidebar.swift:72` passes user-space line rects with no rotation (`line.rect.applying(info.toUserSpace)`). `Stitch/Engine/TodoFinder.swift:130, 154-157, 169-171` assumes text runs along +x and that "above" means +y.
- **To trigger:** a page with `/Rotate 90` containing the line `Signature: ________`.
- **What goes wrong:**
  - Unrotated, the spot is correct: `(187.8, 280, 84×28)`.
  - Rotated, it comes out as `(72, 507, 200×5)`: the whole line including the label, 5 pt tall.
  - To-Do Sign and Initial then place the signature over the label, shrunk to 40%. Drop-snapping and the above/beside blank-space checks are wrong too.
- **Fix:** run `TodoFinder` in an upright frame (display space with y flipped, page size `info.displaySize`). Convert widget rects into that frame, then map the resulting spots back with `toUserSpace`.

### M6. Replace keeps re-replacing the same match when the replacement contains the search term. CONFIRMED (script)

- **Where:** `DocumentWindowController+Sidebar.swift:470-472`. After a replace, `runFind(keep: true)` keeps `current = min(previous, count-1)`. The replace itself is at `:536-553`.
- **To trigger:** Find "fee", replace with "fees", press Replace three times. "Inc" → "Inc." or a case-only change with case-insensitive search does the same.
- **What goes wrong:** you get `fees` → `feess` → `feesss`. The match count stays the same and the cursor never moves on.
- **Fix:** after `replaceCurrent`, move `current` to the first match that starts after the end of the inserted text.

### M7. Internal links put back after shrinking point nowhere. CONFIRMED (with the real `render`)

- **Where:** `Stitch/Engine/PDFShrinker.swift:94-96, 105`.
  ```swift
  link.destination = PDFDestination(page: target, at: dest.point)
  …
  if added { guard shrunk.write(to: dst) … }
  ```
- **To trigger:** shrink a merge that contains internal links, such as a table of contents.
- **What goes wrong:** this is the same macOS 27 PDFKit write problem as H3. The written link becomes `/Dest [ /#23233 /XYZ … ]` and reads back as "Go to page (null)". Web links survive. Links on rotated pages are skipped entirely (`from.rotation == 0`).
- **Fix:** add the links on a fresh `PDFDocument` built from page copies; proven to resolve. Also subtract the crop-box origin from `dest.point`, as the code already does for the link's bounds.

### M8. LibreOffice: Cancel doesn't stop an Excel conversion, and two conversions at once break each other. CONFIRMED (code path plus a real LibreOffice run)

- **Where:** `Stitch/Engine/OfficeConverter.swift:58-81, 137-163`.
- **Cancel:**
  - Cancelling during the fit-to-width macro run kills it. `run` then returns `false`, and `convert` falls through and starts a second `--convert-to` run.
  - That second run starts with the task already cancelled. `withTaskCancellationHandler` calls `onCancel` before `process.run()`, while `isRunning` is false, so the process is never terminated and runs to completion (up to 180 s).
  - For Word and PowerPoint, the resulting `Failure.failed` reaches `Pipeline.prepare`'s generic catch and is reported as "LibreOffice couldn't convert it", not as a cancellation.
- **Shared profile:**
  - Every run uses the same `-env:UserInstallation` profile. Two conversions run at the same time: the second exited with status 1 and wrote nothing.
  - This happens when the menu bar panel and a window's Combine both convert Office files, or when a new job starts while the leftover run from a cancel is still going.
- **Fix:**
  - Call `try Task.checkCancellation()` before each `Process` launch and again after `run()` returns.
  - Turn a terminated-on-cancel exit into `CancellationError`.
  - Re-check `Task.isCancelled` right after `process.run()` and terminate if needed.
  - Run conversions one at a time through a shared actor or lock, or give each run its own profile folder.

### M9. Find & Replace eats letters around ligatures. CONFIRMED (script)

- **Where:** `Stitch/Engine/FindReplace.swift:30`: `let lo = back[i], hi = back[i + q.count - 1] + 1`.
- **To trigger:** replace inside text that contains a ligature character.
- **What goes wrong:** a match that starts or ends partway through an expanded ligature replaces the whole ligature character:
  - "ﬁsh market", replace "ish" with "ash" → "ash market".
  - "oﬃce", replace "of" with "for" → "force".
- **Fix:** reject matches whose start or end falls inside a ligature, or keep the leftover expanded letters on either side of the replacement.

### M10. Fill My Info puts your details into someone else's field. CONFIRMED (script)

- **Where:** `Stitch/Engine/AutoFill.swift:101`: `guard let item = match(field.name) ?? field.toolTip.flatMap(match) else { return nil }`. `match` returns nil both for "no match" and for "this field is about someone else" (`:20`).
- **To trigger:** a field named `Guardian_Phone[0]` with the tooltip "Phone number".
- **What goes wrong:** the field is filled with your phone number. Any `emergency…`, `parent…` or `spouse…` field with a generic tooltip behaves the same way.
- **Fix:** make `match` return a three-way result (matched, excluded, no match). Don't consult the tooltip when the name was excluded.

### M11. MuPDF text extraction runs on the main thread for up to 200 pages when a document opens. CONFIRMED (by reading)

- **Where:** `DocumentWindowController+Sidebar.swift:62-70` (`refreshTodo`), reached from `DocumentWindowController.swift:170` in `init`. It calls `session.blocks(onPage:)`, which runs `smu_page_chars` on the shared document on the main actor.
- **To trigger:** open a long or text-heavy PDF.
- **What goes wrong:** the window freezes for seconds. Hovering in Edit Text mode also extracts each page on the main thread the first time.
- **Fix:** extract text in the background with its own `MuPDFDocument` (MuPDF contexts are per thread), then hand the cached blocks back to the main actor and refresh To-Do.

### M12. A failed Merge or Split from Arrange or Done shows no error. CONFIRMED

- **Where:** `Stitch/App/AppModel.swift:444-447` (`fail`). `banner` is only drawn on Home (`HomeView.swift:46, 111`).
- **To trigger:**
  - Merge from Arrange when the save folder is gone, for example an unplugged drive. The folder is only checked at launch (`Preferences.swift:56`).
  - Or when a source was moved, or the disk is full.
  - Or a Split into Parts that fails.
- **What goes wrong:** you are sent back to Arrange or Done with no explanation. If the panel was closed, there is no notification either, because `finish` only posts on success.
- **Fix:** draw `BannerView` on Arrange and Done as well, and post a notification on failure when the panel is closed.

### M13. The filename field keeps an old name while Stitch saves under another one. CONFIRMED (reproduced with a real NSTextField)

- **Where:** `Stitch/Views/AppKitBridges.swift:27-29`: `if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }`.
- **Why:** the field gets keyboard focus as soon as files are added, and stays mid-edit even while the panel is hidden. So name changes coming from the model never reach the field.
- **To trigger:** drop Lecture 1–3, then drop Lecture 4. Or use Save to… with a new name.
- **What goes wrong:**
  - The field shows "Lecture 1–3.pdf" while the file is saved as "Lecture 1–4.pdf".
  - After Save to…, the field still shows the old name next to "Final.pdf".
  - Typing one character then sends the stale text back and silently undoes the Save to… choice.
- **Fix:** remember the last value the coordinator sent up. When `text` differs from both that value and what the field shows, write it into the field editor and keep the selection.

### M14. "Left out" warnings stay after a retry succeeds. CONFIRMED

- **Where:** `Stitch/App/AppModel.swift:255-256`. `skipped.merge(value.skipped) { $1 }` only ever adds entries.
- **To trigger:** the path the LibreOffice banner itself suggests. Add a PDF and a .docx with LibreOffice missing and press Merge, so the docx is skipped. Go back, install LibreOffice, press Merge again.
- **What goes wrong:** the docx is in the grid, but Arrange, Done and its Home row still say "Left out: report.docx (needs LibreOffice)".
- **Fix:** after preparing, `for id in value.prepared.keys { skipped[id] = nil }`.

### M15. Back from Arrange throws away page removals and the custom order. CONFIRMED (may be intended, but it happens silently)

- **Where:** `Stitch/App/AppModel.swift:265-266`. `showArrange()` always calls `rebuildArrangement(keepingRemovals: false)`.
- **To trigger:** on Arrange, remove some pages and reorder others. Go Back to switch on "Make scans searchable" or "Shrink" (those switches only exist on Home), then press Merge again.
- **What goes wrong:** removed pages come back and the custom order is lost, which makes it easy to merge pages you meant to leave out.
- **Fix:** keep the current arrangement when the set of prepared files hasn't changed. When files were added or removed, keep the removals and order for the files that are still there.

---

## Low

**L1. Choosing "Don't Save" while a save is running deletes the work folder under it.** CONFIRMED.
- Where: `DocumentWindowController.swift:524-554` (`windowShouldClose`) ignores `ui.isSaving`, and `tearDown` → `session.close()` → `Workspace.remove(workDir)`.
- Trigger: press ⌘S then ⌘W at once, and choose Don't Save in the sheet.
- What goes wrong: the ⌘S copy is never written, and its error toast goes to a window that no longer exists.
- Fix: if a save is running, queue the decision on `saveWaiters`, or defer the folder removal until no save is running.

**L2. Undoing back to the saved state still shows "Edited".** CONFIRMED.
- Where: `EditSession.swift:118`. `changeCount += 1` runs on undo and redo too.
- What goes wrong: add a box, undo it, and the window still shows "Edited"; Close and Quit offer to save an unchanged copy. Nothing is lost.
- Fix: a counter that goes up on do and redo and down on undo, or compare History's cursor with its cursor at the last save.

**L3. Recent files that are renamed or moved in Finder drop out of the list.** CONFIRMED.
- Where: `DocumentController.swift:299, 325`. `prefs.recentBookmarks = recents.compactMap { try? $0.bookmarkData() }` re-creates bookmarks from plain URLs.
- What goes wrong: a recent file renamed or moved during the session fails `bookmarkData()` and is dropped for good, which defeats "bookmarks follow renames". `refreshRecents` (`:331`) also just filters such files out.
- SUSPECTED: `resolve` (`:315`) doesn't pass `.withoutMounting`, so a recent file on an unplugged share can stall launch while macOS tries to mount it.
- Fix: keep the bookmark data alongside each URL, re-resolve it instead of re-creating it, refresh stale bookmarks, and add `.withoutMounting`.

**L4. ⌘K's highlighted row jumps back to the top whenever Spotlight results update.** CONFIRMED.
- Where: `CommandBar.swift:197`: `if !q.isEmpty { selection = 0 }` runs on every `update()`.
- What goes wrong: arrow down, a Spotlight update arrives, and Return runs a different item.
- Fix: reset the selection only when the query changes, and keep it on the same item id when results update.
- Minor: `SpotlightSearch.stop()` (`:321`) doesn't cancel `pending` (`:281`).

**L5. Editing a line deletes links and comment boxes that touch it.** CONFIRMED (by reading MuPDF).
- Where: `pdf_redact_page_links` and `pdf_redact_page_annotations` in vendor `pdf-clean.c:1029-1074`, reached from `smu_remove_text`.
- What goes wrong: editing a paragraph that holds a hyperlink drops the link silently, in the working copy and in the saved copy.
- Fix: in the shim, keep the page's Link and FreeText annotations before redacting and put back any that were removed.

**L6. On pages rotated 90° or 270°, a new text box opens offset from the click.** CONFIRMED (script).
- Where: `DocumentWindowController.swift:293-297`. The 90° case uses `point.x - size.width * 0.75` and the 270° case uses `0.25`.
- What goes wrong: the click lands 75% of the way down the box instead of 25%.
- Fix: swap the two factors (90° → 0.25, 270° → 0.75). `PageGeometry` itself is correct.

**L7. `char_list list` in `smu_page_chars` is not volatile.** CONFIRMED (by reading).
- Where: `StitchMuPDF.c:174`. It is modified inside `fz_try` and freed after the catch.
- What goes wrong: undefined behaviour under the setjmp rules, which also breaks the shim's own rule. The realistic worst case is a leak.
- Fix: declare it `volatile` or use `fz_var`.

**L8. A Keychain error on delete is ignored.** CONFIRMED.
- Where: `SignatureStore.swift:91-93`, where `SecItemDelete`'s status is discarded. `deleteAll()` (`:174-184`) then reports "Removed".
- What goes wrong: if the delete is refused, the signature comes back on the next launch.
- Fix: check the status, treat `errSecItemNotFound` as success, and show "Removed" only when it worked.

**L9. One Keychain problem blocks placing a different item.** CONFIRMED.
- Where: `DocumentWindowController+Sidebar.swift:235-241` checks the store-wide `SignatureStore.shared.problem`.
- What goes wrong: an unreadable profile stops ⌥⌘I or To-Do "Initial", which shows the profile's error instead of offering to create initials.
- Fix: track problems per account.

**L10. My Info shows stale matches, and can fill a different address from the one shown.** CONFIRMED.
- Stale matches: `fieldMatches` is only recomputed on the panel's `onAppear` (`MyInfoPanel.swift:57`). Details added in Settings while the panel is open don't show up. Fix: `.onChange(of: store.profile)`.
- Address mismatch: the panel clamps the address index (`:30, 39-40`), but `chosenAddress` (`+Sidebar.swift:216-220, 343`) returns nil when the index is out of range, which falls back to the unfiltered `addresses.first` (`Profile.swift:40`). After an address is deleted, the pills show one address and Fill uses another.
- Also, a blank first address hides every address pill (`:62`).
- Fix: clamp the index the same way everywhere, and fall back to the first non-empty address.

**L11. Combine's "Add this PDF" can add an out-of-date saved copy without saying so.** CONFIRMED.
- Where: `CombinePanel.swift:19` (`session.savedCopy ?? session.original`); the tooltip at `:225-227` only warns when `savedCopy == nil && isDirty`.
- What goes wrong: after one save and further edits, the older saved copy is added and the newer edits are silently missing.
- Fix: warn whenever the tab is dirty.

**L12. Page thumbnails don't update after typing in a form field.** CONFIRMED.
- Where: the `textDidEndEditing` observer at `DocumentWindowController.swift:150-159` never calls `thumbnails.invalidate([page])`.
- Fix: invalidate that page's thumbnail in the observer.

**L13. "Birth" always means date of birth.** CONFIRMED.
- Where: `AutoFill.swift:24`.
- What goes wrong: "Place of Birth", "City/Country of birth" and "Birth Name" get your date of birth.
- Fix: require "date" or "dob", or exclude place, city, country and name.

**L14. Very wide CSVs lose cell text.** CONFIRMED.
- Where: `CSVConverter.swift:227-259`.
- What goes wrong: past about 150 columns, a column's usable width goes negative and each cell draws only its first character. Between about 45 and 120 columns, numbers wrap a digit or two per line.
- Fix: below a minimum column width, split the columns into bands across pages.

**L15. The Excel fit step never falls back when it times out.** CONFIRMED.
- Where: `OfficeConverter.swift:66`. `try await run(...)` throws `timedOut` straight out of `convert`.
- What goes wrong: the plain `--convert-to` fallback the comment promises is skipped, after a 3-minute wait.
- Fix: use `try?` there and fall through to the fallback.

**L16. Smart ordering mishandles some digit runs.** CONFIRMED.
- Where: `SmartOrder.swift:83`: `Int(digits.suffix(18)) ?? Int.max`.
- What goes wrong: full-width and Arabic-Indic digits all become `Int.max`, so "講義１, 講義２, 講義１０" isn't ordered as a series. Runs longer than 18 digits are compared by their last 18 digits only.
- Fix: read digits with `Character.wholeNumberValue`; compare long runs by length, then by text.

**L17. History summaries say "Removed" or "Added" for a change inside a word.** CONFIRMED (cosmetic).
- Where: `HistoryLog.swift:122, 130`.
- What goes wrong: "48 hours" → "48 hour" reads "Removed “hours”".
- Fix: widen both sides of the change to the same word boundaries.

**L18. Two jobs at once can overwrite each other's JPEG output.** SUSPECTED.
- Where: `ImageConverter.swift:70`. `CGImageDestinationCreateWithURL` overwrites, unlike the PDF path's `moveItem`.
- What goes wrong: two jobs (menu bar and Combine) choosing the same name in the same folder at the same moment could overwrite one output. Never an original.
- Fix: write to the work folder, then `moveItem` into place.

**L19. Double-clicking Merge or Split can leave the panel stuck on Working.** SUSPECTED.
- Where: `AppModel.swift:399` sets `returnScreen = screen` with no guard.
- What goes wrong: a second call during the 0.28 s slide saves `.working` as the return screen, and Cancel can't leave it.
- Fix: `guard screen != .working` at the top of `run`.

**L20. Wrong panel height on multiple displays.** SUSPECTED.
- Where: `PanelController.swift:218` takes the height limit from `panel?.screen`, while the anchor comes from the status item's display.
- Fix: use the anchor's screen for both.

**L21. Some drops onto the menu bar icon do nothing, with no message.** CONFIRMED.
- Where: `PanelController.swift:114-122` and `AppModel.swift:91, 494-501`.
- What goes wrong: a drop during a running job is accepted but ignored; a folder with no supported files adds nothing and shows no toast.
- Fix: show a toast in both cases and reject the drop during a job.

**L22. "Open at login" can show the wrong state and a misleading error.** SUSPECTED.
- Where: `SettingsView.swift:69-82`, `Services.swift:40`.
- What goes wrong: a `.requiresApproval` status shows the switch On but it reads Off next time, with no hint. Every error says "install in Applications first", whatever the real cause.
- Fix: handle `.requiresApproval` explicitly and show the real error.

**L23. Temp files from the menu bar pile up for the whole session.** CONFIRMED.
- Where: `AppModel.swift:380-389, 463`.
- What goes wrong: every merge attempt (merged, OCR, shrunk-300/220/150, bookmarked copies, including cancelled and failed runs) shares one work folder that is only cleared by Start Over or Quit. For a menu bar app left running for weeks, that adds up.
- Also: quitting from the icon's menu during a job doesn't ask first, since `applicationShouldTerminate` only checks document windows.
- Fix: one subfolder per run, keeping `overLimit.best` until Start Over because Split needs it.

**L24. Debug demo runs write to the real app's settings and Recent list.** CONFIRMED (by reading).
- Where: `StitchApp.swift:138` uses its own suite only under XCTest. Demo runs use `.standard`, and the Debug and installed builds share the bundle ID `com.liamblackshawbrown.Stitch` (`project.yml:51`).
- What goes wrong: `-StitchDemo app-flow` (and any demo that opens files) adds its temp files (`StitchFlow/Lease signed.pdf`, the merged output) to the real Recent list. I didn't run app-flow for that reason; the installed Stitch was running.
- Fix: under `-StitchDemo`, use `UserDefaults(suiteName: "StitchDemo")`, as the test host does.

**L25. Working copies from earlier rebuilds are deleted while their pages may still be on screen.** SUSPECTED.
- Where: `EditSession.swift:340`.
- What goes wrong: `replacePages` swaps only the changed pages, so the other pages still come from the old file. That is safe only while PDFKit keeps the deleted file open; one check suggests it does.
- Fix: keep the working copies until the tab closes.

### Other suspicions, not proven
- `TextLayout.swift:30-31`: the line pitch `(last.baseline - first.baseline)/(n-1)` can come out 0 or negative if MuPDF puts two runs on the same baseline into one block, so wrapped lines would overlap. Use the median of the positive gaps, or 1.2 × the font size.
- `SaveCopy.swift:57`: `resolveFieldName` returns nil for an ambiguous short name (`Home.City` and `Work.City`), and that typed value is silently skipped on save.

## Checked and found fine
- **Originals:** no path in the merge or convert pipeline writes over an input. Office files are converted from a copy. Opening never writes. Rename refuses collisions, including case-only renames. `protected` covers other tabs' originals. (The exception is H7.)
- **Pipeline:** the order assemble → OCR → shrink → bookmarks, the 300 → 220 → 150 DPI ladder (never lower), OCR stretching via the font matrix, and the page indexes in `assemble` and `Arrangement`.
- **CSV parsing:** quoted newlines, CRLF and BOM.
- **MuPDF shim:** every call is inside `fz_try`/`fz_catch`, allocations and frees match (apart from L7), each background task opens its own document, and the shared one is used only on the main thread.
- **Coordinates:** `PageGeometry.uprightTransform`/`stampTransform` checked numerically for 0, 90, 180 and 270, and crop-box origins come out right.
- **Retain cycles:** none found. Monitors and observers are removed, `tearDown` releases the SwiftUI hosts, the ⌘K panel is freed, and job and toast tasks hold `self` weakly.
- **Window lifecycle:** handing the window back to the start view resets the title, represented URL and edited dot. The quit review replies exactly once on every path.
- **Signing:** Touch ID resumes on the main actor. Keychain save does update, then add on `errSecItemNotFound`. The signature pad has no division by zero, and single-point strokes are rejected.
- **History grouping:** grouping in `batch` is correct; typing in text fields uses the field editor's own undo manager and doesn't move History.

## Suggested order to fix
1. **H1, H4, H5:** the save and rebuild pipeline. These are related; fixing H4's cancellation and file naming plus H5's `pendingPages` together is one focused change in `EditSession`, `StampRenderer` and `DocumentWindowController.save`.
2. **H3 and M7:** write outlines and links on a fresh `PDFDocument`. This also turns the two failing tests green.
3. **H2:** flatten or copy annotations when shrinking and OCR'ing.
4. **H6 and M1:** run tokens plus `checkCancellation()` before the final moves in `Pipeline`.
5. **H7:** resolve symlinks in `sameFile`, or store the original's identity at open.
6. The Medium items, then the Low ones as polish.
