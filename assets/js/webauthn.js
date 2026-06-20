// Passkey (WebAuthn / FIDO2) login + enrolment — issue #795.
//
// Plain JS, not a LiveView hook: /login and /settings are classic controller
// pages. This drives the navigator.credentials.create/get ceremony and POSTs the
// result as JSON to the Phoenix endpoints, which verify it server-side with the
// wax_ library. The buttons start `hidden` in the markup and are revealed only
// when the browser actually supports WebAuthn, so an unsupported browser falls
// back cleanly to the email-PIN flow.

import { onReady, once, postJSON } from "./util"

// base64url <-> ArrayBuffer. The WebAuthn API speaks ArrayBuffers; we send and
// receive base64url strings (no padding) over JSON.
function b64urlToBuf(value) {
  const b64 = value.replace(/-/g, "+").replace(/_/g, "/")
  const pad = b64.length % 4 === 0 ? "" : "=".repeat(4 - (b64.length % 4))
  const bin = atob(b64 + pad)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  return bytes.buffer
}

function bufToB64url(buf) {
  const bytes = new Uint8Array(buf)
  let bin = ""
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i])
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

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

// Login (use a credential), from the /login page. No allow-list is sent, so the
// browser surfaces any discoverable passkey for this site — no email typed.
async function loginWithPasskey(button) {
  const scope = button.closest("#passkey-signin") || document
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

    if (result.ok) window.location = result.redirect
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
  // the "not supported" note (settings) and leave the email-PIN form alone.
  document
    .querySelectorAll("#passkey-enroll, #passkey-signin")
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
}

onReady(setupPasskeys)
