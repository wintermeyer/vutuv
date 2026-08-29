// Passkey (WebAuthn / FIDO2) login + enrolment — issue #795.
//
// Plain JS, not a LiveView hook: /login and /settings are classic controller
// pages. This drives the navigator.credentials.create/get ceremony and POSTs the
// result as JSON to the Phoenix endpoints, which verify it server-side with the
// wax_ library. The buttons start `hidden` in the markup and are revealed only
// when the browser actually supports WebAuthn, so an unsupported browser falls
// back cleanly to the email-PIN flow.

// base64url <-> ArrayBuffer comes from util.js: the WebAuthn API speaks
// ArrayBuffers while the wire carries base64url strings, and so does the Web
// Push subscription's VAPID key.
import { b64urlToBuf, bufToB64url, onReady, once, postJSON } from "./util"

function showError(scope, message) {
  const el = scope.querySelector("[data-webauthn-error]")
  if (el && message) {
    el.textContent = message
    el.hidden = false
  }
}

function hideError(scope) {
  const el = scope.querySelector("[data-webauthn-error]")
  if (el) el.hidden = true
}

// A user who dismisses or lets the native prompt time out (NotAllowedError) gets
// no error — that was a deliberate cancel. Anything else shows the button's
// localized generic message.
function ceremonyError(button, err) {
  if (err && err.name === "NotAllowedError") return null
  return button.dataset.errorGeneric || "Something went wrong. Please try again."
}

// Enrolment (create a credential), from the settings page.
async function registerPasskey(button) {
  const scope = button.closest("#passkey-enroll") || document
  button.disabled = true
  hideError(scope)

  try {
    const options = await postJSON(button.dataset.challengeUrl, {})
    if (options.error) return showError(scope, options.error)

    options.challenge = b64urlToBuf(options.challenge)
    options.user.id = b64urlToBuf(options.user.id)
    options.excludeCredentials = (options.excludeCredentials || []).map((c) => ({
      ...c,
      id: b64urlToBuf(c.id),
    }))

    const cred = await navigator.credentials.create({ publicKey: options })
    const nicknameInput = document.getElementById(button.dataset.nicknameInput)
    const result = await postJSON(button.dataset.createUrl, {
      attestationObject: bufToB64url(cred.response.attestationObject),
      clientDataJSON: bufToB64url(cred.response.clientDataJSON),
      nickname: nicknameInput ? nicknameInput.value : "",
    })

    if (result.ok) window.location = result.redirect
    else showError(scope, result.error || button.dataset.errorGeneric)
  } catch (err) {
    showError(scope, ceremonyError(button, err))
  } finally {
    button.disabled = false
  }
}

// Login (use a credential), from the /login page. We pass along whatever the
// visitor typed in the email field: with no email (or an account that has a
// passkey) the server mints a discoverable challenge and the browser surfaces
// any passkey for this site; for an email with no passkey the server instead
// mails a PIN and answers with a `redirect`, so we send the member to the PIN
// screen rather than strand them at an empty native prompt (issue #834).
async function loginWithPasskey(button) {
  const scope = button.closest("#passkey-signin") || document
  const emailField = document.querySelector('#login-form [name="session[email]"]')
  const email = emailField ? emailField.value.trim() : ""
  button.disabled = true
  hideError(scope)

  try {
    const options = await postJSON(button.dataset.challengeUrl, { email })
    if (options.error) return showError(scope, options.error)

    // No passkey for this address: the server already mailed a PIN, so follow
    // it to the PIN-entry screen (with the friendly flash it stashed).
    if (options.redirect) {
      window.location = options.redirect
      return
    }

    options.challenge = b64urlToBuf(options.challenge)

    const assertion = await navigator.credentials.get({ publicKey: options })
    const result = await postJSON(button.dataset.verifyUrl, {
      rawId: bufToB64url(assertion.rawId),
      authenticatorData: bufToB64url(assertion.response.authenticatorData),
      signature: bufToB64url(assertion.response.signature),
      clientDataJSON: bufToB64url(assertion.response.clientDataJSON),
    })

    if (result.ok) window.location = result.redirect
    else showError(scope, result.error || button.dataset.errorGeneric)
  } catch (err) {
    showError(scope, ceremonyError(button, err))
  } finally {
    button.disabled = false
  }
}

// Re-confirm a sensitive change you are already signed in for — today the
// username rename (issue #1084). Unlike the login ceremony this does NOT act on
// success: the server only stamps the session, and we then submit the page's
// ordinary confirmation form, so the change keeps one CSRF-protected path
// through the controller instead of a second, JSON-only way in.
async function confirmWithPasskey(button) {
  const scope = button.closest("#passkey-confirm") || document
  button.disabled = true
  hideError(scope)

  try {
    const options = await postJSON(button.dataset.challengeUrl, {})
    if (options.error) return showError(scope, options.error)

    options.challenge = b64urlToBuf(options.challenge)

    const assertion = await navigator.credentials.get({ publicKey: options })
    const result = await postJSON(button.dataset.verifyUrl, {
      rawId: bufToB64url(assertion.rawId),
      authenticatorData: bufToB64url(assertion.response.authenticatorData),
      signature: bufToB64url(assertion.response.signature),
      clientDataJSON: bufToB64url(assertion.response.clientDataJSON),
    })

    if (result.ok) document.getElementById(button.dataset.submitForm).submit()
    else showError(scope, result.error || button.dataset.errorGeneric)
  } catch (err) {
    showError(scope, ceremonyError(button, err))
  } finally {
    button.disabled = false
  }
}

function setupPasskeys() {
  const supported = !!window.PublicKeyCredential

  // Reveal the ceremony controls only on a supporting browser; otherwise show
  // the "not supported" note (settings, username confirmation) and leave the
  // email-PIN form alone.
  document
    .querySelectorAll("#passkey-enroll, #passkey-signin, #passkey-confirm")
    .forEach((el) => (el.hidden = !supported))
  document
    .querySelectorAll("[data-webauthn-unsupported]")
    .forEach((el) => (el.hidden = supported))

  if (!supported) return

  document
    .querySelectorAll("[data-webauthn-register]")
    .forEach((btn) => once(btn, "wa") && btn.addEventListener("click", () => registerPasskey(btn)))
  document
    .querySelectorAll("[data-webauthn-login]")
    .forEach((btn) => once(btn, "wa") && btn.addEventListener("click", () => loginWithPasskey(btn)))
  document
    .querySelectorAll("[data-webauthn-confirm]")
    .forEach(
      (btn) => once(btn, "wa") && btn.addEventListener("click", () => confirmWithPasskey(btn)),
    )
}

onReady(setupPasskeys)
