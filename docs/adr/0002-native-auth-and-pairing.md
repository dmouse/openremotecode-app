# ADR 0002: Native authentication, secure persistence, and code pairing

Status: accepted; supersedes the preview behavior of ADR 0001.

## Decision

Use the existing v1 HTTP API and relay protocol without changing server contracts.
AuthRepository owns login, refresh rotation, restoration, logout and account
validation. MainApp gates the workspace on validated authentication. UI never
reads credentials from storage or calls HTTP directly.

Persist only refresh credentials with their origin, account ID and expiry in
flutter_secure_storage. Access tokens remain in memory and passwords remain only
in the login form/request lifetime. The native adapter uses Android Keystore-backed
encrypted storage and iOS unlocked-this-device Keychain. Android backup/transfer
rules exclude app data; iOS entitlements enable Keychain access. Storage errors
never fall back to preferences or silently regenerate keys. The origin alone
uses SharedPreferencesAsync. Version 10.3.1 of secure storage supports this
project's Android SDK 36; its major version is constrained and lockfile retained.

Restore rotates the server-issued refresh token before granting access. Concurrent
requests share one refresh. Persist rotation before exposing the new session.
Check the account ID remains the one stored with the credential. Logout waits for
rotation, deletes the local credential, closes the workspace/relay, and requests
server revocation. Offline logout reports that revocation could not be confirmed.
Device keys and public trust records survive logout for the same account on the
same origin; logout does not revoke devices.

Pairing accepts the existing eight-character code. Generate P256 keys with the
PointyCastle implementation in a compute isolate, sign the v1 identity challenge,
derive the transcript safety code locally, and require explicit matching-code
confirmation. Store private keys, device cookies and pinned connector identities
in one secure record per origin/account. A changed connector key fails closed.
Presence uses a fresh single-use ticket, a same-origin WebSocket, identity-bound
hello/ready messages, heartbeat, bounded reconnect backoff and lifecycle shutdown.
No chat content is read, retained, or relayed by this mobile increment.

## Threat analysis

| Threat | Mitigation and remaining limit |
| --- | --- |
| Password/token disclosure in local files or backups | Native encrypted storage for refresh/device credentials and keys; passwords/access tokens are not persisted; Android backups disabled; iOS device-only Keychain. Process/device compromise remains outside this protection. |
| Cross-server or cross-account reuse | Validate origins and scope session records by origin, identities by origin plus account; compare refresh account IDs; destroy login form on server change; discard stale session work. |
| Network interception or credential redirect | Platform TLS validation remains enabled; release/profile require HTTPS; HTTP and WebSocket upgrades reject redirects. Debug loopback HTTP is an explicit local development exception. |
| Expired/revoked session grants access | Cold restore contacts the server, refreshes before expiry on operations, validates account on resume, and closes the authenticated gate on account API 401. Relay-ticket 401 can indicate a revoked device and does not by itself erase account credentials. Server remains authoritative for every protected operation. |
| Token-rotation race or storage failure | One refresh in flight; durable save before exposing credentials; logout waits for rotation. Failed token persistence attempts revocation and fails closed. A process death between server rotation and native write may require sign-in again. |
| Malicious server substitutes connector key | Locally computed safety code binds service, pairing ID, connector and device identities; user must compare out of band. Never silently overwrite a pin. Server can still deny service or falsify presence; presence is not cryptographic proof of chat contents. |
| Pairing code brute force/replay or accidental trust | Existing server limits/expiry/proof-of-possession; client validates code format, separates claim from confirmation, checks expiry and device identity, and disables duplicate actions. Confirmation retries are explicit; server idempotency handles lost responses. |
| Malformed/oversized network input or resource exhaustion | Bounded HTTP body and timeouts, validated identities, scoped relay path, heartbeat, handshake deadline and bounded reconnect. Server applies relay limits. Crypto operations use library implementations off the UI isolate. |
| Sensitive diagnostics | Static client errors only; no raw server errors, credentials, keys or content logged. No new analytics or observability payloads. Server audit behavior remains governed by its existing API implementation. |

## Validation and limitations

Unit/widget coverage includes secure-write/delete failure, wrong passwords,
cross-origin isolation, account mismatch, offline restore, revoked sessions,
single-flight rotation, logout races, code expiry/reuse, trust mismatch, stale
inventory and safe network errors. Public-only fixtures generated by the existing
TypeScript protocol verify Dart safety codes and WebCrypto signature compatibility.
Generated private keys are never checked into fixtures.

The Android integration test runs real registration/login/refresh/logout, native
secure storage, Go-validated P256 proofs, two-phase pairing, identity restoration,
and relay presence against a disposable local server. It uses a separate Android
application ID and Keystore/data sandbox, plus an isolated storage namespace. The
launcher disables Flutter's default uninstall cleanup. Storage prefixes alone
do not protect interactive sessions from app uninstall; the original test setup
incorrectly assumed they did, resulting in lost local sessions and pairing keys. iOS build/Keychain validation
and OS process restart testing remain release checks on their actual platforms.

E2EE chat, HPKE envelope exchange, session browsing, and device-management UI are
outside this increment. A compromised native device can access its own secrets;
E2EE also cannot protect a compromised local OpenCode machine or authorized model
provider. Browser bundle compromise remains a separate web-client trust limit.
