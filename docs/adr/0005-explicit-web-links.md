# ADR 0005: Explicitly open message web links

## Context

The original Markdown renderer deliberately removed all link recognizers, leaving
links indistinguishable from ordinary text and impossible to open. The requested
behavior is clickable links in assistant replies and literal user prompts.

## Decision

- Use the pinned Markdown renderer's native link callbacks for inline, reference,
  angle-bracket and GFM bare links. Keep selection and Markdown formatting.
  Underline links using the existing dark `AppTheme.info` color.
- Preserve literal user text, recognizing at most 64 HTTP/S URL spans without
  interpreting it as Markdown. Dispose owned recognizers on edits and teardown.
- Compact OpenCode's plain `PR #17 (https://github.com/...)` format into a
  clickable **PR #17** label in both message renderers. Hide the parentheses/URL
  only in presentation, keep the original message and destination unchanged,
  and still preview that destination before Open. This is limited to complete,
  valid `PR #number (HTTP/S URL)` references, not arbitrary prose rewriting.
  Markdown inline/fenced code, literal HTML, existing Markdown link labels and
  incomplete or unsafe references are not rewritten by the inline extension.
- Before opening, show the actual destination as selectable text and require an
  explicit Open action. Cancel/dismiss does nothing. This prevents an innocent
  Markdown label from hiding where the user is about to navigate.
- A pure domain policy admits absolute HTTP/S URLs only, with a host, valid
  port, no embedded credentials, no whitespace/backslashes/control/bidi
  characters, and a maximum length of 4096 UTF-16 units. Relative paths and
  `file`, `data`, `javascript`, `intent`, `mailto` and other schemes cannot launch.
- A narrow injectable data adapter calls `url_launcher` 6.3.3 in
  `LaunchMode.externalApplication`, without app headers, credentials or an
  embedded WebView. Launch directly after confirmation rather than relying on
  `canLaunchUrl` and its additional platform package-visibility configuration.
  The OS may choose its browser or an associated application for a web URL.
- Bound launch waiting to ten seconds and show a fixed failure notice. Never
  log destinations, query parameters, native exceptions or message content.
- Keep images, HTML, code, thought/tool/shell content and the large-message
  Markdown fallback passive. Rendering, scrolling and receiving updates do not
  launch URLs or fetch resources. No conversation content is persisted.

This revises only the passive-link portion of the original Markdown design;
it does not introduce file browsing, a generic deep-link launcher, automatic
previews, or a server/relay protocol change. The phone does not resolve a local
OpenCode file or relative URL.

## Threat analysis

| Threat | Control |
| --- | --- |
| Misleading model-authored Markdown label | Preview the actual destination before explicit Open |
| Executable scheme, file access, arbitrary deep link or relative path | HTTP/S-only validation both before confirmation and in the native adapter |
| Credentials/control characters obscure destination | Reject user-info, whitespace, backslashes and control/bidi characters |
| Passive rendering leaks content to an external service | No network/native calls until the confirmed user action; image loading remains blocked |
| App credentials leak to a linked site | No authentication headers or app credential context passed to the OS |
| Unbounded URL gestures or repeated taps | 64 literal URL spans, existing Markdown size limits, per-message single-flight confirmation |
| Failure leaks sensitive URL parameters | Fixed UI notice; exceptions are handled without logging |

The approved URL leaves the app's encrypted chat boundary and is handled by the
OS/browser under its own security and privacy model. The app cannot guarantee a
site is trustworthy or prevent a site from redirecting after the user opens it.

## Verification

Tests cover HTTP/S policy bounds and hostile inputs, real taps on Markdown and
literal URL spans, destination preview/cancel/Open, no automatic I/O, failure
handling, code/image restrictions, punctuation, retained raw user text, and
existing selection/layout/streamed-text behavior. Native browser launching still
requires verification on an isolated Android/iOS test device.
