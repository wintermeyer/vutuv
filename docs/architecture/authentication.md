# Authentication & sessions

vutuv is **passwordless**. The baseline login is a two-step email-PIN flow
(`/login` mails a 6-digit PIN, the second step verifies it; no password is ever
stored).

The PIN lives in `login_pins` (one row per `(user, type)`, shared by the
`login`, `email` change and `delete` flows). It stays valid for 30 minutes from
when it is minted (`minted_at`) and it is **one-time**: a successful check stamps
`consumed_at`, so it can never be replayed. A classic (non-LiveView) PIN form can
be posted twice — a double-tap, a back-navigation, a retried request — so
`Vutuv.Accounts.check_pin/3` tells an **already-used** PIN (`consumed_at` set →
`{:already_used, _}`, a calm "already used" notice because the first submit
already logged the member in) apart from a genuinely **expired** one
(`minted_at` past the window, or cleared → `{:expired, _}`). Collapsing the two
once told members who had just logged in that their fresh PIN had expired
(issue #839).

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

Power users can also enrol two kinds of **alternative login codes** (issue
#912, `Vutuv.LoginCodes`) that work **in the normal PIN field** at step 2 —
same screen, same form, so a member who sets nothing up never sees any
difference:

* an **authenticator app** (RFC 6238 TOTP, `nimble_totp`, table `user_totps`,
  one row per member): set up under Sign-in & security by scanning a QR code
  (rendered server-side with `eqrcode`, air-gap safe) and confirming with a
  first code — the row is unusable until that confirmation, so a mis-scan
  cannot enrol a broken secret. Verification accepts the current and previous
  30-second window (clock drift) and passes `last_used_at` to NimbleTOTP as
  `since:`, so a code can never be replayed.
* a printable **one-time code list** ("Kennwortliste", table
  `login_list_codes`): ten `XXXX-XXXX` codes from an unambiguous alphabet
  (no `0/O/1/I/L`), each logging the member in exactly once (consumed
  atomically). Viewable, regenerable and deletable under
  `/settings/login_codes`.

The wiring is one seam: `Accounts.check_login_code/2` first runs the normal
`check_pin/3` and only on failure tries `LoginCodes.redeem_login_code/2` for
the account. Every alternate failure returns exactly the PIN check's own
result, so messages, attempt counters, the lockout and the enumeration safety
of the PIN flow are byte-for-byte unchanged; a success also consumes the
outstanding emailed PIN. Like passkeys these are alternative first factors,
enrolled only while logged in — the email PIN remains the always-available
fallback and the only root of trust, so there is nothing a member can lock
themselves out with. The PIN screen shows a one-line reminder that app/list
codes work, but only to members who actually enrolled
(`LoginCodes.any_for_email?/1` — the same deliberate reveals-enrolment cost
as the passkey fallback).

Each login is a tracked **server-side session** (`Vutuv.Sessions`, table
`user_sessions`, SHA-256-hashed token): members see where they are signed in,
revoke a single device or all others, and add / remove passkeys at
`/:slug/settings`; a noteworthy login (new device, suspicious location) mails a
security alert

**Where a login lands.** Normally `VutuvWeb.Home.path/1`: the feed, or the
member's own profile while they follow nobody. The one exception is the PIN
that confirms a **brand-new registration** — that member is sent to the
one-time welcome page (`/system/welcome`) first, where they are asked once for
their location and job search. `SessionController.post_login_path/2` gates it on
both the PIN form's `"registration"` context and a `nil`
`users.welcome_completed_at`, so an ordinary login never lands there and a
member who abandons the page is not asked again. See
[Profiles](profiles.md#the-one-time-welcome-page-systemwelcome).

A newcomer gets **no welcome toast** on either page: the welcome screen greets
them in its own hero, and the profile it hands them to already shows the
completion checklist, so a toast on top would only repeat it. The returning
member's "Welcome back, …" (plus the unread-conversations nudge) is unchanged.

