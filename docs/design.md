# Mobile design, iteration 1

The proposed next iteration is documented in
[Project and chat navigation](chat-navigation-plan.md). That plan describes
future behavior; this document records the currently implemented design except
where a section explicitly defines a target pending implementation.

Real authentication gates the Connections home. Debug builds default to
`http://127.0.0.1:8080`; saved origin and build override precedence remain intact.
Use the normalized server origin as a visible signing destination while keeping
its editor hidden behind six background/branding taps.

## Home and navigation

Connections is the home destination. A left drawer opens from the menu button on
phones; at 720 logical pixels or wider a 280-pixel sidebar stays visible.
Settings displays the authenticated account and Sign out. The green indicator
shows the selected destination. Every screen shares one warm off-white
background (`#F7F8F2`); app bars match it with no scroll tint, so white input
fields and cards stand out against the page.

Show an empty state with Enter pairing code before the first connection. Existing
connections form a lazy list, online first. Offline, unknown, and verification
required states remain visible with text and icons. A missing local pairing explains
that account membership does not authorize this device. A different saved identity
has a separate Connection identity changed warning; presence cannot clear either state. Pull to refresh retrieves
server inventory. Do not infer online status from an inventory response.

Add connection opens one small code field, with normal paste support. Connect
claims the code and shows the locally computed safety code. Only Codes match —
confirm authorizes trust. A mismatch, expiry, or failed verification must never
create a trusted card. Network failures are recoverable without automatic retries
of trust-changing requests. No camera/QR flow is needed in this iteration.

## Visual language

| Token | Value | Use |
| --- | --- | --- |
| Primary | `#DBF4AD` / RGB `219, 244, 173` | Main action, brand tile, neutral notices |
| Ink | `#20251D` | Headings, button labels, focus outlines |
| Muted | `#60665B` | Supporting text and icons |
| Background | `#F7F8F2` | Warm, quiet screen surface |
| Border | `#DCE0D4` | Field outlines |
| Input surface | `#FFFFFF` | Email, password, server fields |

Use `AppTheme` as the source of truth. Pale lime always gets a dark foreground.
Use `AppButton.primary` for lime actions and `AppButton.secondary` for outlined
actions with dark labels and icons. Both use the shared theme for padding,
corners, and touch targets, and support optional icons and wrapping labels.
For asynchronous actions, pass `isLoading` and a descriptive `loadingLabel`;
the component disables activation and announces progress while the caller
continues to own the operation and error handling. Plain Material buttons also
inherit the shared theme; outlined actions must never inherit pale lime text.
Errors use Material error colors, descriptive text, and a live semantic region.
Connection cards use the reusable `StatusBadge` with semantic colors from
`AppTheme`: green for online, neutral gray for offline, amber for verification
required, red for an identity change, and blue for unavailable status. Dark
labels and icons sit on softly tinted backgrounds. Every status retains its
text and distinct icon so color is never the only signal. Badges wrap with
large text and are informational, not additional tap targets.
Connection cards have a 1-pixel soft gray (`#DCE0D4`) border. Tapping a card
selects it with a 2-pixel dark green (`#21663A`) border, a Selected label, and
selected accessibility semantics. Only one card is selected at a time; selection
follows its ID through sorting and rename, and clears when it is removed.
Offline cards use a muted gray (`#60665B`) border, including when selected.
Their selected state keeps the 2-pixel border and Selected label in muted gray.
Border colors update with presence while preserving selection.
Selection is temporary UI state and does not open a relay or authorize trust.
Status badges continue to describe availability independently of selection.
Use the platform font without network font downloads. The hero is 40 logical
pixels, body text is 14–16, and secondary microcopy is 10–12; essential instructions
remain body size. Use 4/8-pixel spacing increments, 16-pixel control corners,
48-pixel minimum tap targets, and a 56-pixel minimum primary button height.

The layout uses safe areas, a 460-pixel maximum content width, and scrolling when
the keyboard or large text reduces available space. Text can wrap and scale;
there are no fixed-height text containers. There are no decorative animations,
blur layers, remote images, or unnecessary network polling. Flutter's standard
controls provide focus behavior, labels, and password visibility affordances.

## Chat color palette

This implemented light-theme palette uses a tinted reading surface and
muted forest-green Markdown emphasis. The same `#F7F8F2` surface is now the
shared background for every screen, so the conversation no longer stands apart
from the project and chat lists. It does not define a dark theme.

Use a warm, lightly green-tinted reading surface and muted forest-green emphasis.
The goal is to make bold phrases feel like part of the response rather than
success labels, while preserving the existing lime brand and amber thoughts.

| Role | Value | Use |
| --- | --- | --- |
| Chat background | `#F7F8F2` | Entire conversation surface and chat header |
| Regular text | `#20251D` | Message body, headings, and composer text |
| Bold text | `#36543C` | Inline Markdown bold in assistant responses |
| Secondary text | `#60665B` | Timestamps, descriptions, and supporting labels |
| Thinking text | `#805500` | Thought/Thinking label, preview, icon, and timing |
| Subtask title | `#496573` | Muted slate-blue task title and completion check |
| Subtask metadata | `#60665B` | Tool-call count and elapsed time |
| Code background | `#ECEFE5` | Inline code and fenced code blocks |
| Composer surface | `#FFFFFF` | Input surface, distinct from the conversation |
| Primary actions | `#DBF4AD` | Brand lime fills with dark ink labels and icons |
| Subtle border | `#DCE0D4` | Dividers, card borders, and code outlines |
| Soft border | `#ECEEE7` | Half-pixel edges a fill already defines: input outlines, the effort slider's track |
| Status green | `#21663A` | Existing success, online, and selected-state accents |

### Usage rules

- Apply the background tint to the whole conversation and its header for one
  continuous reading surface. Do not add individual message bubbles or cards.
- Keep bold weight as well as the muted green color. Scope this accent to inline
  Markdown bold, not every bold label, heading, table header, or button in the app.
- Keep headings in dark ink; establish hierarchy through size and weight.
- Do not put a colored highlight or pill behind bold phrases. Code alone keeps
  its distinct surface, monospace type, and existing border treatment.
- Keep thoughts amber and retain their label, icon, and italic preview so their
  meaning does not depend on color alone.
- Keep the composer white, with dark text and a soft hairline border. Its surrounding
  area should continue the chat background rather than create a white band.
- Preserve success green for status and selection. Markdown emphasis must have
  its own theme color instead of reusing `AppTheme.success`.
- Define colors centrally in `AppTheme`, not as literals in individual widgets.
  Never use pale lime as text on white or on the tinted chat background.

### Subtask styling

- Use muted slate blue `#496573` with medium weight for subtask titles, such as
  "Explore Task: Inspect mobile colour palette". This distinguishes delegated work
  from forest-green bold emphasis and amber thinking text.
- Render metadata such as "15 tool calls · 1m 22s" in smaller secondary text using
  `#60665B`. Preserve readability when text scales.
- Keep subtasks directly on the `#F7F8F2` conversation background without colored
  cards or bubbles.
- A completion check may use the same slate blue as the title. Do not turn the
  entire completed task green; reserve success green for explicit success feedback.
- Pair an icon with an explicit state label for running, completed, or failed
  tasks. Color alone must not communicate task state.
- Define the subtask color centrally in `AppTheme`. This is a light-surface color,
  not a direct copy of the blue-gray foreground used by the dark TUI.

### Verification before rollout

- Check normal-sized text contrast of at least 4.5:1 on its actual surface,
  including bold, secondary text, thinking text, subtask text, and code.
- Verify the header, conversation, composer, and code surfaces together on a
  small screen and with large text; preserve the existing message spacing.
- Add widget assertions for the chat surfaces and Markdown bold color and weight.
  Confirm headings and status colors remain independent of inline emphasis.
- Verify subtask title and metadata styles, explicit state labels, and wrapping
  at large text sizes.
- Treat this as a light-theme specification only. A future dark theme needs
  separately defined and contrast-checked colors rather than reusing these values.

## Server selection and session behavior

Six taps open configuration, with no more than two seconds between consecutive
taps. Form controls retain their gestures. Partial sequences reset on background
and modal changes. The editor validates a normalized origin and saves only after
a successful preference write. Switching origin destroys entered credentials.
Configuration is available only while signed out; it grants no privilege.

HTTPS is required, with debug-only HTTP for exactly loopback hosts. Android debug
network policy matches this exception. ADB reverse forwards device loopback to the
development machine. Saving an origin does not imply that it is reachable.

Login is asynchronous and prevents duplicate submissions. The workspace opens
only after the server authenticates and the refresh credential is securely saved.
Cold start shows a brief restoration state and asks the server to rotate saved
credentials. Failure stays on login with a useful error and retry. Sign out
clears local session state and attempts server revocation. Failure to delete
secure storage keeps the session visible so the user can retry.

## Connection actions

A three-dot menu contains Rename and Delete. Rename opens a prefilled name field,
validates a nonempty name against the server limit, and saves before updating the
row. Refresh cannot overwrite a successful rename with an older list response.
The server name is shared across the account; identity and trust stay intact.

Delete opens a confirmation describing account-wide revocation. The action
waits for the server, prevents duplicate deletes and new pairing during deletion,
and keeps the row on failure. Remove the local pin only after acknowledgement;
never present a local-only deletion as successful revocation. A failed local
cleanup reports that remote revocation succeeded and allows an idempotent retry.
OpenCode chat conversations and other connectors remain unchanged.

## Conversation header and actions

The conversation header keeps Back, the agent mark, a tappable left-aligned
single-line title, and a vertical three-dot Chat options menu. A 56-pixel
leading slot and 4-pixel title spacing reduce the visual gap without shrinking
the back target. Long titles have a full-title tooltip. The title and the model
line below it sit tight against each other, with the whole two-line block as one
48-pixel tap target rather than each line padding itself out; the bar grows only
when scaled-up text needs the room. The status badge rides the agent mark's
bottom-right corner: online is a filled green dot, offline an outlined muted dot,
and while the chat is working -- its session busy, a tool running, or a subtask
(background ones included) still pending, running or retrying -- the badge is the
same activity spinner the conversation's rows use, on its own clock that runs
only while work is in flight. Each state has a tooltip and a screen-reader
label, so status is not
communicated by color alone. Refresh lives in the menu
alongside Rename chat and Fork chat, not in a separate header row, and the menu
also carries Show task list while a dismissed list is being held back. Project
and chat-list headers retain their existing layout.

### Task tab and task banner

When the chat has a task list, an inverted tab hangs down from the middle of
the header into the conversation. It starts at the header and drops from it:
flat along the top so it continues the bar's own edge, centered horizontally,
and raised over the messages -- it floats on top of the conversation rather than
occupying a band of its own, so the list keeps its full height and scrolls
underneath.

The tab is drawn as a shape that grows out of the header rather than one stuck
onto it. Where it starts and ends, the ink flares about 10 pixels sideways along
the header's hairline and curves back in -- a concave shoulder on each side,
filleting the join the way a branch meets a trunk -- while the two corners
hanging in the conversation round off the ordinary way by 14. The shoulders are
drawn outside the tab's own box, so they belong to the header's edge rather than
to the label: widening them never moves the text and never grows the tap target
sideways into the conversation.

The tab is dark ink filled with a lime checklist glyph, a light **Tasks** label
and a lime `2/5` count; it is the one element up there that reads as a counter
rather than a title, so it is filled and inverted against the light chat surface
instead of outlined like everything else. It is not in the header itself: the
bar keeps Back, the title block and the Chat options menu, and the counter no
longer competes with the title for width.

Width is the one dimension the tab spends freely: 28 pixels of padding on each
side of the line, so it reads as a tab drawn across the header rather than a
chip pinned under it -- about 183 by 26 pixels at the default text size, growing
with the user's. Widening it costs the conversation nothing, because the tab
hangs over the messages instead of displacing them. Height it does not spend: it
hugs its one line with 6 pixels above and below, and does not pad itself out to
a 48-pixel target, which would hang dead ink between the header's edge and the
words. The tab's width keeps it an easy target even so, and the visible tab is
the whole of it -- nothing invisible hangs below it to swallow a tap meant for a
message. A chat with no task list has no tab at
all -- not an empty or zeroed one, and nothing reserved where it would be. The
count is announced in words ("Tasks, 2 of 5 done") and as a live region, so a
task ticking over is heard without reopening anything.

Tapping the tab raises the task banner, a bottom sheet like the model banner.
It leads with **Tasks** and the same count in words, then a slim lime progress
bar, then the tasks in OpenCode's own order. Each row is a state icon, the
task's text, and that state in words underneath -- To do, In progress, Done,
Cancelled -- so state never rests on an icon or color alone. A completed or
cancelled task's text is muted, a cancelled one struck through, and the task in
progress is the only one in medium weight. Task text is always plain text,
never Markdown.

The banner is read-only: nothing in a row is tappable and there is no way to
add, reorder, complete, or clear a task. The agent owns its list; this app
counts and shows it. The sheet stays live while it is up, and a banner left
open over a chat the conversation has since left closes itself rather than
showing another chat's list.

### Dismissing a finished list, and getting it back

Once every task on a list is done, the banner offers **Hide task list** in its
bottom-right corner, which closes the sheet and takes the tab with it. Hiding
is a display decision only: the list is untouched, still read on every snapshot
and still counted. Its screen-reader hint says so, and says where the way back
is.

That way back matters, because the tab is the only route into the sheet.
**Show task list** therefore appears at the top of the Chat options menu,
ahead of a divider, for exactly as long as a list is being held back --
dismissing it is undone by the same menu that holds Rename, Fork and Refresh,
without waiting for the agent to write a different plan. A list also returns on
its own the moment it stops being fully done: a task added or reopened later is
never hidden behind an old dismissal of a different, finished list.

A dismissal belongs to the chat and to the exact list dismissed, not to the
current screen: going back to the chat list and opening the chat again keeps a
dismissed list hidden, and bringing it back is remembered the same way. A
different finished plan -- other tasks, or the same tasks reordered -- is shown
until it is dismissed in its turn, and an empty list (which is also how a
failed read arrives) neither shows anything nor forgets the dismissal. The
record is kept in memory for as long as the chat flow is open and is never
written to the device: it is derived from task text, which this app does not
store. Closing the flow or restarting the app shows a finished list again.

Hiding is offered only where that undo exists. A subtask conversation has no
Chat options menu, so its banner has no Hide -- nothing there can dismiss a tab
it could not bring back.

Tapping the title opens Chat details with the full wrapping chat title first and
centered, followed by connection/project breadcrumbs with the unlabeled project
path, MCP servers, and chat actions. One-pixel dividers with consistent vertical
spacing separate the sections. The path preserves its exact text: parent folders
use the theme's blue information color, the final separator is muted, and the
project folder is emphasized in forest green with medium weight. It remains plain
display text, not a filesystem link. The connection breadcrumb
opens Projects and the project breadcrumb opens Chats. There is no Location
heading, presence badge, or chat-status display on this screen; connection
presence remains in the conversation header. The breadcrumbs wrap at large text
sizes and retain accessible 48-pixel tap targets. The details screen uses accessible
tap targets. Returning with Back preserves the conversation, scroll position, and
unsent draft. Duplicate opens are guarded; details clear and dismiss when trust
or the source conversation is invalidated. Opening details does not create a
session; existing chat snapshot polling still updates its title.
The separate, read-only MCP topic below is active only while details are visible.
The final section offers Fork chat and Delete chat with 48-pixel tap targets.
Delete uses the theme's danger/error text color and requires an explicit,
source-bound confirmation. Busy, offline, unsupported, draft, and subtask states
disable unavailable actions. Errors stay visible; uncertain forks cannot be
repeated without reconciliation. A confirmed fork opens its new conversation;
confirmed deletion clears the active conversation and draft and returns to Chats,
even if clearing a saved pin later fails. No action changes MCP configuration.

Action safety: the confirmation retains its original chat identity and project
path and rechecks trust, visibility, availability, and capability before dispatch.
Source/trust loss or backgrounding cancels confirmation; offline or busy status
disables it. Existing versioned encrypted commands and plugin authorization
remain the final boundary. Late acknowledgements cannot clear another chat, and
only confirmed deletion (including authoritative not-found) removes local
conversation/draft state. No new filesystem, MCP control, or permission access
is introduced, and neither confirmation text nor action errors are logged.

### MCP server status

Keep the existing title route and breadcrumb navigation. The **MCP servers**
section follows the location information and a divider, without a redundant Live status
label. Server names are plain, wrapping text. Connected
servers show only their name and the theme's success-green dot, without a visible
Connected label; screen readers still announce the status. Disabled, Failed,
Needs authentication, and Needs client registration retain visible labels. Only
a current, connected server has a green dot. Stale status uses a muted outlined
dot and explicit section-level last-known messaging. Rows are
passive, including their screen-reader semantics: no tools, connect, authenticate,
configure, or other mutation actions.

A details-scoped `McpViewModel` owns a separate encrypted project subscription,
not an `includeMcp` option on `chat.snapshot`. It listens before subscribing,
accepts the largest matching revision, renews the same ID every 30 seconds under
the v1 60-second lease, and uses a fresh ID after reconnect or resume. Closing,
covering, changing source, and backgrounding stop updates with best-effort
unsubscribe. A late subscribe acknowledgement receives another best-effort
cleanup only on its original connection generation.

Loading, unsupported, unavailable, offline, paused, empty, and last-known states
are labeled explicitly. Stale or failed renewal never claims live green status;
without updates or a successful renewal freshness expires after 45 seconds.
Trust loss clears all names, and source changes cannot reuse another project's
snapshot. Draft details use their project without creating a chat. Failures in
this topic do not change conversation fetching, composer state, or chat errors.
See [MCP status contract and threat analysis](mcp-status.md).

Rename chat opens a prefilled, scrollable dialog. Trim the title and require
1-512 UTF-16 code units, matching the encrypted protocol. Keep input until the
connector acknowledges the rename; failures stay in the dialog. Disable Save
during snapshot reads and conflicting work rather than dropping a submission.
Dismiss and clear the dialog when trust or its source conversation changes.
Renaming preserves session identity, message history, pins, and the unsent draft.

Fork chat copies the entire history at its end, then opens the confirmed new
chat with an empty composer. The original history and in-memory draft remain
unchanged. Fork is available only for an existing, idle chat; both actions
require an online trusted connector advertising the corresponding capability.
Unsupported plugins display restart guidance. Draft chats can use menu Refresh
without creating a session; Rename and Fork remain disabled. Refresh is disabled
offline and during conflicting reads or mutations.

Mutations remain serialized across background and navigation transitions.
Neither action retries automatically. An uncertain fork blocks further forks
from that source until the user returns to the authoritative chat list. A late
confirmed fork does not navigate after cancellation; it tells the user to find
the new chat in Chats instead. Snapshot polling alone cannot clear either guard.
Errors/progress use fixed text without logging titles or conversation content;
titles and mutations remain inside encrypted relay payloads. Authorization,
deadline, and deduplication limits are documented in
[plugin ADR 0005](../../packages/agents/opencode/docs/adr/0005-chat-rename-and-fork.md).

## Conversation composer

The composer is a single compact row: a white multiline input with no visible
label or placeholder, beside a 48-pixel circular lime send button. The input
keeps its Message accessibility label. Empty text cannot be sent; sending shows
an accessible progress indicator and prevents repeat activation. Stop remains
available beside the input while a response is active.

Long-press Send to open a minimal Build/Plan picker without submitting text.
The button has a mode-aware accessibility label and tooltip; Shift+F10 opens the
same picker when the button has keyboard focus. Build uses an upward arrow and
Plan a planning icon. The picker keeps explicit labels and a selection check.
Build is the initial choice on capable connectors. A chosen mode applies to
subsequent prompts while this chat flow stays open, survives failed sends and
navigation, and is not persisted to disk. Mode changes are blocked during sends;
each prompt captures its choice before asynchronous chat creation.

Explicit modes require both `chat.prompt` and `chat.prompt.mode` capabilities.
Older connectors keep their text-only behavior and show update guidance in the
picker, not a false Build/Plan selection. Loss of capability blocks a previously
selected mode instead of silently downgrading it. Stale picker results cannot
change another chat, an offline connection, or a revoked connection. Choices
travel only inside encrypted prompts; no additional logs, storage, automatic
retries, or permission grants are introduced. Plan follows local OpenCode
configuration rather than guaranteeing read-only execution. See the
[prompt mode contract and threat analysis](../../packages/protocol/CHAT-PROMPT-MODE.md).

## Model and effort banner

A sparkles button inside the input raises the model banner, a bottom sheet like
the Build/Plan picker: it comes up from the bottom edge over the composer, so
the input and Send sit behind it rather than beside it. The button is hidden
while a prompt is actively being written. Raising the banner is the only way in;
dismissing the sheet is the way out.

The banner is one centered line -- the model's name, the effort in force beside
it in muted text, and a chevron -- above the effort control. The whole line is a
48-pixel tap target through to the searchable model list, which replaces the
banner. Choosing a model that reports effort levels raises the banner again so
its slider is there to set them; a model without levels finishes there. The list
names models and providers only; effort is not repeated per row.

Effort levels are one slider inside an outlined pill: a dot per stop, lime fill
up to the chosen one, and a dark ink thumb, never pale green carrying a shape
against white. Its leftmost stop is Default -- no effort travels with the prompt
and the model's own applies -- followed by the levels the connector reports, in
its order. Every stop keeps its text label on the slider's value semantics and
in the banner's title, so the control never reads as thumb position alone.
Dragging commits when the drag ends, not per step. A model reporting no levels
is its title alone; an unsupported connector shows update guidance there
instead, and the banner disables rather than closing during sends.

Raising the banner is what fetches the provider list, never chat load. A model
recovered from a chat snapshot carries ids alone, so the list swaps in the real
option for its name and levels and drops a recovered level that option does not
offer. A banner left open over a chat the composer has since left is disabled,
not applied: like the mode picker, a stale sheet cannot change another chat, an
offline connection, or a revoked connection.

## Conversation messages and thoughts

Messages sit directly on the conversation surface with 24-pixel spacing, without
individual backgrounds or rounded cards. User messages have a You label;
assistant messages omit the repetitive OpenCode label and its header spacing.
Code blocks retain their existing code surface.

A prompt the user sent keeps a rounded code-surface panel, the full width of the
conversation rather than the width of its words, so every prompt starts and ends
on the same edges as the replies between them. A prompt sent in Plan mode says
so in its own bottom-right corner: the word Plan in 9-pixel muted italic, inside
the panel and below the words. It reads as part of the prompt and announces as
"Sent in Plan mode".

Plan mode marks the agent's side differently: what the agent itself says sits
inside a 3-pixel `AppTheme.info` rule down the left with a 10-pixel gutter,
which is what identifies planning at a glance while scrolling. The rule hugs
that prose alone. Thought rows and tool runs stay outside it, keeping their own
gutters, icons and status lines rather than nesting inside a second rule, so a
mixed message shows the rule beside its words and nothing beside the rest. A
prompt never carries the rule either -- its corner mark says the same thing in
text.

Provider reasoning appears in its original position as a display-only Thought row:
a small psychology icon, 12-pixel amber `AppTheme.warning` text, a semibold label,
an italic first-line excerpt, and 11-pixel monospace timing. This dark amber is readable on
white; label and icon distinguish reasoning without relying on color. Rows have
no toggle, expansion arrow, repeated detail body, or button semantics.
Thought rows use a compact 32-pixel minimum height and grow when text wraps.
Confirmed running thoughts use the shared activity spinner in the same icon box;
finished thoughts restore the psychology icon.
They remain readable by screen readers as ordinary text.

Duration comes only from valid start/end timestamps. An unfinished final thought
in the latest message says Thinking only while the connector is online and the
session is busy. Idle/offline snapshots stop claiming active work; missing clocks
show no duration. Snapshot updates replace the visible excerpt and timing.
No provider text means only the Thought/Thinking label is shown. Older
plugins fall back to ordinary text; recognizing reasoning requires the updated
plugin. The bounded encrypted contract and threat analysis are documented in
[chat reasoning](../../packages/protocol/CHAT-REASONING.md).
See the [rendered conversation preview](previews/chat-thoughts.png) with synthetic
messages.

File mentions retain the authored prompt and a compact `[File: filename]` label.
OpenCode's synthetic attachment expansion is excluded by the plugin, not rendered
as user prose. File labels are passive: no download, preview, or file-opening
action. The authoritative local file context is unchanged.

## Tool messages

Tools are compact terminal-style log entries directly on the conversation
background, without cards or bubbles. A leading arrow or operation icon precedes
only the available filename or short description, for example
`lib/example.dart` or `"Theme|Color" in mobile/lib`. Operation words such as Read,
Search, Run and Tool are not displayed; they remain in screen-reader labels.
If no safe description is available, a completed row shows only its icon, except
execution summaries which fall back to Run command. Typed activities without a
description use the activity registry's label.
Known MCP actions use fixed summaries such as Capture screen or Inspect screen
elements; arguments and outputs are not displayed. Search patterns
and optional locations are bounded descriptions; matched content is never shown
in the row. The line uses regular-weight 12-pixel UI text in slate
blue `#496573`, shared with subtasks. Long entries wrap rather than truncate.
Completed tools have no separate status or timing line; their completion and
valid timing remain in the accessibility label. Other states appear inline in
parentheses after a description, or alone when there is no description, with
muted text for pending/running/unknown or last-known status.
Failures retain an error icon and explicit Failed label in the error color;
the description remains slate blue.
Unknown tools use a bounded, humanized tool name as a description. Summary rows
do not expose raw command/output/error bodies or open files/execute actions.
Negotiated shell details are the explicit exception described below.

Thoughts, tools and subtasks use 12-pixel icons matching the header font size,
without per-glyph optical enlargement. Icons, spinners and disclosure arrows scale
with accessibility text size and are centered on the first header line, including
when titles wrap. The gutter is the scaled icon width plus 8 pixels.
The conversation keeps its 20-pixel inset, so activity text starts at 40 pixels at
default text size; prose remains at 20 pixels. Metadata aligns with titles.
Rows use 4-pixel vertical padding; subtasks retain a 4-pixel title-to-metadata gap.
Tools have no separate metadata line. Passive rows
have a 32-pixel minimum height and grow naturally; navigable subtasks have a
48-pixel minimum tap target. Consecutive tools, thoughts and subtasks have no added
24-pixel gap, including when OpenCode splits them across messages. Whitespace-only
text parts and empty projected records (including synthetic-only shell user
messages) do not add padding or interrupt activity.
Visible history messages keep their own keys; they are not merged. The 24-pixel
separation remains at user/prose boundaries and after truncation notices.

Explicit states and icons distinguish work without relying on color. Unfinished
tools are last known when offline or the message is no longer active. Subtasks
remain distinct through their agent labels and verified navigation affordances.
Structured tools require the `chat.tools` capability; older connectors retain
plain summaries until restarted with the updated plugin. See the
[tool contract and threat analysis](../../packages/protocol/CHAT-TOOLS.md).

### Collapsible shell history

When both `chat.tools` and `chat.shell` are advertised, mobile requests shell
details. Each shell starts collapsed: a compact, full-width 32-pixel minimum toggle header shows a
bounded description (or Run command), status and valid timing.
Shell headers use the same 4-pixel vertical padding as thought/tool rows, without
additional Material button padding; larger/wrapped text grows naturally.
When expanded, command and output appear below as selectable
13-pixel monospace text on the code surface, aligned to the activity gutter.
Long lines wrap. Empty completed output says No output; unfinished output says
Waiting for output; shortened details carry an explicit notice.

Collapsing removes both command and output, including accessibility content, while
retaining the description in the header. Each choice survives same-ID live/polling
updates and off-screen recycling independently, including in subtask history.
Only IDs from bounded loaded history are retained; history reset/navigation clears
the choices. No detail or choice is persisted to disk. The toggle is keyboard and
screen-reader accessible and reports its expanded state. Literal content does not
execute commands, open links or fetch images, and terminal controls are stripped.
See the [shell contract and threat analysis](../../packages/protocol/CHAT-SHELL.md).

### Shared live activities

Read, execute, think/thought, apply patch, search, task-list updates and subtasks
use the same 12px/1.35 header typography, 11px secondary text and icon geometry.
The language-neutral vocabulary lives in `packages/protocol/schema`; the mobile
visual registry is `activity_presentation.dart`. Native names are mapped only in
the host adapter, so future Pi integrations use the same rows.

Running glyphs share a single clock and repaint independently of message text.
Visibility checks stop cached off-screen animations. Backgrounding, covered routes
and reduced motion stop the clock; reduced motion retains a static state indicator.
No per-row timer or whole-row pulse is used. Completed activities show their final
operation icon. Unchanged Markdown rendering is cached.

A running reasoning activity says Thinking immediately, even before its first
text delta or while the aggregate session status is catching up. Losing permission
to animate does not turn it into a completed Thought: stale running data is shown
as last known. End/failure events restore the final state and icon.

The conversation has a compact, left-aligned three-dot typing bubble at its newest
end while a prompt is being submitted or the agent is working. It stays visible
alongside thought/tool activity and between blocks, then disappears on completion
or disconnect. The three dots pulse in sequence using the existing shared clock;
reduced motion displays static dots. One semantic label announces Sending message
or Agent is working, without announcing individual dot pulses. The footer is keyed
independently of messages, and a visible message anchor preserves the reader's
position when it appears or disappears in older history.

Capable peers use encrypted revisioned message replacements, batched at 100ms,
instead of three-second chat polling. Shell and reasoning progress and assistant
text arrive before completion. Live text uses a cached-part delivery path with
fresh authorization checks, rather than waiting for full history/subtask reads.
Source snapshots reconcile reconnects and revision
gaps; incomplete pre-subscription prefixes are explicitly labeled. Hidden chats
(including while viewing Details) stop their subscriptions and reconcile on return.
The initial stream is established before a new draft's first prompt. See the
[activity/stream contract and performance safeguards](../../packages/protocol/ACTIVITY.md).

## Subtask conversations

Task calls display their agent and description, for example **Explore Task —
Inspect mobile color palette**, above `Completed · 15 toolcalls · 1m 22s`. Titles use muted
slate blue `#496573` with medium weight. A verified child has a chevron and an accessible, wrapping tap
target; tapping it opens a read-only child chat. Back restores the parent chat,
scroll position and unsent draft. Child views offer Refresh and preserve normal
message-history pagination; they have no composer or chat mutation menu. Nested
child navigation is limited to eight levels.

Running, retrying, failed and unavailable states are explicit. Offline rows mark
active status as last known. Partial history shows a lower-bound count (`15+`)
and no duration. Deleted/unverified children have no open action. Trust loss
clears both child and parent content, and late responses cannot reopen a closed
view. Parent polling pauses while a child view covers it.

Older connectors keep their plain tool text. Restart OpenCode with the updated
plugin to advertise the new capability. See the
[encrypted subtask contract](../../packages/protocol/CHAT-SUBTASKS.md).
Rendered synthetic previews: [task row](previews/chat-subtasks.png) and
[child conversation](previews/subtask-chat.png).

## Markdown messages

Assistant text renders as selectable GitHub Flavored Markdown with pinned
`flutter_markdown_plus` 1.0.12 and `markdown` 7.3.1. User prompts remain literal
selectable text. The renderer handles assistant text parts without merging or
duplicating them; thought excerpts are plain styled text. Formatting includes headings,
emphasis, strikethrough, paragraphs, line breaks, ordered/unordered lists, static
task checkboxes, quotes, inline/fenced code, and tables. No syntax highlighting,
LaTeX, Mermaid, or remote font loading is introduced.

Use dark text and the existing app theme. Inline bold Markdown text uses muted
forest green `#36543C` (`AppTheme.markdownBold`), independently of status green.
The [chat palette](#chat-color-palette) defines the conversation and code surfaces.
Code is monospace on a quiet bordered
surface. Long code and tables scroll horizontally inside the existing lazy
conversation list; messages never add a second vertical list. A SelectionArea
allows selection across text blocks without SelectableText's scroll gestures
capturing horizontal code swipes. Unclosed fences render their current contents
and update as authoritative snapshots replace the same message ID. The original
message and truncation notice remain intact.

Rich rendering is limited to 16,000 UTF-16 code units, 512 newlines, and fewer
than 16 leading block-markup/indentation characters on each line. Larger or
deeply structured content falls back to the complete selectable source with a
notice, not another truncation. These are conservative rendering limits on top
of the existing 48,000-unit wire limit and bounded message history. The renderer
reuses its parsed widgets when text and styles have not changed.

### Security boundaries

Treat Markdown and its destinations as untrusted display data. Raw HTML blocks
render literally rather than being executed or silently dropped. Images from
all schemes, including network, file, asset, and data URLs, become an explicit
not-loaded placeholder with their alt text. Rendering must not load external or
local resources, perform native platform calls, or write conversation data.

Links display their label and actual destination as selectable text with no
link gesture recognizer, browser launcher, or URL resolution against the project.
Task checkboxes convey checked state but cannot submit commands or permissions.
No new network capability, server storage, or sensitive logging is added. Tests
intercept HTTP creation and platform channels, verify inert links and images,
and cover selection, literal HTML/code, incomplete Markdown, same-ID updates,
small-screen large-text layout, and mixed-height history anchoring.

## Flutter boundaries and performance

- Widgets own controllers, focus, gestures, layout, and navigation only.
- View models own validation, busy/error state, sorting, and pairing transitions.
- Repositories own authentication, inventory, pairing, trust, and relay lifecycle.
- Platform adapters own bounded HTTP requests and native secure storage.
- Domain values own normalized origins, immutable session state, codes and identities.

Use constructor injection, ChangeNotifier, and ListenableBuilder. Keep feature
boundaries and small reusable widgets. Start work once outside build, reject
concurrent submissions, discard stale completions, and dispose listeners/timers.
Crypto key generation and signing use compute isolates; ordinary input validation
does not. Connection rows are lazy, relay retries are bounded, and backgrounding
closes presence activity. Refresh rotation is single-flight. No telemetry records
credentials, keys, server error bodies, or conversation content.

[Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations)
and [performance guidance](https://docs.flutter.dev/perf/best-practices) inform these
choices. Measure profile builds on representative devices before claiming frame
or startup performance.

## Verification

Unit/widget tests cover hidden gestures, hostile URLs, storage failures, duplicate
requests, cross-server/account isolation, credential rotation and revocation,
cryptographic protocol fixtures, pairing expiry/mismatch, stale list responses,
responsive layout, keyboard behavior, and accessibility guidelines. Native Android
integration verifies real API and secure storage behavior. iOS Keychain,
process termination/restart on both platforms, and TalkBack/VoiceOver remain
manual release checks. Never treat fake repository tests as proof of native
storage behavior. See ADR 0002 for security assumptions and limitations.
