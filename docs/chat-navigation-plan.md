# Mobile project and chat navigation

Status: first functional iteration implemented, 2026-09-05.

## Available flow

Double-tap a verified connection, or use **Open projects**, to follow
**Connection → Project → Chats → Conversation**. Single tap still selects a
connection. Back moves through those screens in reverse order.

Projects are the connector's locally authorized existing working directories.
The default is the current OpenCode directory. The plugin option
`projectDirectories` may contain additional exact absolute directories approved
on the connected computer. **Open project by path** resolves only a directory
already in that policy. It cannot create folders, clone repositories, browse the
filesystem, or authorize additional paths remotely.

The projects app bar mirrors the chats app bar: the connection name is the
title with a small online/offline icon in the actions area, keeping accessible
labeling without visible Online text. The body starts directly with a
**Search projects** field. That field is the shared `SearchField` control —
identical metrics, hint style, and clear action to the chats search, so the
control keeps its size across the two screens. Project rows are transparent
with a hairline border, matching the connection and chat lists, and open on tap.

Chats lists only main sessions. Sessions with a parent (including sub-agent
sessions) are excluded by both plugin list APIs and defensively by the mobile
view model. Pagination retains its continuation even when a page contains only
children, so automatic pagination can reach later main sessions. Search filters
loaded chats immediately, then checks older pages after a 350ms debounce if the
results do not fill the viewport. The app retains up to 1,000 chats and allows at
most 100 pages per refresh (including child-only pages), labeling capped lists
incomplete. No total chat count is available from the connector.

The chats app bar shows the folder name with a small online/offline icon,
retaining accessible labeling without visible Online text. Below it, a quiet
search field and a compact **New chat** button (a `+` icon, labeled for
assistive tech) share a row. The search field includes a clear action and
retains **Search loaded chats** while more pages remain. Chats are grouped into **Pinned**, **Today**,
**Yesterday**, then exact local calendar dates such as **Sep 4 2026**, newest
first and omitting empty sections. Pins appear only in the Pinned section.
Small section markers use an amber pin, a green Today dot, a blue Yesterday dot,
and gray dots for older groups. Semibold dates, muted years, and fine divider
lines distinguish sections. These decorate the visible section labels and
do not indicate session activity. Rows give medium-weight titles up to two lines,
use short update times and subtle dividers,
and omit repeated chat icons. The list remains lazy, scrolls with the keyboard,
and keeps pull-to-refresh available. Scrolling within 320 logical pixels of the
bottom fetches another page with a small inline spinner, announced as Loading
older chats or Searching older chats for screen readers. Short/child-only pages
continue until the viewport fills or pagination ends. Only one request runs at
a time; offline/background states pause fetching. Failed continuations retain
existing rows and expose an explicit **Retry loading chats** action rather than
automatically retrying. Refresh/reconnect obtains a new authoritative list.
Chat rows open on tap and use a three-dot menu for **Pin chat / Unpin chat** and **Delete chat**.
Pins stay above ordinary chats, survive app restart on this device, and can bring
older chats into the first page. Up to 20 pins per project are stored as opaque
IDs in native secure storage. Delete confirms removal from OpenCode, including
sub-agent conversations, and requires an updated plugin. See the
[pin/deletion ADR](../../packages/agents/opencode/docs/adr/0003-chat-pins-and-deletion.md).

See the [rendered chat-list preview](previews/chats.png) with sample data.

Conversation uses a tappable chat title, a small accessible online/offline dot,
and a vertical three-dot menu containing Rename, Fork, and Refresh. There is no
breadcrumb row beneath the title. Tapping the title opens Chat details with its
full name, current connection/chat status, project path, and location links.
The connection returns to Projects; the folder returns to Chats. Details Back
returns to the same conversation without resetting its scroll position or draft.
Long names wrap in details and truncate with a full-name tooltip in the header.

**New chat** opens a local draft in the selected directory. Opening, typing,
refreshing, or leaving it creates no OpenCode session. The first nonblank **Send**
creates the session and submits the prompt; subsequent sends reuse its ID. Drafts
are not polled or included in chat lists. If the first prompt fails after creation,
the app preserves its text and confirmed session for an explicit retry. An
uncertain creation blocks another create until the user returns to Chats to
reconcile. Creation and prompt submission are separate requests, so a first-send
failure can leave a confirmed session without a message.

Conversation shows bounded message snapshots and tool summaries,
with a text composer and Stop. It polls authoritative snapshots every three
seconds while active. Assistant messages now render selectable Markdown,
including lists, headings, code, and tables; user prompts remain literal text.
Images are blocked and links are passive selectable text. See the
[Markdown rendering contract](design.md#markdown-messages). This iteration does
not yet provide event streaming, todos, or permission-response controls.

Conversations open at the newest message in a bottom-anchored lazy list. Scrolling
within 240 logical pixels of the top requests 10 earlier messages and shows a
compact spinner announced as **Loading earlier messages**. Older pages grow above
the visible messages without changing their scroll offset. Short or empty pages
continue automatically while the viewport needs more history. Failures preserve
the cursor and existing messages, with **Retry loading earlier messages** shown
only after a failure; polling never retries a failed history request.

History and latest-page reads are single-flight. Offline/background transitions
pause requests and ignore late responses; changing chats clears history state.
Latest-page polling preserves the oldest cursor, including exhausted history.
Explicit refresh or reconnect resets to the latest snapshot with a fresh cursor.
At most 200 messages are retained and 100 earlier pages may be fetched per history
reset; reaching either limit stops pagination and displays an incomplete-history
notice. Cursor cycles fail closed. These limits also bound automatic requests
when authenticated but invalid responses contain no new messages. No protocol,
authorization, encryption, logging, or durable-storage behavior changes.

## Protocol and security

The existing presence WebSocket carries authenticated HPKE encrypted requests
and responses; mobile never connects directly to an OpenCode port. The shared
[chat contract](../../packages/protocol/src/protocol/chat.ts) defines capability
version 1: `project.list`, `project.open`, `chat.list`, `chat.snapshot`,
`chat.create`, `chat.prompt`, `chat.abort`, `chat.get`, and `chat.delete`. Legacy `session.list` remains a
separate operation. Unsupported capabilities give an explicit plugin-update
message.

The adapter uses the SDK transport supplied by OpenCode. Its fixed `/api/session`
compatibility route provides directory-scoped pagination, verified against pinned
OpenCode 1.18.25. Session-ID operations independently check directory membership.
Canonical path and filesystem identity are checked before operations. Native
cursors remain in a bounded five-minute local map behind opaque IDs.

Only pinned, currently authorized peers may exchange commands. The relay routes
opaque envelopes and owns no chat history. Outer metadata is authenticated,
responses are correlated by peer/request/operation, and replay windows, queue
limits, payload limits, and deadlines bound work. A five-minute in-memory plugin
journal deduplicates create/prompt/abort request IDs (128 entries); it does not
survive restart. Clients never automatically repeat uncertain mutations.

Android uses Bouncy Castle HPKE; iOS uses CryptoKit HPKE and requires iOS 17 for
chat encryption. Keys remain in native secure storage. Native iOS compilation
and interoperability still need an isolated Apple test environment.

Projects, chats, messages, and drafts remain in process memory. Backgrounding
suspends chat work. Resume/reconnect obtains fresh authoritative state; late
responses cannot reopen a previous selection. Trust loss and revocation clear
affected decrypted state and drafts. Offline content is visibly stale.

See the [access-policy ADR](../../packages/agents/opencode/docs/adr/0002-authorized-project-contexts.md)
for remaining filesystem races and single-endpoint limitations.

## Verification and remaining work

Run `flutter analyze`, `flutter test`, protocol/plugin tests, and the pinned
OpenCode integration suite. The native Android test uses
`./tool/test_local_android.sh emulator-5554`, the isolated
`com.openremotecode.app.integration` application, and `--no-uninstall`. It pairs
synthetic identities, uses the real authenticated server relay and real plugin,
and checks native encryption, project discovery, main-session filtering, reading
messages, creating chats, denied paths, secure restoration, and revocation.
Never uninstall or clear the interactive app to run tests.

Remaining milestones: independently routed concurrent OpenCode endpoints,
streaming events, one-time permission responses, richer conversation rendering,
and native iOS verification. The default current-directory path is the native
end-to-end tested baseline; multiple configured directories require further
lifecycle testing before a multi-endpoint release.
