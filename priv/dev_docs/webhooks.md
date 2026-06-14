# Webhooks

Instead of polling, vutuv can POST signed event notifications to your
server as things happen: a new follower, a connection request, a reply,
a message.

Webhooks belong to a registered [OAuth application](/developers/authentication#oauth-2-for-third-party-apps).
Add one on your app's page under
[/developers/apps](/developers/apps): endpoint URL (https; `http://localhost`
for development), the events you care about, and you receive a signing
secret (`vutuv_whsec_…`, shown once).

## Privacy model: thin envelopes, scoped fan-out

Two rules shape everything:

1. **Your app only hears about members who authorized it** — with the
   scope matching the event. A `message.created` event for member M is
   only delivered if M granted your app `messages:read`. No grant, no
   delivery; revoked grant, no delivery; suspended app, no delivery.
2. **Payloads carry ids and usernames, never content.** A message event
   does not contain the message text; a reply event not the reply body.
   Fetch details through the API with your scoped token — content never
   sits unencrypted in webhook logs.

## Events

| Event | Needs the member's scope | `data` |
|-------|--------------------------|--------|
| `follower.created` | `social:read` | `follower` (username) |
| `connection.requested` | `social:read` | `from` |
| `connection.accepted` | `social:read` | `by` |
| `endorsement.created` | `social:read` | `endorser`, `tag` |
| `post.liked` | `posts:read` | `by`, `post_id` |
| `post.replied` | `posts:read` | `by`, `post_id` |
| `message.created` | `messages:read` | `from`, `conversation_id` |

Plus `ping`, the test event you can trigger from the app page.

## The delivery

```text
POST <your endpoint>
Content-Type: application/json
X-Vutuv-Event: follower.created
X-Vutuv-Delivery: 0190…           (unique per delivery — deduplicate on it)
X-Vutuv-Signature: sha256=8d7c…
```

```json
{
  "event": "follower.created",
  "occurred_at": "2026-06-11T14:00:00Z",
  "member": "wintermeyer",
  "data": {"follower": "greta-tester"}
}
```

`member` is whose authorization the delivery rides on — the member the
event happened *to*.

## Verify the signature — always

The signature is a hex HMAC-SHA256 of the **raw request body** with your
signing secret. Reject anything that does not verify; an unverified
webhook endpoint is an open door for fabricated events.

**Python:**

```python
import hashlib, hmac, os

def verify(raw_body: bytes, signature_header: str) -> bool:
    expected = "sha256=" + hmac.new(
        os.environ["VUTUV_WEBHOOK_SECRET"].encode(), raw_body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature_header)
```

**Node:**

```javascript
const crypto = require("node:crypto");

function verify(rawBody, signatureHeader) {
  const expected = "sha256=" +
    crypto.createHmac("sha256", process.env.VUTUV_WEBHOOK_SECRET)
      .update(rawBody).digest("hex");
  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(signatureHeader));
}
```

## Respond fast, retry contract

Answer with any `2xx` within 10 seconds — acknowledge first, process
later. Anything else (including timeouts) is retried with exponential
backoff (2, 4, 8, … minutes, up to 8 attempts per event). Deliveries can
arrive out of order and, in rare cases, more than once — deduplicate on
`X-Vutuv-Delivery`.

An endpoint that does nothing but fail is **automatically disabled**
after sustained failures; the app page shows the reason and a re-enable
button. Events that occurred while a subscription was disabled are not
replayed — webhooks are a freshness channel, the API is the source of
truth.

## Local development

Point the webhook at an `http://localhost` URL (allowed only for
development) or use a tunnel. The **Send ping** button on the app page
delivers a `ping` event so you can verify your signature code without
waiting for a real event.
