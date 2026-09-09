# QuickPeek Timeline Implementation Plan
Goal: implement approved docs/plans/2026-09-09-timeline-editor.md inside QuickPeek.
Architecture: vendored MIT TimelineKitCore data types; separate QuickPeekTimeline package owns atomic linked editing, selection and history. Native app UI builds playback/export from the same snapshot.
1. Vendor Core and licenses; add model tests for split, linked selection, independent audio, multi-delete, undo/redo, bounds and persistence. Implement model.
2. Add native editor UI: ruler, video thumbnails, audio waveform, click/command/shift/box selection, keyboard split/delete/undo, drag/trim, bottom toolbar. No floating video playback controls.
3. Add shared AVComposition builder, async waveform/thumbnail loading, preview rebuild cancellation and atomic export. Keep originals untouched.
4. Run package tests and actual media export checks, compile/sign, then replace installed app and verify process/hash. Report real-gesture verification separately.
