# Stitch security audit

**Scope:** the whole app on branch `sign-and-edit` at commit `68cfef8` (PR LBB2005/stitch#1), plus the installed `/Applications/Stitch.app`, the Debug and Release builds in `build/DerivedData`, the login Keychain items Stitch created, and the pinned MuPDF submodule (`vendor/mupdf`, tag 1.28.6). Audited on 2026-11-16. I only read code and inspected built binaries. Nothing was built, run or edited.

**Threat model.** Stitch is a personal app on one Mac with one user. The realistic attackers are:

1. **A hostile document.** A PDF, Office file, CSV or image that someone sends you and you open, merge or sign. This is the main way in from outside.
2. **Other code running as you.** A malicious npm/pip package, a dodgy app, a browser exploit. It can already read your files. The Keychain is the one thing it shouldn't get for free.
3. **Someone at your unlocked Mac.** A roommate or a classmate. Touch ID gating exists to stop them.
4. **Leaks in what Stitch writes.** Saved copies, temp files, preferences, metadata.

**Overall verdict.** There are no critical or high-severity issues. The C shim is careful, originals are well protected, nothing is logged, there are no secrets in the repo, and Stitch makes no network calls of its own. The main weak spots:
- The Release build is easy to inject into. That undoes the Keychain's per-app protection.
- Password-protected PDFs come out unencrypted.
- MuPDF has upstream fixes that haven't been released yet, and the build script wouldn't pick up an update anyway.

## Summary

| # | Severity | Finding |
|---|---|---|
| M1 | Medium | The Release app ships with `get-task-allow` and without hardened runtime, so any process running as you can attach to Stitch or inject a library and read the signature and details from the Keychain without a prompt |
| M2 | Medium | Saving a password-protected PDF writes an **unencrypted** copy next to the original (and decrypted working copies to temp) |
| M3 | Medium | MuPDF 1.28.6 misses upstream fixes already on the 1.28.x branch (including the CVE-2026-112036 double free), and `build-mupdf.sh` would keep linking stale libraries after a submodule bump |
| L1 | Low | LibreOffice conversions run with default macro and link settings and can reach the network |
| L2 | Low | Clicking a page in the Select tool follows the PDF's own link annotations (any URL scheme, including `file://`) with no confirmation |
| L3 | Low | Touch ID gating is weaker than the spec says: Settings shows the signature without it, and with the 5-minute grace a window never locks again |
| L4 | Low | A crafted PDF can hide or move a stamped signature in the saved copy (unbalanced `q`/`Q`), while the on-screen preview looks right |
| L5 | Low | "Cover and retype" with a white text box doesn't remove what's underneath |
| I1–I6 | Info | Hardening notes (see the end) |

## Fix status (2026-11-16, after the audit)

| # | Status | What changed |
|---|---|---|
| M1 | Fixed | `project.yml` Release config: `ENABLE_HARDENED_RUNTIME: YES`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`. `scripts/install.sh` warns if the installed app isn't hardened. Takes effect at the next `scripts/install.sh` (one Keychain prompt for the new build). |
| M2 | Fixed | `smu_open` records whether a password was needed. `smu_save` then writes `PDF_ENCRYPT_KEEP`, so saved copies and working copies keep the password. The working-copy reload unlocks with the session's password. |
| M3 | Fixed | `vendor/mupdf` moved to the `1.28.x` maintenance branch head (`464c506fc`, 53 fix commits past 1.28.6, including CVE-2026-112036). `.gitmodules` tracks `branch = 1.28.x`. `build-mupdf.sh` rebuilds whenever the submodule commit differs from `build/mupdf/REV`. Move to 1.28.7 once it's tagged. |
| L1 | Fixed | soffice runs under `sandbox-exec` with IP networking denied and gets a minimal environment. The profile is forced to `MacroSecurityLevel=3` and `BlockUntrustedRefererLinks=true`. The macro loads with `MacroExecutionMode=0` and `UpdateDocMode=0`. |
| L2 | Fixed | `StitchPDFView` is its own `PDFViewDelegate`. Only http, https and mailto links open, after an alert showing the URL. Anything else is refused with a toast. |
| L3 | Fixed | Settings → Signatures needs Touch ID to show, change or delete. Replacing a signature from a document asks for Touch ID. Creating a signature no longer unlocks My Info. The pad only pre-fills your name after Touch ID. With grace on, panels lock again when the grace runs out. The `isTesting` bypass is `#if DEBUG` only. The spec wording now matches. |
| L4 | Fixed | `smu_place_pdf` runs the page through a MuPDF processor that counts unclosed `q` and `BT` and closes them before the stamp. |
| L5 | Fixed | Before a white-background text box is stamped, `smu_redact` removes the text, image pixels and covered drawings under it. The hint says Save Copy removes what's under the box. |
| I1, I2, I6 | No change | They need same-user access, or are inherent to the feature. After M1 and L3, flipping `touchIDGrace` only stretches a genuine Touch ID to 5 minutes. |
| I3 | Fixed | Fresh names are written with a move that fails if the name was taken meanwhile (it retries the next name). A later save only replaces its own earlier copy, checked by volume and inode (`SaveCopy.FileID`). |
| I4 | Fixed | Images are limited to JPEG, PNG, HEIC/HEIF, TIFF, WebP, GIF, BMP, AVIF and camera RAW. Remove location also strips IPTC city, area and country. |
| Bug scan H7 | Fixed | `SaveCopy.sameFile` resolves symlinks first, so Save Copy As can't replace an original opened through a symlink, nor the reverse. |
| I5 | Partly | Tables over 2,000,000 cells are refused. `smu_open` checks `calloc`. There's still no MuPDF memory cap (a hostile PDF can still be slow). |

Tests for the fixes are in `StitchTests/SecurityTests.swift`.

---

## Medium

### M1 — Release build allows debugger attach and library injection, bypassing the Keychain ACL

**Where:** `project.yml:54` (`ENABLE_HARDENED_RUNTIME: NO`, for every configuration). Xcode's default `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` adds `com.apple.security.get-task-allow`. Verified with `codesign -d --entitlements -`:
- `/Applications/Stitch.app` and the Release build both carry `get-task-allow = true` with code-signature flags `0x0(none)`, so there's no runtime hardening.
- The saved items' ACL (`security dump-keychain -a`, attributes only) trusts only `/Applications/Stitch.app`, partition `cdhash:0d73a737…`. That is good on its own.

**Attack.** Malware running as you can do either of these:
- Run `lldb -p $(pgrep -x Stitch)`. `get-task-allow` lets any same-user process take Stitch's task port with no root and no prompt. It then reads `SignatureStore.shared` from memory. `SignatureStore.init` → `reload()` (`Stitch/Signing/SignatureStore.swift:125-136`) decrypts all three items at launch, before any Touch ID.
- Launch `/Applications/Stitch.app` with `DYLD_INSERT_LIBRARIES=evil.dylib`. Without hardened runtime, dyld honours it. The injected code runs *as* the trusted cdhash, so `SecItemCopyMatching` returns the signature, initials and profile silently.

**Impact.** The Keychain's per-app ACL is the only thing that stops same-user malware from reading your signature vectors, name, email, phone, student ID, date of birth and addresses without a prompt. This cancels it. That data is enough to forge your signature on documents and for identity fraud.

**Fix.** Harden Release only. The test-host problem in the comment is a Debug-only concern:
```yaml
    configs:
      Release:
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO   # no get-task-allow in the installed app
```
Stitch links MuPDF statically and loads only system frameworks, so library validation won't break it. LibreOffice runs as a separate process and isn't affected. After `scripts/install.sh`, check that `codesign -dvv /Applications/Stitch.app` shows `flags=0x10000(runtime)` and the entitlements are empty. The first launch of the new cdhash will show one Keychain prompt.

### M2 — Password-protected PDFs are saved without their password

**Where:** `Stitch/Engine/MuPDF/StitchMuPDF.c:87` (`opts.do_encrypt = PDF_ENCRYPT_NONE`), used by:
- `SaveCopy.render` (`Stitch/Engine/SaveCopy.swift:52-65`) for the saved copy.
- `EditSession.rebuildWorkingCopy` (`Stitch/Document/EditSession.swift:321-329`) for `working-N.pdf` in the temp folder.

**Attack / scenario.** You open a bank statement or medical form that needs a password, type the password, sign it, and press ⌘S. `Statement_signed.pdf` lands next to the original, often in Downloads or an iCloud/Dropbox folder, **with no encryption**. Anyone who later gets that folder, or a cloud-sync leak, reads it without the password. Nothing in the UI says the protection was dropped. After a Text edit, the decrypted working copies also stay in `$TMPDIR/Stitch/<pid>/…` until quit, or until the next launch if Stitch crashes.

**Impact.** The document silently loses its confidentiality protection. This is the opposite of what you'd expect from "Save Copy".

**Fix.** In `smu_save`, use `PDF_ENCRYPT_KEEP` when the document was encrypted. MuPDF 1.28 supports this for full rewrites (`pdf-write.c:2676`, `opts->crypt = doc->crypt`). Expose it as a flag:
```c
int smu_save(smu_doc *doc, const char *path, int keep_encryption, char *err, int errlen);
// …
opts.do_encrypt = keep_encryption ? PDF_ENCRYPT_KEEP : PDF_ENCRYPT_NONE;
```
Pass `keep_encryption = (password != nil)` from `SaveCopy`. Keep `NONE` for the temp working copies only if PDFKit needs them decrypted, and accept that they're temporary. If you'd rather offer the choice, make Save show "Keep the password / Remove it", defaulting to keep.

### M3 — MuPDF: unreleased upstream fixes, and the build never rebuilds after a bump

**Where:** `vendor/mupdf` at tag `1.28.6` (`da5f5eb89`) and `scripts/build-mupdf.sh:9`.

**Details.**
- 1.28.6 is the newest *release*, but `origin/1.28.x` already has fixes that came after it. The ones that matter for security:
  - **Bug 709768 / CVE-2026-112036** (`4d1565c1d`, double free in `free_char_list`, `source/pdf/pdf-xref.c:4173`). The local copy still lacks `c->list = NULL`.
  - **Bug 709822** (overread in `skip_language_code_utf8`).
  - **Bug 709806** (bad `/Indices`).
- I traced CVE-2026-112036's path to `pdf_validate_changes` and signing (`pdf-signature.c:212`, `pdf-xref.c:5119/5237`). Stitch never calls those, so it's probably **not reachable today**. The other two are in general parsing code.
- `build-mupdf.sh` returns early whenever `build/mupdf/lib/libmupdf*.a` exist. If you bump the submodule for a CVE fix, the app keeps linking the old libraries with no warning.
- Every PDF you double-click, Open With, open through Services or open from ⌘K goes straight to `pdf_open_document` (`EditSession.init`). That runs in-process, unsandboxed and, until M1 is fixed, injectable. A MuPDF memory bug is therefore full code execution as you, plus Keychain access.

**Fix.**
1. Make the build script key its cache on the submodule commit:
   ```zsh
   rev=$(git -C vendor/mupdf rev-parse HEAD)
   if [[ -f $out/lib/libmupdf.a && -f $out/lib/libmupdf-third.a && "$(cat $out/REV 2>/dev/null)" == "$rev" ]]; then exit 0; fi
   # … after a successful build:
   echo $rev > $out/REV
   ```
2. Move to MuPDF 1.28.7 (or the `1.28.x` head) when it's tagged, and re-check https://mupdf.com/releases/cve each time.
3. Longer term, consider a small XPC helper (or a sandboxed helper process via `sandbox-exec`) for MuPDF parsing, so a parser bug doesn't land in the process that holds Keychain access.

The CVEs fixed in 1.28.0 (CVE-2026-7233, -3308, -25556, -40505) don't affect 1.28.6.

---

## Low

### L1 — LibreOffice conversions use default macro and link settings and can reach the network

**Where:** `Stitch/Engine/OfficeConverter.swift:55-63` and `:107`.

**Details.**
- `soffice` gets the full user environment (`ProcessInfo.processInfo.environment.merging…`).
- The fit-to-width macro calls `loadComponentFromURL(…, (Hidden,))` with no `MacroExecutionMode` or `UpdateDocMode`.
- The isolated profile is otherwise default, so `BlockUntrustedRefererLinks` is off and nothing turns off external data links.
- A `.docx`/`.xlsx` you merge can carry linked remote images, OLE links or `WEBSERVICE()` formulas. LibreOffice may fetch those while rendering the PDF.
- Document macros in `.docm`/`.xlsm`/`.pptm` (all accepted, `Stitch/Model/InputFile.swift:15-17`) rely on LibreOffice's default macro security level.

**Scenario.** A "syllabus.docx" with a 1×1 remote image tells its sender your IP address and when you opened it. That breaks the spec's "No network calls". LibreOffice has also had CVEs where crafted documents leaked local data through URL expansion (2024–25). A stale LibreOffice makes those reachable.

**Fix.**
- In the macro, pass `_prop("MacroExecutionMode", 0)` (`NEVER_EXECUTE`) and `_prop("UpdateDocMode", 0)` (`NO_UPDATE`).
- Write a small `registrymodifications.xcu` fragment into the Stitch profile before the first run: `Security/Scripting/MacroSecurityLevel=3`, `DisableMacrosExecution=true`, `BlockUntrustedRefererLinks=true`.
- Pass a minimal environment (`HOME`, `PATH`, `TMPDIR`, `STITCH_*`).
- Optionally, run soffice under `sandbox-exec -p '(version 1)(allow default)(deny network*)'`. It's deprecated but works, and it makes the no-network promise hold for real.

### L2 — PDF link annotations are followed on click

**Where:** `Stitch/Document/PDFCanvas.swift:388` (and `:372`). In the Select tool, a click falls through to `PDFView.mouseDown`. No `PDFViewDelegate` is set anywhere in the app, so PDFKit's default `pdfViewWillClick(onLink:with:)` opens the URL with `NSWorkspace`.

**Scenario.** A hostile PDF puts an invisible link annotation over the whole page. Your first click (to select, or to deselect a box) opens `https://tracker…/?opened` in your browser, a phishing page, a custom-scheme URL that drives another app, or a `file://` URL to an app or folder. Clicks in place mode are already intercepted (`:350-355`), which is good.

**Fix.** Make `StitchPDFView` set `delegate = self` and implement `pdfViewWillClick(onLink:with:)`. Allow only `http`, `https` and `mailto`, and only after an alert that shows the full URL. Ignore everything else, especially `file:`.

### L3 — Touch ID gating has gaps and doesn't match the spec

**Where:**
- `Stitch/Views/AppSettingsView.swift:151` and `:154`: Settings → Signatures draws the signature and initials and offers Change/Delete with no Touch ID. The same goes for Sign ▾ → Change Signature… (`Stitch/Document/Sidebar/SignPanel.swift:15-16`).
- `Stitch/Signing/SignaturePad.swift:53`: the pad pre-fills your full name from the profile without asking.
- `Stitch/Document/DocumentWindowController.swift:593`: with the grace setting on, `ui.revealed` is never reset. A window that was unlocked once stays unlocked for its whole life, not 5 minutes. With grace off it stays unlocked as long as the window is key. The spec says "Touch ID … before each placement".
- `Stitch/Signing/SignatureStore.swift:196`: `if AppDelegate.isTesting { return true }`. `isTesting` reads the `XCTestConfigurationFilePath` environment variable and is compiled into Release too (the string is in the installed binary). It's not exploitable on its own, because under that variable the app skips startup, but it's an auth bypass driven by an environment variable.

**Scenario.** Someone at your unlocked Mac opens Stitch → Settings → Signatures and screenshots your signature. Or, with grace on, they use an already-open document window to place your signature on anything, with no prompt.

**Fix.**
- Wrap the Settings previews in the same reveal gate, and require `BiometricGate.authorize` before Change/Delete.
- Derive "revealed" from `BiometricGate.lastSuccess + graceSeconds`, re-checked on a timer, instead of a stored flag that never expires.
- Put the `isTesting` shortcut under `#if DEBUG`.

Know the ceiling here: a Keychain item can't itself require Touch ID (`SecAccessControl` with `.userPresence`) without the data-protection keychain, and that needs a team ID and `keychain-access-groups`, which a self-signed "Flow Dev" identity can't get. So the gate will always be an app-level check. That's one more reason to fix M1.

### L4 — Stamped signatures can be hidden or moved by a crafted page

**Where:** `Stitch/Engine/MuPDF/StitchMuPDF.c:301-317`. Existing content is wrapped as `q` + old streams + `Q` + `q cm /StitchStampN Do Q`.

**Scenario.** A page whose content sets a zero-area clip and then pushes extra `q` without matching `Q` leaves the graphics state stack deeper than one. Stitch's single `Q` pops only one level, so the stamp is drawn inside the attacker's clip or transform. In Stitch the signature looks placed (the overlay is drawn by PDFKit). In the saved `_signed.pdf` it's invisible, or sits somewhere else, for example next to a different clause.

**Impact.** Integrity. You believe you signed what you saw. A malicious counterparty can then claim you never signed it, or show it in another spot.

**Fix.** Add the stamp as its own annotation (a Stamp annotation with the XObject as its appearance) and `pdf_bake_document` it. Or sanitize the page with `pdf_clean_page_contents` (sanitize on) before wrapping. Either way, add a check after save: render the stamp's rectangle with MuPDF and confirm it isn't blank.

### L5 — "Cover and retype" isn't redaction

**Where:** `Stitch/Document/DocumentWindowController.swift:23` and `Stitch/Document/PDFCanvas.swift:384`. They suggest covering scanned text with a white text box.

**Scenario.** You cover an SSN or account number on a scan with a white box and send the copy. The scan image underneath is untouched, and so is any OCR text layer Stitch added ("Make scans searchable"). A recipient can extract the image or select the hidden text.

**Fix.** Change the wording to "covers it visually; the original is still in the file". Better: add a real "Redact" action using `pdf_redact_page` with `PDF_REDACT_IMAGE_PIXELS` and black or white boxes. The shim already uses redaction for Edit Text, just with images left intact.

---

## Info / hardening

- **I1 — Temp files survive a crash.** Decrypted working copies, the stamp PDFs and Office copies live in `$TMPDIR/Stitch/<pid>/` (per-user, 0700, so only you can read them) until quit, or until the next launch after a crash (`Stitch/Engine/Workspace.swift:29-36`). That's fine for a single user. M2's fix shrinks what's left behind.
- **I2 — Same-user tampering knobs.**
  - `touchIDGrace` lives in plain `UserDefaults`, so `defaults write com.liamblackshawbrown.Stitch touchIDGrace -bool YES` turns on the never-locking window from L3.
  - The LibreOffice profile in `~/Library/Caches/…/LibreOfficeProfile` is user-writable and soffice runs its Python scripts. Stitch rewrites `stitch_fit.py` each time, which is good.

  Both only matter after M1 and L3 are fixed. Consider keeping the grace preference in the Keychain next to the profile.
- **I3 — Save Copy replace window.** `SaveCopy.place` (`Stitch/Engine/SaveCopy.swift:110-111`) uses `replaceItemAt` whenever the target exists.
  - For a fresh `uniqueURL` name, a file created between naming and saving would be replaced.
  - For `previousCopy` (`:79-83`), whatever now sits at that path gets replaced, even if you put a different file there since the last save.

  Neither ever touches an original (the file-identity check holds). For fresh names, use `moveItem` (it fails if the target exists) and fall back to the next name.
- **I4 — Image input surface and metadata.**
  - `FileKind.classify` accepts every type ImageIO can decode (`Stitch/Model/InputFile.swift:21-37`), including rarely used formats with a history of ImageIO CVEs. An allow-list (JPEG, PNG, HEIC/HEIF, TIFF, WebP, GIF) reduces the surface.
  - "Remove location" drops only the GPS dictionary (`Stitch/Engine/ImageConverter.swift:62`). IPTC City/Country text fields survive, so also drop `kCGImagePropertyIPTCDictionary` location keys.
- **I5 — Denial of service.**
  - No MuPDF memory limit (`FZ_STORE_DEFAULT`, default allocator).
  - The CSV parser loads whole files and pads every row to the widest one (`Stitch/Engine/CSVConverter.swift:123-129`).
  - `smu_open` doesn't check `calloc` (`StitchMuPDF.c:60`).

  A hostile file can hang or exhaust memory, but can't corrupt anything. LibreOffice already has a 180-second timeout.
- **I6 — Privacy breadcrumbs.**
  - Recent files are bookmark data in `~/Library/Preferences/com.liamblackshawbrown.Stitch.plist`.
  - Notifications show output file names, possibly on the lock screen.
  - The signature you place is stamped as vectors, so anyone with the signed PDF can lift it as clean vector paths. That's true of any visual e-signature. Flattening doesn't change it, but it's worth knowing.

  None of these are bugs.

---

## Looked at, found fine

**MuPDF shim** (`StitchMuPDF.c/.h`, `MuPDFDocument.swift`)
- Every MuPDF call sits inside `fz_try`/`fz_catch`.
- There's no `return` inside an `fz_try` body. The returns inside `fz_catch` are the supported idiom.
- Locals written in `fz_try` and read in `fz_always` or `fz_catch` are `volatile`.
- Cleanup happens in `fz_always`.
- No MuPDF type or longjmp reaches Swift.
- Error buffers are 512 bytes with their length passed, written with `snprintf`.
- Fixed `char[]` fields are always NUL-terminated by `copy_str`, so Swift's `String(cString:)` reads them safely.
- Growth math uses `size_t` and `realloc` results are checked. The `int` capacity overflow would need more than 2³⁰ items, which isn't reachable.
- `pdf_redact_options` is fully initialized (4 fields).
- One context per document, with no shared global state. Each `MuPDFDocument` is used from one task at a time (`render` and `rebuild` open their own).
- Out-of-range page numbers throw inside MuPDF and are caught.

**MuPDF build**
- JavaScript is off (`-DFZ_ENABLE_JS=0`; `pdf_js_*` are stubs in `libmupdf.a`). mujs is still linked but never called.
- No curl, Tesseract, zxing or libarchive.
- Bundled third-party libraries are current: FreeType 2.14.3, zlib 1.3.2, lcms2 2.19, libjpeg 10 (Jan 2026), OpenJPEG/HarfBuzz/jbig2dec from June 2026, brotli from Oct 2026.

**Keychain**
- Items are local only (`kSecAttrSynchronizable false`) and `WhenUnlocked`.
- The ACL is limited to `/Applications/Stitch.app` with a cdhash partition (verified on the real items). Debug builds and the test host get a prompt and don't silently read them.
- Demo runs (`.demo`, `#if DEBUG` only) and tests (`.tests`, `.storagetests`, cleaned up in `tearDown`/`defer`) use their own services.
- The `.unreadable` backup is written once, never overwritten, and removed by Delete All.
- "Won't overwrite unreadable" stops a denied prompt from wiping your data.

**Logs and crash output**
- There are no `print`, `NSLog`, `os_log` or `Logger` calls anywhere in `Stitch/`.
- No profile or signature data is written to `UserDefaults` or files.
- The PDF password is held only in memory (`EditSession.password`) and typed into an `NSSecureTextField`.

**Drag and drop**
- `PlaceItem` puts only an enum token on the pasteboard, with `visibility: .ownProcess`. Profile values never go on a pasteboard.
- The drop targets accept only file URLs (panel) or that private type (canvas).
- Placing a signature from a drop still goes through Touch ID.

**⌘K Spotlight**
- `NSPredicate(format: "%K CONTAINS[cd] %@", …)` substitutes your text as a value, so there's no predicate injection.
- Results are limited to your home folder and come from the local index only.

**LibreOffice invocation**
- `Process` is given an argument array (no shell).
- The input is an absolute path to a copy in the work folder, so a file name like `--foo.docx` can't become an option.
- The profile folder is 0700. It holds no recent-documents list or thumbnails (checked `registrymodifications.xcu`).
- LibreOffice is killed on cancel and after the timeout. Installed version: 26.8.2.

**CSV**
- Pure Swift, bounds-checked RFC 4180 parser. Formulas are never evaluated (`=cmd|…` is drawn as text).

**Originals are never written over**
- `SaveCopy` refuses the original and other tabs' originals by file identity, which also catches case-insensitive names, symlinks and hard links.
- Saves go through a staged copy, then a move or replace.
- Rename refuses an existing name (and `moveItem` fails if the destination exists, closing the race), does case-only renames through a temporary name, and `FileRename`/`OutputNaming` strip `/`, `:`, leading dots and cap names at 255 bytes, so a name can't escape its folder.
- OCR and Office work on copies.
- `Pipeline` uses `moveItem` to `uniqueURL` names (fails rather than overwriting), and `PDFShrinker` uses `.withoutOverwriting`.

**Scratch folders**
- Per-user `$TMPDIR`, one folder per PID.
- `clearLeftovers` keeps folders of running PIDs (`kill(pid,0)`/`EPERM`).
- `removeItem` removes symlinks themselves, never what they point to.
- `Workspace.remove` only deletes inside its own root.

**Entry points**
- Open/Open With, Dock drop and Services only open PDFs into a window (file URLs only) or stage files for merging. Nothing runs automatically.
- The demo code (`DemoMode`, `DocumentDemo`, `-StitchDemo`, `-StitchDemoSnapshot`) is entirely `#if DEBUG`. No `StitchDemo` string is in the installed binary (verified with `strings`).
- No custom URL schemes are registered.

**Network**
- No `URLSession`, sockets or web views anywhere.
- The only URL is the LibreOffice download link, opened only when you click it. Notifications are local.

**Secrets**
- I scanned all 8 commits outside `vendor/`: no keys, tokens or private keys.
- `.gitignore` covers `.env*`, `*.pem` and `*.key`.
- Test fixtures contain only your name and a campus address.

**Sandbox and signing**
- `ENABLE_APP_SANDBOX: NO` is deliberate. There are no extra entitlements beyond `get-task-allow` (see M1).
- The Debug build's test-manager exceptions exist only in the Debug build.
