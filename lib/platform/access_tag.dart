// Not a secret: this value is compiled straight into the app binary and is
// extractable from it, so it must never be treated as authentication or access
// control. It exists only to cut automated scanner/bot noise on the server's
// public HTTP endpoints before a request reaches real auth logic (see
// server/README.md, "Client Access Tag"). Real authorization still comes
// entirely from account, device, connector, and session credentials.
//
// Must match the server operator's CLIENT_ACCESS_TAG, and the TypeScript
// plugin's ACCESS_TAG_VALUE (packages/agents/opencode/src/access-tag.ts) —
// changing it is a breaking release.
const accessTagHeader = 'X-Orc-Access';
const accessTagValue = 'orc-client-v1';
