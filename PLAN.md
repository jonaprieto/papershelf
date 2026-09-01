# PaperShelf improvement plan

## Working rules

- Keep the PDF annotation model as the source of truth.
- Reuse the existing reader, palette, rename preview, and apply flows.
- Implement one focused workstream at a time.
- After every change: run the full test suite, inspect the diff, and commit only when all tests are green.
- Do not continue to the next workstream with uncommitted changes or failing tests.

## Workstreams

### 1. Restore rename review and command-palette actions

- Make **Review renamings** a persistent, visible collection action again.
- Reuse the existing dry-run `preview()` and guarded `apply()` paths.
- Expose review, apply, and existing rename actions in the command palette.
- Add a direct **Open Settings** palette action while retaining searchable individual settings.
- Keep applying unavailable until a current review exists.

Relevant areas: `Catalogue.swift`, `Commands.swift`, `CommandPalette.swift`.

### 2. Improve PDF navigation and focused reading

- Reuse the existing document `step(by:)` navigation.
- Make next/previous document commands available while reading.
- Add horizontal two-finger trackpad navigation for next/previous PDFs while preserving vertical PDF scrolling.
- Add native macOS full-screen support for focused reading.
- Keep Reading Mode and native full screen independently usable.

Relevant areas: `Review.swift`, `ReaderWindow.swift`, `Commands.swift`.

### 3. Add selectable PDF contrast modes

- Preserve the current dark tint behavior as the default.
- Add Normal, Dark tint, and White-on-black appearance choices.
- Apply the effect only to the PDF canvas, not the Notes panel or application chrome.
- Verify text PDFs, scanned PDFs, images, and highlights.

Relevant areas: `Prefs.swift`, `Review.swift`, and `PaletteSettings.swift`.

### 4. Fix note and highlight interactions

- Pressing **Add Note** should immediately focus the note text field.
- Make the highlighting-bar action explicitly visible and labelled **Add note**.
- Make every note entry point use the same behavior, including the main reader toolbar.
- Clicking a highlight should set `selectedMark` and select/scroll to the matching row in the Notes panel.
- Reuse the existing `mark(atViewPoint:)`, `selectedMark`, and Notes Rail scrolling behavior.

Relevant areas: `Reading.swift`, `Annotations.swift`, `Review.swift`.

### 5. Add customizable highlight semantics

Highlight meaning should be separate from presentation color. Provide default roles such as:

- Read / keep
- Rewrite
- Delete
- Omit
- Important

Support editing the label, color, and shortcut at three scopes:

```text
Paper override > Project override > Library defaults
```

- Store paper overrides using the library's stable document ID so renaming a PDF does not lose them.
- Add **Customize highlight meanings** to the palette and relevant highlight menus.
- Preserve compatibility with existing PDFs through a legacy color fallback.
- Give new annotations a stable semantic role/slot.
- Show semantic labels in the Notes Rail, Markdown exports, and generated sidecars.
- Changing a paper or project profile should immediately update the display and exports for its highlights.

Relevant areas: `Annotations.swift`, `Prefs.swift`, `PaletteSettings.swift`, `Markdown.swift`, and existing library persistence.

### 6. Synchronize notes to a generated Markdown sidecar

- Keep PDF annotations as the single source of truth.
- Generate an accompanying file beside each PDF, initially named `<PDF stem> notes.md`.
- Include a generated PaperShelf header identifying the file as managed output.
- Overwrite the managed file atomically whenever annotations change.
- Include highlights, notes, colors, pages, source metadata, and semantic labels.
- Add a preference enabled by default to disable future sidecar writes.
- Do not delete an existing sidecar merely because synchronization is disabled.
- Move the sidecar together with the PDF during renaming.

Relevant areas: `Markdown.swift`, `Annotations.swift`, `Prefs.swift`, and the rename apply path.

### 7. Add dictation to note inputs

- Add a microphone button beside note inputs.
- Record a short native macOS audio clip, then transcribe it when recording stops.
- Append the result to existing typed text.
- Show recording, uploading, and error states.
- Reuse the existing API key and base URL configuration.
- Add microphone permission metadata and focused request/error handling.
- Start with record-then-transcribe; defer realtime streaming and diarization.

Relevant areas: `AI.swift`, `Reading.swift`, and `Resources/Info.plist`.

### 8. Preserve annotation text fidelity

- Fix corrupted or incomplete quoted text shown in the Notes rail after highlighting.
- Preserve word boundaries, punctuation, Unicode characters, ligatures, and multi-line text
  when reading a PDF selection or annotation.
- Keep the exact same text across the PDF annotation, Notes rail, Markdown export, and
  generated sidecar.
- Verify that the fix does not change the visual highlight geometry or page navigation.

Relevant areas: `Annotations.swift`, `Reading.swift`, `Markdown.swift`, and PDF text
extraction helpers.

### 9. Share notes with ChatGPT

- Add explicit Notes Rail actions to open all current highlights and notes in a new ChatGPT
  conversation or copy them into an existing one.
- Reuse the complete Markdown export so pages, notes, and semantic meanings stay together.
- Keep automatic background synchronization deferred until there is an explicit privacy and
  consent design for sending future annotations off the machine.

## Verification

Add focused coverage for:

- Rename review/apply palette actions and settings access.
- Reader next/previous navigation.
- Highlight click-to-note selection.
- Note editor focus.
- Semantic scope precedence, rename stability, and legacy fallback.
- Markdown sidecar content, generated header, overwrite behavior, and toggle behavior.
- Sidecar movement during renaming.
- Transcription request construction and failure handling.
- Annotation text fidelity for multi-line, Unicode, and ligature-containing selections.
- Complete notes handoff to ChatGPT without dropping pages, notes, or semantic meanings.

After each workstream, run:

```sh
rtk swift test
```

Then inspect the diff and commit the work before starting the next workstream. At the end, manually verify trackpad swipes, full screen, contrast modes, annotation selection, rename review/apply, sidecar updates, and microphone permission/transcription failures.

## Deferred scope

Defer live transcription, editable/mergeable sidecars, and a separate notes database until the simpler implementation demonstrates a real need for them.
