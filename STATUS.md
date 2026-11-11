---
status: active
progress: 90
effort_left: 4
next_step: Use Stitch on real PDFs (lease, USC form, contract, scan, password-protected, digitally signed) for a week instead of Acrobat; fix what comes up
updated: 2026-11-11
source: estimate
---

## Goal
Stitch: menu-bar app to merge PDFs/Office/CSV, convert images and shrink files for AI-chat uploads (spec: docs/SPEC.md), plus a Dock app that signs, fills and edits PDFs (docs/SIGN-AND-EDIT-PLAN.md).

## Done
- Part 1: engine (merge, smart order, convert, OCR, shrink, Office/CSV), panel UI, tests, scripts
- Part 2 (branch sign-and-edit): Stitch window, tabbed document windows, MuPDF engine + Save Copy, signatures/initials with Touch ID, text boxes, dates, forms + auto-fill, click-to-edit text, opening from Finder/Dock/Services/recents, Settings window

## Left
- Hands-on run through every flow on real documents (the UI wasn't clicked through during the build)
- Two old merge tests fail on macOS 27: PDFKit no longer keeps the bookmarks Stitch adds (`PDFTools.addOutline`)
- Later versions: highlights/comments, page tools, compress button, convert/protect, scanning, flatten on save
