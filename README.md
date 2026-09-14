# Open Remote Code Mobile

The app's display name is **Open Remote Code**, its Dart package is
`openremotecode`, and its Android/iOS application identifier is
`com.openremotecode.app`. This is a separate installation from the previous
`com.example.opremote` development app and requires fresh login and pairing.
Existing installations can remain installed.

The planned hosted API/relay origin is `https://api.openremotecode.com`.
It is not a development default or a claim that the service is deployed.
See [Naming and Planned Domains](../README.md#naming-and-planned-domains)
for the landing page and API/relay hosts.

Native Flutter client with real server authentication, secure session restoration,
a connections home, and short-code pairing. The main color is `#DBF4AD`.
UI widgets depend on view models and repositories; networking, storage, and
cryptography stay outside widgets.

## Local Android development

Start the local Open Remote Code service on port 8080, then run from `mobile/`:

```sh
./tool/run_local_android.sh emulator-5554
```

This checks server readiness, runs `adb reverse tcp:8080 tcp:8080` for the selected
device, and launches Flutter. The debug default remains `http://127.0.0.1:8080`.
Loopback means the Android device itself; without ADB forwarding, login reports
that it cannot reach the server. Reapply forwarding after an emulator or ADB
restart. A USB-connected Android device can use its device ID instead.

For an already running app:

```sh
adb -s emulator-5554 reverse tcp:8080 tcp:8080
```

Then retry sign-in. Local HTTP is allowed only in debug builds and only for
`127.0.0.1`, `localhost`, or `[::1]`. Release/profile builds require HTTPS.
iOS simulator loopback reaches the Mac hosting the simulator; physical iPhones
need a reachable HTTPS development service. iOS builds and Keychain behavior
must be verified on macOS/Xcode before shipping.

## Server selection

Tap login background or branding **six times**, with consecutive taps no more
than two seconds apart. The sixth tap opens the server editor. Configuration
has no visible shortcut. The read-only signing destination is shown on login
so the user knows where their credentials go.

Save a normalized HTTPS origin without paths, embedded credentials, query, or
fragment. Only this nonsecret preference uses ordinary preferences. A saved
origin overrides `REMOTE_SERVER_URL`, which overrides the debug default. Changing
the origin clears the login form. There is no production endpoint bundled.

```sh
flutter run --dart-define=REMOTE_SERVER_URL=https://remote.example.com
```

## Google sign-in

Off unless the build is configured, so the action is absent rather than present
and unusable. Pass the OAuth **web** client ID as `GOOGLE_SERVER_CLIENT_ID`; both
platforms request their ID token for it, and it must match one entry in the
server's `GOOGLE_OAUTH_AUDIENCES`. `GOOGLE_IOS_CLIENT_ID` is only needed when the
iOS client ID is not already in `Info.plist`. Client IDs are public identifiers,
not secrets.

```sh
flutter run \
  --dart-define=REMOTE_SERVER_URL=https://remote.example.com \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=111111111111-web.apps.googleusercontent.com \
  --dart-define=GOOGLE_IOS_CLIENT_ID=222222222222-ios.apps.googleusercontent.com
```

**Android** needs no file changes; register an Android OAuth client for package
`com.openremotecode.app` with the SHA-1 of each signing certificate you use,
debug included, or the SDK returns no token. **iOS** needs the reversed iOS
client ID as a URL scheme so Google can return to the app; `ios/Runner/Info.plist`
carries the block as a comment to fill in, since a wrong scheme breaks the
callback silently and the value is per-deployment. See the Google Sign-In section
of `server/README.md` for registering the clients.

One button, **Continue with Google**, appears on both the sign-in and
create-account screens, because it is one operation: the server creates the
account when the assertion reaches no existing one. It never leads to the
verification screen — Google has already proved the address. Cancelling the
account chooser is not an error and shows no banner.

If the server answers **An account already uses this email address**, that account
predates email verification and was never proved to belong to its registrant.
Sign in with the password instead; linking automatically would hand the account
to whoever controls the address today.

## Authentication and connections

Use an existing account on the selected service. Login calls the public API;
incorrect credentials never open the workspace. The app saves the rotating
refresh credential in Android Keystore-backed encrypted storage or device-only
iOS Keychain. Passwords are never persisted; access tokens remain in memory.
A fresh launch rotates the saved credential with the same server before opening
the home screen. Offline restoration keeps the credential for explicit retry
and stays on login. Settings provides account information and Sign out.

Each connection has a three-dot menu with **Rename** and **Delete**. Rename saves
the display name on the server, so it survives refresh and is visible to your
other devices. **Delete and revoke** confirms account-wide
revocation on the server before removing the saved connection. It disconnects all
devices using that connector; local OpenCode chats remain. Failed requests keep
the connection for retry. The account must own the connector, but this device
does not need its pairing keys to revoke it.

The white Connections home lists authorized connectors, puts online peers first,
and retains offline peers. Unknown presence and identities requiring verification
are labeled explicitly. Add connection accepts one short typed or pasted code.
Compare the safety code with OpenCode, then explicitly confirm matching codes.
An existing account connection may say Verification required when this device has
never paired with it. The current plugin has no add-another-device action while
already paired; that flow remains to be implemented. Do not treat account login
as connector verification or revoke an existing connector merely to dismiss the
label. A changed saved identity is displayed as a separate warning.
The connector must also review the claim before confirmation succeeds.
Private device keys, device credentials, and pinned public identities are scoped
to both the server and account and stored securely. Existing keys cannot be
silently replaced. Presence uses single-use relay tickets and suspends in the
background. Chat/session browsing and encrypted message exchange are the next
feature; connection cards currently show inventory and presence.

## Verification

Chat title taps open the existing Chat details route, including a read-only
**MCP servers** section. It uses a separately encrypted project subscription,
renews only while details are visible and foregrounded, and labels stale/offline
status without live green dots. No MCP tool, authentication, or configuration
actions are exposed. See [MCP status](docs/mcp-status.md) for the wire contract,
lifecycle, threat analysis, and tests.

Use Flutter with Dart 3.13.2 or a compatible version. Android requires the SDK,
JDK, accepted licenses, and an emulator/device; iOS requires macOS and Xcode.
The lockfile selects secure storage 10.3.1, compatible with Android compile SDK
36; version 11 requires a newer SDK target.

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
./tool/test_local_android.sh emulator-5554
```

The integration test requires a disposable local server with registration enabled.
It creates a random test account and builds a separate Android application
(`com.openremotecode.app.integration`) with its own Keystore/data sandbox. It
verifies login/restore/rotation/logout, pairs a simulated connector, verifies live
presence and persisted identity, and revokes its connector and sessions. Test
accounts remain in the development database; no credentials are printed or saved
in source. The launcher also sets `--no-uninstall`: this Flutter SDK otherwise
uninstalls the test application after execution. Do not run plain native
`flutter test integration_test/...` on the normal app ID; uninstall deletes its
login and private pairing keys even when test storage keys have a prefix.
Refreshing, hot restart, and closing/reopening the normal app should preserve
pairing. Uninstall/clear-data creates a new device and requires pairing again.

Read [architecture requirements](AGENTS.md), [design conventions](docs/design.md),
and [authentication and pairing threat analysis](docs/adr/0002-native-auth-and-pairing.md).
Rendered Flutter design previews (sample data): [login](docs/previews/login.png),
[connections](docs/previews/connections.png), [code entry](docs/previews/pairing-code.png),
and [safety verification](docs/previews/pairing-safety.png).
The root pnpm scripts do not run Flutter checks.
