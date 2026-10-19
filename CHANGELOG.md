# Changelog

## Unreleased

- Trim trailing room noise and the stop-key click from each dictation before decoding,
  so Whisper no longer invents a closing "Thank you." for the silent tail.
- Drop decoded segments that the microphone contradicts (text stamped over a span
  with no speech energy), in both the final transcript and the live preview.
- Judge each segment by its own token confidence instead of the whole-window value
  WhisperKit copies onto every segment.

## 0.2.0 — 2026-08-18

- Added live dictation preview at the active text cursor.
- Added a floating microphone indicator near the caret and a stable transcript panel.
- Made final text delivery safer and more reliable across native editors, browsers, and terminals.
- Prevented duplicate final insertion and repeated overlapping transcript fragments.
- Added on-device system-audio transcription with a dedicated live transcript window.
- Added searchable transcription history with copy actions.
- Improved silence detection and filtering of low-confidence Whisper hallucinations.
- Added current Whisper model variants, model storage details, and model deletion controls.
- Improved Fn/Globe hotkey diagnostics, permission guidance, and duplicate-instance protection.

## 0.1.2 — 2026-07-21

- First notarized direct-distribution release.
