# ADR 0004: Recover idle chat streams without leaving the conversation

## Problem

A connector subscription has a 60-second lease and a revision counter scoped to
that subscription. If the connector expires or loses a subscription while the
relay connection remains online, renewing the same ID can create a new stream
at revision zero. The mobile client previously discarded that lower baseline and
all following lower revisions while still reporting the old stream as live.
That disabled fallback polling. Sending a prompt also skipped its history read
because the stream appeared live, so an accepted message could remain invisible.

## Decision

- Capture the applied revision at the start of each subscribe/renew request.
  A renewal response must advance beyond it. If not, stop the old subscription;
  the existing conversation fallback fetches an authoritative snapshot and opens
  a new subscription ID, without navigation or clearing retained history.
- Compare against the revision at request time, not at response time: valid
  events can overtake a renewal acknowledgement. Preserve pre-ack buffering,
  reset watermarks and generation/target correlation checks.
- Bound each subscribe/renew request to 20 seconds. Retire local liveness 50
  seconds after the last successful acknowledgement, independently of events,
  before the connector's 60-second lease. Healthy streams still renew every 25
  seconds and do not poll history while idle.
- After every accepted prompt, read authoritative history and rebase the stream,
  even when it appears live. A failed follow-up read reports that the message
  was sent but updates are reconnecting. Retry reads through the existing
  three-second fallback; never automatically retry the prompt. Clear that notice
  after a successful latest-history read.
- Preserve foreground, trust and connection-generation guards. Stop timers when
  covered, backgrounded, navigated away or disposed; ignore late responses from
  retired subscriptions. No durable conversation storage is introduced.

## Security and resource handling

Recovery uses the same authenticated, encrypted, project/session-bound read
operations. It cannot broaden authorization or silently grant permissions.
Only one stream request is pending per target; the existing shared request gate,
repository concurrency limit, bounded event buffer and fallback cadence remain.
No prompt, response, decrypted event, cursor or native exception is logged.
Uncertain prompt outcomes retain the existing explicit-user-retry policy.

## Verification

Mobile tests simulate a recreated lease at a lower or equal revision, a stalled
renewal and late acknowledgement, an event overtaking a renewal reply, explicit
closure, a dropped prompt event, a failed post-send read, and five minutes of
idle foreground renewal followed by background suspension. Recovery preserves
the open conversation and sends each prompt only once. Existing shared-fixture
stream validation and chat navigation/history tests remain applicable.
