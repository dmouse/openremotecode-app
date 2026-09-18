# Mobile Architecture

## Scope

This directory contains the Flutter application written in Dart for iOS and Android. It provides a trusted native client for managing connectors and remotely interacting with live OpenCode sessions.

The mobile application is the supported user-facing client. It uses the public HTTP API and encrypted relay protocol while respecting native application lifecycle, secure storage, networking, and distribution constraints.

The root `AGENTS.md` defines product-wide constraints and takes precedence over this document.

## Responsibilities

- Register or authenticate a user through the server API, by password or through a federated provider.
- Maintain native device identity and credentials in platform secure storage.
- Pair with an OpenCode connector using code entry or QR-assisted verification.
- Verify and pin connector identity through a safety phrase or equivalent secure comparison.
- List, select, rename, and revoke authorized connectors and devices.
- Establish the authenticated WebSocket and perform end-to-end encryption locally.
- List sessions and render message snapshots and streaming updates.
- Create sessions, submit prompts, abort responses, and answer individual permission requests.
- Handle foreground, background, resume, offline, reconnect, and credential-expiry transitions accurately.

## Application Boundaries

Organize the application around these areas:

- Authentication: account access, refresh rotation, logout, and account status.
- Secure device identity: key generation, secure persistence, proof of possession, and local revocation cleanup.
- Pairing and trust: scanner or code entry, safety phrase comparison, trusted connector records, and key-change warnings.
- Relay transport: admission tickets, WebSocket lifecycle, encrypted protocol, heartbeat, retry, and network awareness.
- Connector state: inventory, presence, endpoint selection, capabilities, and compatibility.
- Session state: snapshots, session selection, creation, status, and todos.
- Conversation state: messages, streaming parts, drafts, pending commands, abort, and errors.
- Permission decisions: high-visibility, time-sensitive once-or-reject responses.
- Platform integration: app lifecycle, deep links, secure storage, network status, accessibility, and eventual push notifications.

UI features depend on application services and stable product types. Native storage, cryptography, HTTP, WebSocket, and lifecycle APIs remain behind platform adapters.

Flutter UI and application code live in `lib/`. Keep Android and iOS platform integration in `android/` and `ios/`. Manage Dart dependencies in `pubspec.yaml` and retain `pubspec.lock` for reproducible application dependency resolution.

## Native Security Model

Store refresh credentials and private device keys in iOS Keychain or Android Keystore-backed secure storage. Short-lived access credentials remain in memory where practical. Do not store secrets or decrypted conversations in ordinary asynchronous storage, application logs, crash reports, analytics, clipboard history, or unprotected backups.

Use application-bound deep links for pairing and authentication callbacks. Validate every deep-link parameter and require an authenticated, visible confirmation before changing trust state.

The app pins trusted connector public identities. A connector key change is a security event requiring a new pairing flow. Server account ownership does not authorize silent key replacement.

Screens containing sensitive conversation content should use platform protections against unintended previews or screenshots where product requirements justify them. Notifications must not include plaintext prompt or response content by default.

## Lifecycle and Connectivity

Mobile operating systems suspend background network activity. The app must not promise a continuously active WebSocket while backgrounded.

- Establish or resume the relay when the application becomes active.
- Close or suspend expensive work cleanly when backgrounded.
- Treat network changes as normal and reconnect with bounded exponential backoff.
- Refresh credentials before relay admission when needed.
- Request authoritative connector and session snapshots after resume or reconnect.
- Keep unsent drafts locally in protected application state.
- Represent uncertain command outcomes explicitly and avoid automatic duplicate prompt submission.

Push notifications are a later enhancement for presence or waiting permission signals. Because the server cannot read E2EE content and does not store messages, notifications should carry only opaque identifiers and generic wording. Opening a notification reconnects and retrieves current state from the connector.

## Pairing Experience

The first iteration uses one short code input with normal paste support, per the product decision. Code entry initiates server-mediated authorization and does not bypass authenticated account checks or safety code verification. Camera/QR pairing is deferred.

Pairing clearly separates:

- Account authentication with the server.
- Authorization to associate a connector with the account.
- End-to-end verification of connector and mobile public identities.

Expired, reused, mismatched, or revoked pairing attempts fail closed and provide a recoverable path to start again.

## Session and Conversation Experience

The local OpenCode connector is authoritative and must be online for live access. The app should communicate this plainly.

Conversation rendering supports incremental message parts, tool-state summaries, errors, todos, and session status while treating all received content as untrusted. The initial release does not browse arbitrary local files or expose raw shell execution.

Permission requests require explicit user action and clear risk context. Only one-time approval and rejection are initially available. If the connector goes offline or the request expires, the UI must disable stale actions.

The app does not retain a durable offline copy of conversations. Temporary in-memory state may remain while the app process is active, but a cold start obtains fresh state from the connector.

## Shared Contracts

Use the versioned encrypted protocol, validation rules, and OpenAPI contract shared with the server and plugin. Share language-neutral schemas, contract fixtures, and cryptographic test vectors. Generate or implement Dart API clients and product models from those contracts; the Flutter app must not depend on importing the TypeScript runtime packages used by the plugin.

Because the Dart implementation is written against those contracts rather than compiled from them, anything reimplemented here must be pinned by a shared fixture that both languages assert against. Connection epoch derivation and the relay envelope's additional authenticated data are the current examples: if the two implementations drift, the peers stop agreeing on the connection rather than failing loudly at build time. Keep the sequence window and epoch lifetime aligned with [server ADR 0011](../server/docs/adr/0011-relay-connection-epochs.md).

Do not share browser cookies, IndexedDB assumptions, DOM rendering, Node or Bun APIs, or plugin lifecycle behavior with mobile. Shared packages must declare their supported runtimes and avoid hidden platform dependencies.

## First-Iteration Flutter Conventions

Keep UI separate from business logic. Follow the implemented boundaries in
`lib/features/login` and `lib/features/server_settings` and the design contract in
[docs/design.md](docs/design.md).

- Organize code by feature. Widgets live in each feature's `ui/` directory;
  validation and state transitions live in view models or immutable domain types;
  platform persistence and network calls live in data adapters.
- Widgets own only presentation state: controllers, focus, visibility, gestures,
  layout, and navigation. Do not read preferences, make HTTP calls, or implement
  endpoint/authentication rules in a widget or its `build` method.
- Inject dependencies through constructors. Use SDK `ChangeNotifier` and
  `ListenableBuilder` for observable state in this iteration. Add a state or
  navigation package only when a concrete requirement justifies it.
- Prefer small named widgets and `const` constructors. Keep shared UI in
  `lib/ui/core/` and avoid a general-purpose helpers collection.
- Use the app theme for colors and controls. The primary brand color is exactly
  `#DBF4AD`; pair it with dark foregrounds. Never use pale green text on white.
- Keep async work out of `build`. Guard duplicate saves, handle failures, dispose
  owned controllers/listeners, and check lifecycle after asynchronous work.
- Server selection is available only before authentication. Scope credentials and device identities to the normalized server origin, tear
  down transports before switching, and never send old credentials to a new host.
- Store only the server origin in ordinary preferences. Credentials and private
  keys require native secure storage. Never log form input or raw exceptions.
- Test meaningful behavior: hostile input, persistence failures, races, credential
  clearing, keyboard/large-text layout, and accessible controls. Run `flutter
  analyze` and `flutter test`, and verify native integration when a device exists.

## Performance and Accessibility Requirements

- Bound retained streaming parts and message rendering work.
- Use list virtualization for long sessions.
- Avoid cryptographic and message-normalization work on animation-sensitive paths.
- Support dynamic text sizes, screen readers, reduced motion, keyboard navigation where applicable, and adequate touch targets.
- Design for intermittent and high-latency networks rather than assuming desktop connectivity.
- Make connection and synchronization states understandable without relying on color alone.

## Verification Expectations

Future mobile work must test secure credential behavior, biometric or device-lock interactions if introduced, pairing, key mismatch, deep links, app resume, network transitions, token expiry, relay reconnect, snapshot reconciliation, streaming messages, abort, permission expiry, logout, and device revocation.

Use shared protocol fixtures to verify compatibility with plugin and web implementations. Keep Dart unit and Flutter widget tests in `test/`, and native integration tests in `integration_test/`. Run `flutter analyze` and the tests relevant to each change. Also run `dart run import_lint`, which enforces the layering rules above (UI must not import `platform/` or raw storage/network packages; `platform/` must not import feature code besides `domain/` types) with a failing exit code — the IDE-integrated analyzer plugin surfaces the same rules but only after a Dart Analysis Server restart, so the CLI is the reliable check for a change. Native end-to-end tests should cover at least one iOS and one Android path. Security review is required before enabling push notifications, local conversation persistence, biometric gates, or screenshot restrictions.

Run native Android integration tests only through `./tool/test_local_android.sh`.
It builds the separate `com.openremotecode.app.integration` application and passes
`--no-uninstall`. Never run plain `flutter test integration_test/...` against the
interactive app: this Flutter SDK uninstalls the app by default after tests,
deleting its Keystore keys, login, and pairing data. A storage-key prefix alone
does not isolate tests from uninstall. Do not uninstall or clear the normal app
to test persistence. iOS native tests require an isolated test bundle/device too.

## Out of Scope

- Maintaining a guaranteed background WebSocket.
- Plaintext push-notification content.
- Durable offline conversation history.
- Direct network access to the local OpenCode server.
- Arbitrary shell or filesystem control.
- Silent trust of connector key changes.
