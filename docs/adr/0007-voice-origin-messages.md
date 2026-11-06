# 0007: Voice-origin messages without retained audio

Status: implemented, 2026-11-06. Supersedes [0006](0006-voice-note-presentation.md).

## Decision

Voice input is an alternative way to author a text prompt, not an audio attachment.
During capture, bounded microphone samples drive a 24-bar rolling waveform and
microphone feedback at most ten times per second. A timer shows the 60-second
limit. Reduced motion disables scaling and waveform animation; status and elapsed
time remain available to screen readers without announcing every audio frame.

Cancel discards the turn. Send explicitly ends capture, obtains the final local
Hex transcript and submits it through the existing encrypted `chat.prompt` path.
Stop (including reaching 60 seconds) instead offers an unsent card with Send and
Discard. Neither Stop nor partial transcription automatically submits a note.
The separately typed draft is never populated or cleared by note submission.
Call-mode pause detection and explicit call-mode auto-send are unchanged.

The sent card says **Voice message**, shows the original duration and explains
**Sent as text · Audio not saved**. **Show transcript** reveals the already
submitted text beneath the card; Hide transcript collapses it. Neither action
calls a transcription service or submits another prompt. There is deliberately
no Play button, playback waveform or audio-unavailable placeholder.

## Metadata and authoritative history

The normal text prompt carries this bounded, versioned presentation marker:

```
[Open Remote Code voice note v2: <uuid>; durationMs=<1..60000>]
<transcript>
```

The marker and transcript together fit the existing 32,000 UTF-16-unit prompt
limit. A fresh UUID correlates the voice-origin message; it grants no trust.
OpenCode remains the source of truth and retains the marker with the authored
text. A fresh mobile screen recovers the label, duration and transcript from its
normal authoritative snapshot without an audio cache or metadata side database.
The marker is visible to OpenCode and the authorized model provider; older clients
show literal text. Existing well-formed v1 markers still render as voice-origin
cards, with no invented duration. Unsupported, malformed, empty and over-limit
markers remain ordinary text. Only user messages receive the voice treatment.

The shared `voice-note-v2.json` fixture pins the mobile representation and its
round-trip through the TypeScript prompt/snapshot contracts. This is not a new
remote operation, file-access capability or relay envelope field.

## Retention and threats

Capture keeps only the existing bounded streaming queue/remainder while Hex
transcribes, a byte counter for duration and bounded amplitude measurements.
There is no second full-recording buffer, workspace audio index or active playback
integration. Streaming buffers are drained on finish and cleared on cancellation;
no recording is saved to disk, preferences, backups, telemetry or relay history.
Pre-existing native playback adapters are not instantiated by this flow.

Unsent state is discarded on navigation, backgrounding, trust loss or a context
change. Late transcription results cannot populate another chat. An uncertain
submission cannot be resent from the card and is never retried automatically.
Transcript disclosure is plain selectable text, not interpreted as Markdown,
commands, files or URLs. An authenticated peer can author marker-shaped text but
cannot supply audio, gain permissions or bypass the usual encrypted prompt
authorization, account isolation or deduplication boundaries.

## Verification

Tests cover shared metadata and malformed markers, explicit one-shot Send,
60-second Stop, preserved text drafts, empty/over-limit transcripts, late results
after cancellation, uncertain submission, fresh-screen reconciliation, transcript
disclosure without native playback calls, responsive waveform/reduced motion and
narrow large-text layout. Existing voice transport and call-mode tests remain.
Native microphone permissions/interruption behavior on Android and iOS still
require isolated device verification; this change introduces no new native API.
