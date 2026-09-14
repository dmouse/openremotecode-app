# Read-only project MCP status

## Contract

This mobile implementation consumes the independent encrypted `project.mcp` v1
topic. It never adds `includeMcp` to a chat request and never reads the local
OpenCode HTTP API directly. The connector remains authoritative.

| Operation | Request body | Response body |
| --- | --- | --- |
| `project.mcp.snapshot` | `version: 1`, `projectId: uuid` | `version`, `projectId`, `state`, `servers` |
| `project.mcp.subscribe` | `version: 1`, `projectId: uuid`, `subscriptionId: uuid` | snapshot fields plus `subscriptionId`, `revision` |
| `project.mcp.unsubscribe` | same as subscribe | `version: 1`, `unsubscribed: true` |

`project.mcp.updated` is strictly `kind: event`; its inner encrypted payload's
`requestId` equals the client-generated subscription ID. Its body has the same
shape as the subscribe response. All four operations must be advertised before
details initiates a subscription. Each request is also capability-gated by the
authenticated repository. There is no fallback to raw OpenCode payloads.

The details route uses the snapshot returned by subscribe instead of issuing a
redundant standalone snapshot. `McpSnapshot.request`/`parse` and the encrypted
request transport also support the standalone snapshot shape, verified directly
against the shared fixture.

Bodies have strict keys and integer version 1. Revisions are nonnegative safe
integers (at most 9007199254740991). `state` is `ready` or `unavailable`, with
`unavailable` requiring an empty server list. There are at most 100 unique server
names; names contain 1-128 UTF-16 code units and exclude C0/C1 controls and bidi
characters U+061C, U+200E/F, U+202A-E, and U+2066-9. Server rows contain exactly
`name` and `status`. Status is one of `connected`, `disabled`, `failed`,
`needs_auth`, or `needs_client_registration`.

## Lifetime and freshness

The v1 lease is fixed at 60 seconds; no lease duration is inferred from payloads.
The connector polls every 3 seconds while subscribed and emits only changes.
The mobile client renews the same subscription ID every 30 seconds. A successful
renewal returns an authoritative snapshot and increasing revision even with no
changes. The greatest revision wins across events and responses, including an
initial event preceding the subscribe response. Response ordering cannot regress
the server list within that subscription lifetime. Reconnect/resume creates a
new ID and resets revision tracking. Renewal failure, a non-increasing response
revision, or possible lease expiry retires the old ID and counters with a
best-effort unsubscribe. Recovery waits 30 seconds before subscribing with a
fresh ID; ordinary presence notifications cannot bypass this backoff. The last
snapshot stays explicitly non-live until the new lifetime supplies data.

Lease expiry is tracked independently of change events, conservatively from the
send time of the last acknowledged subscribe. A deadline check before requests,
responses, and events also covers overdue callbacks after a scheduling stall.
An expired server-side ID recreated at revision zero cannot make a retained
higher-revision snapshot live again. Initial events may still precede their
subscribe response; largest-revision ordering is preserved within a live ID.

The route owns one bounded snapshot and no history or durable storage. Timers and
listeners are disposed with the route. Backgrounding, route covering/closing,
source change, lost capability, and offline transitions stop the subscription.
Unsubscribe is best effort and never retries on a new connection generation;
lease expiry bounds server-side cleanup if the network is gone. If subscribe
finishes after close, a second bounded cleanup handles an overtaken unsubscribe.

A successful renewal or newer event starts a 45-second freshness timer. Failure
to renew immediately removes live status once known, even if more events arrive;
only data from a fresh subscription lifetime recovers from this failure. If a
renewal hangs, freshness still expires after 45 seconds, and lease expiry retires
the lifetime even if change events keep arriving. The transport bounds requests
at 20 seconds.
Names may remain as explicitly last-known in memory while offline/paused, but no
green live dots remain. Trust or project loss clears the snapshot completely.

## Threat analysis

- Disclosure: names and statuses stay inside the existing authenticated HPKE
  envelope. No extra HTTP endpoint, logging, analytics, clipboard, preferences,
  screenshots, or disk cache receives these values. Outer routing metadata stays
  authenticated as associated data; no cryptographic primitive is changed.
- Cross-account/peer substitution: `ApiConnectionsRepository` resolves the sender
  from pinned keys, checks authenticated account scope, and binds each event to a
  connector and opaque peer-scoped connection generation. Checks run again after
  async decryption, including failed decrypts. Offline, inventory trust loss, and
  revocation retire only the affected peer's requests and events. Healthy peers
  keep their subscriptions, revision counters, and pending requests; full socket
  closure still invalidates every peer. Already routed frames from removed peers
  are ignored instead of closing a healthy peer's transport.
  A revoked connector loses local trust immediately after remote acknowledgement,
  even if removing its secure-store binding fails. MCP also checks project,
  subscription, connector, and generation before accepting data.
- Replay/correlation confusion: the bounded encrypted-envelope replay window
  survives reconnect. Only `project.mcp.updated` is admitted as an event by native
  payload validation. Event dispatch occurs before and separately from pending
  response lookup; an event cannot complete a request even with a colliding ID.
  Revision checks reject older or duplicate updates. Late decrypts and replies
  cannot repopulate revoked or changed sources.
- Hostile display input: strict shape, size, uniqueness, status, and name checks
  prevent protocol field smuggling and control/bidi spoofing. Names are rendered
  literally, not Markdown or links. Authentication-required labels are purely
  informational and never launch authentication or grant permissions.
- Availability: subscription errors remain local to MCP, not chat errors. One
  renewal is in flight per view generation, and the existing relay limits pending
  requests, decrypt work, payloads, timeouts, and replay state. MCP retains only
  one list of at most 100 rows. Explicit freshness prevents a change-only stream
  from leaving a false live indicator indefinitely.

These checks do not make a compromised authorized connector or native device
trustworthy. Native HPKE implementation and secure-store assurance remain covered
by their existing platform security boundaries.

## Verification

Tests read `../packages/protocol/test/fixtures/project-mcp-v1.json` directly.
There is no duplicated fallback fixture. Run from `mobile`:

```sh
flutter analyze --no-pub
flutter test --no-pub
```

The MCP suites cover strict parsing, shared snapshot/subscribe requests and
responses, encrypted platform-boundary content and routing, event/response
separation, wrong peer and replay rejection, delayed decrypt invalidation,
event-before-response ordering, renewal/freshness, reconnect/resume, late cleanup,
capability gating, source/trust loss, title navigation, passive semantics, drafts,
empty/failure/offline states, and 320-pixel layout with 2.5x text.
The API suite also runs a real loopback WebSocket with fake HTTP/storage and
native-channel adapters, verifying event-before-response delivery through the
production repository and decrypt races against revocation (including failed
local cleanup), key change, backgrounding, and logout. Focused regressions cover
revision-zero lease recreation after a revision-ten event, delayed callbacks,
bounded recovery backoff, and four unrelated connector flaps on one socket
without orphaning the healthy connector's subscription slots. Peer-scoped
request/seal/decrypt races and unrelated inventory/revocation changes are covered
separately from global socket invalidation.

Unit platform-channel mocks verify the Dart encryption boundary, not native HPKE
execution. Native interoperability and TalkBack/VoiceOver are separate release
checks. Never install/uninstall or clear data on the normal application for
verification. Android integration may run only through the existing isolated
`tool/test_local_android.sh` launcher; iOS requires an isolated bundle/device.
