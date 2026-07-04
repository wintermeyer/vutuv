# Authentication & sessions

vutuv is **passwordless**. The baseline login is a two-step email-PIN flow
(`/login` mails a 6-digit PIN, the second step verifies it; no password is ever
stored).

Returning members can also enrol one or more **passkeys** (WebAuthn / FIDO2 —
Touch ID, Windows Hello, a security key) from the Account hub and sign in with
one as an **alternative first factor**, skipping the email round-trip entirely
(`Vutuv.Credentials`, the `wax_` library, table `user_credentials`; the browser
ceremony is `assets/js/webauthn.js`, revealed only on supporting browsers).

A passkey is enrolled only while logged in, so the email PIN stays the
always-available fallback and the **only** way to bootstrap an account — a
passkey is a faster *return* login, never the root of trust.

If a member types their address and clicks "Sign in with a passkey" but that
account has no passkey, the challenge endpoint quietly falls back to the
email-PIN flow — it mails a PIN and drops them on the PIN screen with a friendly
note — instead of stranding them at an empty native prompt (issue #834).

Passkey verification funnels into the same `Accounts.login/2` exit as the PIN,
so it gets the identical server-side per-device session row, new-device security
email and live-socket wiring.

Each login is a tracked **server-side session** (`Vutuv.Sessions`, table
`user_sessions`, SHA-256-hashed token): members see where they are signed in,
revoke a single device or all others, and add / remove passkeys at
`/:slug/settings`; a noteworthy login (new device, suspicious location) mails a
security alert
