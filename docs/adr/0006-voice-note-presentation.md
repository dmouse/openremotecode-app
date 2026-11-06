# 0006: Temporary playable voice notes with authoritative text prompts

Status: implemented, 2026-11-06.

## Decision

Notes are not dictation. Microphone samples drive a bounded, at-most-10-Hz level
indicator; reduced motion disables scaling. Stop ends capture and local Hex
transcription, then offers a scrollable preview with explicit Play/Pause, Send
and Discard. No stop, transcription result, or partial audio segment submits a
note automatically. Call-mode pause detection and explicit auto-send stay unchanged.

On explicit Send, a draft obtains a confirmed session through the existing
creation/uncertainty guard. The normal encrypted `chat.prompt` carries:

```
[Open Remote Code voice note v1: <uuid>]
<transcript>
```

This is versioned presentation metadata in a bounded text prompt, not a new
operation or a native OpenCode payload. The label and transcript are visible to
the authorized model provider and local OpenCode client. No credentials, file
paths or routing identities are added. Older clients display literal text.
Only a well-formed v1 UUID marker on a user message becomes a voice bubble.
The full prompt, marker included, must fit the existing 32,000-unit limit.

The local audio index is keyed by connector, approved project path, session and
fresh random note ID inside the authenticated workspace lifetime. It retains at
most eight PCM16/16-kHz/mono notes, each at most 1,920,000 bytes (60 seconds).
Matching also requires the exact transcript before exposing playback. Sending
cannot change another conversation's draft; an uncertain submission permits no
second Send from that preview and never retries automatically. Authoritative
history reconciles the prompt normally, without text-similarity guesses.

Transcribe is an explicit display action for the already obtained transcript,
not another model prompt or a second transcription request. The transcript is
plain selectable text, never interpreted as a command, file, Markdown or URL.

## Retention and playback

No audio is written to disk, backups, preferences, logs, metrics, or relay history.
Returning to a chat can reuse workspace-memory audio; restart/eviction leaves an
honest audio-unavailable placeholder plus the authoritative transcript. Peer trust
loss/revocation clears affected memory; logout disposes the workspace index.
Unsent recordings are discarded on navigation, backgrounding, interruption or
loss of the current recording context. The app does not promise offline audio
sync or permanent audio messages.

Playback uses a narrow native channel accepting only bounded even-length PCM
bytes, never a path or URL. Android uses AudioTrack static memory; iOS builds an
in-memory WAV for AVAudioPlayer. Native buffers are released on stop, native
lifecycle suspension, interruption, audio-focus loss and Flutter disposal. One
foreground player is shared by previews and history, with serialized operations
and generation checks. There is no autoplay, background player, file cache,
loopback HTTP proxy, download, upload, export or audio-based permission reply.
Starting microphone capture stops playback first.
Playback cannot start during capture or transcription, or from a covered or
backgrounded conversation. Native play/resume also recheck foreground state so
late platform-channel delivery cannot restart audio after suspension.

## Threats and verification

An authenticated peer can author marker-shaped text. It cannot provide audio,
trigger playback, escape the current connector/project/session lookup, or gain
trust. A UUID marker is a correlation identifier, not an authorization token.
Unexpected version/format/size remains literal text. Normal encryption and the
plugin's prompt authorization/deduplication remain the security boundaries.

Tests cover preview without submission, preserved typed drafts, explicit Send,
inline transcript disclosure, malformed markers, bounded/scoped audio, revoked
contexts and late transcription, uncertain-send repeat prevention, no path/URL
playback, serialized pause/resume and stop during pending playback. Android
compilation is checked independently. Native microphone/speaker, OS interruptions
and iOS compilation/interoperability still require isolated device verification.
