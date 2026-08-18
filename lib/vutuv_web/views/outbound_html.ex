defmodule VutuvWeb.OutboundHTML do
  @moduledoc """
  The hand-off page (issue #1569): the one response shape a form submission
  uses when its real destination is another site.

  `form-action 'self'` is checked against **every hop of a submission,
  redirects included**, so answering such a POST with `redirect(conn,
  external: …)` is refused by Chrome and WebKit. The refusal is invisible from
  here — the POST arrives, we answer 302, the browser drops it — and the
  console names *our own* URL as the blocked one, so it reads like a bug in a
  page that has nothing to do with the destination. See
  `VutuvWeb.Plug.ContentSecurityPolicy` for the directive itself.

  The consent screen widens the directive instead, because its destination is
  registered and known while the page renders. Neither caller here can do
  that: `VutuvWeb.RemoteFollowController` resolves its destination from an
  address the visitor types, and the job page's apply button lives in a
  LiveView the visitor may have reached by live navigation, so the document
  holding the form is not the one that would have carried the header.

  So the submission **ends here**, at a 200. `form-action` is satisfied by the
  same-origin POST, and the hop that actually leaves vutuv is an ordinary
  navigation, which the directive does not govern — both halves measured in
  Chrome against a bare `form-action 'self'`.

  An `http(s)` destination is taken automatically: `hand_off/3` sets
  `:meta_refresh` and the layout's head emits `<meta http-equiv="refresh">`,
  so the page flashes past unseen and the flow is the one click it always was.
  Every other scheme waits for the button, because a browser hands a URL to an
  external program on a user gesture rather than on a page's say-so — which is
  the job board's `mailto:`, and reading the address before writing to it is
  no loss.

  Both callers' destinations are scheme-checked where they are produced
  (`Vutuv.Fediverse.RemoteFollow`'s subscribe template must be `https`,
  `apply_url` passes `ChangesetHelpers.validate_url/2`), so nothing exotic
  reaches the `href`; `Phoenix.Component.link/1`'s own check is the backstop,
  and it fails loudly rather than rendering.
  """
  use VutuvWeb, :html

  embed_templates("../templates/outbound/*")

  @doc """
  Everything this page says about `url`, decided once: the heading, the button
  label, and the URL the layout may forward to on its own (`nil` when it may
  not).

  One function rather than three, because all three answers turn on the same
  question — what kind of destination is this — and three separate parses can
  disagree about it. The heading names the destination before the visitor gets
  there: the host for a website, the address itself for a mail.
  """
  def hand_off_copy(url) when is_binary(url) do
    case URI.parse(url) do
      # `mailto:jobs@example.com?subject=…` parses with the address as the path
      # and the subject as the query, so the address is read off `path` alone.
      %URI{scheme: "mailto", path: address} when is_binary(address) ->
        %{
          title: gettext("E-mail to %{address}", address: address),
          label: gettext("Write e-mail"),
          auto_forward: nil
        }

      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        %{
          title: gettext("Continue to %{server}", server: host),
          label: gettext("Continue"),
          auto_forward: url
        }

      # Neither caller can produce this — the subscribe template is https and
      # `apply_url` passes `ChangesetHelpers.validate_url/2` — so it is here
      # only so an unexpected destination renders a page rather than raising on
      # a missing clause. Forwarding to one we cannot name is a different
      # matter, hence no `auto_forward`; refusing a dangerous `href` stays
      # `Phoenix.Component.link/1`'s job.
      _unnameable ->
        %{
          title: gettext("Continue to %{server}", server: url),
          label: gettext("Continue"),
          auto_forward: nil
        }
    end
  end
end
