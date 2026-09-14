# ADR 0001: Login UI and pre-authentication server selection

Status: historical design decision. Authentication, workspace behavior, and
secure storage are superseded by [ADR 0002](0002-native-auth-and-pairing.md).

## Decision

Use feature-based Flutter widgets, view models, and a replaceable preferences
repository. SDK observables and constructor injection keep this single-screen
app small. Store a normalized server origin using `SharedPreferencesAsync`.
HTTPS is required except for an explicit debug-only HTTP allowance on exactly
`127.0.0.1`, `localhost`, and `[::1]`, requested for local testing. The app injects
this allowance through `kDebugMode`; the parser defaults to HTTPS-only and uses
the same policy for validation, saving, build defaults, and restored preferences.
Debug builds use `http://127.0.0.1:8080` as their initial origin. An optional
`REMOTE_SERVER_URL` build define overrides it; a saved selection takes precedence.
Release/profile builds have no default and require server selection or an explicit
HTTPS build define.
There is no hard-coded production host or automatic fallback after corrupt or
unreadable preferences.

Six background/branding taps open the editor. Configuration and its current
origin remain hidden until the sixth tap, per the requested product behavior.
There are no visible, long-press, sign-in, or semantic settings shortcuts. The form
is a clearly labeled preview and sends no HTTP traffic.
Valid preview submission clears form credentials and replaces the login route
with an empty white workspace and a Settings-first sidebar. This route grants no
authorization and exposes no protected resources. It must be gated by real
authentication before adding protected functionality.

## Threat analysis

| Threat | Current mitigation / residual limit |
| --- | --- |
| Cleartext credentials over an untrusted network | Release/profile builds accept only HTTPS. Debug builds permit HTTP only on the three explicitly allowed loopback hosts. LAN addresses, hostname suffix tricks, and embedded credentials remain rejected. No network client exists yet; future clients must retain platform certificate validation and reject cross-origin credential redirects. |
| Confusing URL disguises a destination | Reject embedded credentials, percent escapes, non-ASCII input, backslashes, whitespace, query/fragment, and non-root paths. Show the complete normalized origin inside the editor. IDNs must use their ASCII/Punycode form. |
| Secret input leaks through storage or diagnostics | Preferences contain only the origin. The preview neither stores nor logs credentials, raw errors, or form input. |
| Failed preference write appears successful | Commit the in-memory selection only after the repository accepts the write. Preserve the previous origin on failure and expose retry. Preferences are noncritical and may still be lost after process/device failure. |
| Stale state sends old credentials to a new server | Changing origin destroys the login form state. No authenticated account/session exists yet. Future storage and transport must be scoped to the origin and reset on a switch. |
| Malicious or compromised self-hosted server | The user explicitly selects the server and sees its origin in the editor. HTTPS does not establish server trust. E2EE connector verification is still required when implemented. |
| Accidental hidden gesture or concurrent actions | Require six taps, reset on pauses/lifecycle/modal changes, open one sheet, and disable overlapping writes and dismissal during saving. |
| Device compromise or modified preferences | Preferences are not a trusted identity store. Revalidate restored values; never use the selected origin as proof of account or connector identity. Native device compromise is outside this control's protection. |

The server-setting feature is local and pre-authentication. It changes no account
authorization, devices, pairing records, or server resources. Account isolation
will require origin-scoped identities and contract tests before authentication is
enabled. No cross-component wire contract changes in this iteration.

## Consequences

Deployed self-hosting requires trusted TLS and origin-root hosting. Local HTTP
is a debug-only exception, not a certificate bypass. A saved local HTTP address
is rejected when restored under release/profile policy. Android devices can use
ADB reverse port forwarding to reach the development computer's loopback server.
Native cleartext transport policy remains to be verified when networking exists.
There is no connectivity
test or guarantee of persistence after a device failure. Manual native restart
testing on both platforms remains a release check. The six-tap gesture does not
grant or protect any privilege.

The hidden gesture reduces discoverability and accessibility of server selection.
A real authentication flow must make the credential destination clear before
submission; this preview sends no credentials.
