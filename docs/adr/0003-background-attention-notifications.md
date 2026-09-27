# ADR 0003: Attention notifications through server-sent push

Status: proposed. Changes the mobile scope in `mobile/AGENTS.md` (push
notifications) and the documented server metadata once accepted. Needs matching
plugin and server ADRs before implementation.

## Context

A user who starts work in OpenCode and puts the phone away has no way to learn
that the agent is blocked on a permission or question, or that it finished. The
current app cannot tell them:

- The relay is foreground-only. `WorkspaceScreen` calls
  `ConnectionsRepository.setActive(false)` when the app leaves `resumed`, which
  closes the WebSocket, and `chatOnline()` is false from then on.
- Live updates are per session. `ChatStream` is a lease on the one open
  conversation. Snapshots carry `status`, `permission` and `question`, but only
  for that session.
- The plugin has no account-wide signal, and relay events are dropped while no
  client is attached.
- The server has no push capability, and the native projects have no
  notification setup.

Operating-system constraints rule out keeping the relay open instead. iOS does
not permit a background WebSocket, and `BGAppRefreshTask` runs too rarely to
report "the agent needs you now". Android permits it only from a visible
foreground service, which still leaves iOS without a solution. APNs and FCM are
the only mechanism that works on both platforms.

An end-to-end encrypted wake that tells the server nothing was considered. It
would keep notification text generic unless an iOS Notification Service
Extension decrypted each push, and it would not support features that need the
server to act on events, such as grouping or a future voice call. The product
accepts sharing event metadata with the server for a better mobile experience,
while conversation content stays end-to-end encrypted.

## Decision

### What the server learns

The plugin reports **attention events** to the server over HTTPS. An event
contains metadata only:

```
POST /v1/connectors/me/attention
{ version: 1,
  eventId,                  // random UUID per attention item, plugin-generated
  projectId,                // existing opaque UUID
  sessionId,                // OpenCode session id, max 128 chars
  kind: "input_needed" | "finished" | "failed" | "resolved",
  occurredAt }
```

- `input_needed`: a permission or question is waiting on the user.
- `finished` / `failed`: a top-level session went from busy to idle, or ended
  with an error. Subtask sessions report nothing of their own.
- `resolved`: an earlier `input_needed` was answered, rejected, or expired, so
  its notification can be removed. It reuses that event's `eventId`.

Nothing else is sent: no session title, prompt, response, tool name, command,
file path, project path, or permission detail. The protocol package defines the
schema and the plugin's adapter maps OpenCode events to it; raw OpenCode
payloads never cross the boundary. The endpoint is described in the OpenAPI
contract.

### Server behavior

- Authenticates the connector, checks it is active, and targets only devices of
  the same account.
- Throttles per device: one push per `eventId`, and repeated `finished` events
  within 30 s are merged into one notification.
- Stores nothing durable. A short in-memory table (about 10 minutes) supports
  deduplication, merging, and `resolved`. Logs, metrics, and audit records do
  not contain session ids or project ids; counters by `kind` are allowed.
- Sends the push even when the app is connected. The app decides how to show
  it (see below), so the server does not need to know what the user is viewing.

### Push delivery

- `PUT /v1/devices/{deviceId}/push-token` registers an APNs or FCM token for the
  authenticated device. Tokens are deleted when the device is revoked, on
  logout, and when APNs/FCM reports them invalid.
- The push carries `kind`, `eventId`, `connectorId`, `projectId`, and
  `sessionId` as data, and text chosen by `kind`:
  - `input_needed`: "OpenCode needs your input"
  - `finished`: "OpenCode finished a task"
  - `failed`: "A task stopped with an error"
- Notifications use `eventId` as the APNs collapse id and FCM tag, so
  `resolved` replaces and removes the pending notification.
- Lock-screen visibility is private. Session titles are not shown.

### Mobile behavior

- Requests notification permission from a settings screen, not at launch.
- Registers the push token after login and device pairing, and again when the
  OS rotates it.
- When the app is in the foreground and the push is for the open session, it is
  not shown; the conversation already displays the state.
- Tapping a notification opens that session. The app reconnects and loads a
  fresh snapshot from the connector, so it shows the current state even if the
  question was already answered elsewhere.
- Ignores pushes whose connector is not a trusted connector of the current
  account and server.

### Answering

Answers stay in the conversation screen with the existing permission and
question banners. There are no answer buttons on the notification: the product
requires an explicit, in-context tap with risk information, and "always allow"
from a lock screen does not meet that.

### Plugin behavior

- Sends an event when an attention item appears or resolves, with bounded retry
  for 2 minutes; older events are dropped as stale.
- Sends events regardless of whether a client is attached. The server decides
  whether and how to notify.
- Can be disabled in the plugin configuration, for users who do not want to
  share this metadata.

## Future: voice assistant

The server knowing when a session needs input is what enables a call-style
experience later: iOS VoIP push with CallKit and an Android full-screen intent
can ring the phone. What is spoken must still come from the phone, which
decrypts the conversation over the relay and uses on-device speech. The server
triggers the call but does not receive conversation text. Any design that sends
content to a server-side voice service breaks end-to-end encryption and needs
its own ADR.

## Threat analysis

- **Content.** Conversation content remains end-to-end encrypted. No prompt,
  response, title, tool name, or file path reaches the server, Apple, Google,
  or the OS notification store.
- **Activity metadata (accepted).** The server, Apple, and Google learn when a
  session needs input or finishes, which session and project ids are involved,
  how many sessions are active, and roughly how fast the user responds. The ids
  are opaque but stable, so a per-session timeline can be derived. This is a
  deliberate trade-off for the notification experience and must be stated in
  the security documentation. The plugin setting lets a user opt out.
- **Retention.** The server keeps attention metadata only in memory for
  deduplication, never in the database or logs, so a database disclosure
  reveals no activity history.
- **Cross-account delivery.** Pushes go only to devices of the connector's
  account; the connector identity comes from its credential, never from the
  request body.
- **Abuse.** A connector can send only generic notifications to its own
  account, and per-device throttling limits volume. Revoking the connector
  stops it.
- **Push tokens.** A leaked token is useless without our APNs/FCM credentials.
  Tokens are never logged and are deleted on revocation or logout.
- **Hostile input.** The server validates the body strictly (known `kind`,
  bounded ids, UUID formats). The app validates the push data and routes only
  to trusted connectors.
- **Stale actions.** A notification only opens the session; nothing is sent
  from it, so an expired or already-answered request is shown in its current
  state.

## Consequences

- The trust model in the root `AGENTS.md`/`CLAUDE.md` and the security docs
  must list attention metadata as information the server receives.
- `mobile/AGENTS.md` "Lifecycle and Connectivity" and "Out of Scope" change:
  push is in scope; a background WebSocket stays out of scope.
- The server gains an APNs/FCM sender, push-token storage, and two endpoints.
  Local development must work without Apple/Google credentials, using a no-op
  or logging sender.
- New mobile dependencies (Firebase messaging or equivalent) need the review
  required by `mobile/AGENTS.md`.

## Verification

- Contract fixtures for the attention body and push data, asserted by the
  plugin, server, and Dart.
- Plugin: pending → `input_needed`, answered → `resolved`, busy → idle →
  `finished`, subtasks silent, opt-out sends nothing.
- Server: cross-account rejection, revoked connector rejected, per-`eventId`
  deduplication, `finished` merging, token deletion on revocation and logout,
  no ids in logs.
- Mobile: foreground suppression for the open session, tap routing, rejecting
  pushes for untrusted connectors, and token re-registration.
- Native: one iOS and one Android path from a simulated connector event to a
  displayed notification.
