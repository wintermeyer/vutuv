defmodule VutuvWeb.ErrorHTML do
  @moduledoc """
  Styled error pages. Each `render/2` returns the `.error-page` **card**
  (code, message, "Back to the start page"); a layout wraps it into a full
  document. Two wrappers, both styled:

    * a plug halts a request (`Plug.All404`, `EnsureActivated`, authorization
      checks) → the controller renders the card inside the normal **app
      layout**, styled by the loaded `/assets/app.css`.
    * Phoenix itself rescues an exception (a real 500, a 413 upload, an
      unmatched route) → `render_errors` wraps the card in the **self-contained
      `VutuvWeb.LayoutHTML.error/1` layout** (`layout/error.html.heex`): a full
      HTML document with inline critical CSS, so the page looks like vutuv.de
      even when the database or the asset pipeline is what broke. It used to
      render bare (`layout: false`) and reached production as unstyled serif
      text; see `error_layout_test.exs`.

  The card leans on the `.error-page` classes, defined both in `components.css`
  (for the app-layout path) and inline in the error layout (for the rescued
  path), so it reads correctly in either wrapper.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Operator
  alias Vutuv.SourceRepo
  alias VutuvWeb.Endpoint
  alias VutuvWeb.PageHTML

  # A request the server could not read (issue #1227): a mangled multipart
  # body raises in the endpoint (invalid UTF-8 in a text part, or all fields
  # dropped over a defective Content-Disposition) before any controller runs,
  # so no per-form message can help — and the fallback used to be the bare
  # words "Bad Request", a dead end. Say what happened, that reload + resend
  # usually clears it, and give the recurring case a bug-report path.
  def render("400.html", assigns) do
    assigns = Map.new(assigns)

    ~H"""
    <div class="error-page">
      <p class="error-page__code">400</p>
      <h1 class="error-page__title">
        {gettext("Your browser sent a request we could not read.")}
      </h1>
      <p class="error-page__hint">
        {gettext("Please go back, reload the page, and send the form again.")}
      </p>
      <p class="error-page__hint">
        {gettext("If this keeps happening, please tell us with a bug report at")}
        <a href={SourceRepo.issues_url()}>{SourceRepo.issues_label()}</a>.
      </p>
      <%!-- Why the stamp is printed rather than asked for, and why in UTC:
      see `utc_stamp/0`. --%>
      <p class="error-page__hint">
        {gettext(
          "The most helpful detail in such a report is the exact time of the error. Right now it is %{time}.",
          time: utc_stamp()
        )}
      </p>
      <p class="error-page__actions">
        <a href="/" class="button">{gettext("Back to the start page")}</a>
      </p>
    </div>
    """
  end

  # The opposite of the 500 below, and the page has to say so: everything here
  # works, the address is simply not one of ours. "Page not found" left the
  # visitor unable to tell that from an outage — the same two words a browser
  # shows when a site is down — so the card names what is fine, what is not,
  # and the two ordinary reasons (an old link, a typo) before pointing home.
  def render("404.html", assigns) do
    assigns = Map.new(assigns)

    ~H"""
    <div class="error-page">
      <p class="error-page__code">404</p>
      <h1 class="error-page__title">{gettext("This page does not exist")}</h1>
      <p class="error-page__hint">
        {gettext(
          "The site itself is running, this address just is not one of ours. The link is probably old, or it carries a typo."
        )}
      </p>
      <p class="error-page__actions">
        <a href="/" class="button">{gettext("Back to the start page")}</a>
      </p>
    </div>
    """
  end

  def render("403.html", assigns) do
    assigns
    |> Map.new()
    |> Map.merge(%{code: 403, message: gettext("You are not allowed to view this page.")})
    |> error_page()
  end

  def render("410.html", assigns) do
    assigns
    |> Map.new()
    |> Map.merge(%{code: 410, message: gettext("This page is no longer available.")})
    |> error_page()
  end

  # The one error page that cannot say what happened: the request died where
  # this page cannot see. What it *can* say is the shape of the two causes and
  # how long each takes, which is the question the visitor actually has. The
  # commonest one is not a bug at all but a deploy in flight, so the page names
  # the wait (`:deploy_minutes`) rather than asking for patience in the
  # abstract — and hands over what turns the other case into a report somebody
  # can act on: who to write to, and the code and the minute to quote. What it
  # replaced said "Pardon us! Something went wrong." and linked a bug tracker.
  def render("500.html", assigns) do
    assigns = Map.new(assigns)

    ~H"""
    <div class="error-page">
      <p class="error-page__code">500</p>
      <h1 class="error-page__title">{gettext("This site is offline right now.")}</h1>
      <p class="error-page__hint">
        {gettext(
          "That is either a fault in the software or a new version being installed. Either way the site is away only briefly."
        )}
      </p>
      <p class="error-page__hint">
        {ngettext(
          "Installing a new version takes up to one minute.",
          "Installing a new version takes up to %{count} minutes.",
          deploy_minutes()
        )}
      </p>
      <.operator_contact code={500} />
      <p class="error-page__actions">
        <a href="/" class="button">{gettext("Back to the start page")}</a>
      </p>
    </div>
    """
  end

  # A withheld profile (issue #812): the account exists but is currently hidden
  # (frozen / suspended → 403, permanently deactivated → 410). Deliberately
  # vague — it does not reveal *why* — and distinct from the generic 403
  # ("you are not allowed to view this page"), which is about the viewer's
  # permissions, not the resource's state. `@code` is the status the caller
  # (`EnsureActivated`) chose.
  def render("profile_unavailable.html", assigns) do
    assigns = assigns |> Map.new() |> Map.put_new(:code, 403)

    ~H"""
    <div class="error-page">
      <p class="error-page__code">{@code}</p>
      <h1 class="error-page__title">{gettext("This profile is currently unavailable.")}</h1>
      <p class="error-page__actions">
        <a href="/" class="button">{gettext("Back to the start page")}</a>
      </p>
    </div>
    """
  end

  # An upload beyond Plug.Parsers' multipart cap raises before any controller
  # runs, so the friendly per-form messages never get a chance — the member
  # uploading a too-big LinkedIn archive or photo gets this card instead of
  # the bare fallback text.
  def render("413.html", assigns) do
    assigns
    |> Map.new()
    |> Map.merge(%{code: 413, message: gettext("The file you sent is too large.")})
    |> error_page()
  end

  # The admin-area 403 for a logged-in member: instead of a bare error it
  # answers the natural follow-up question - how does one become an admin?
  def render("403_admin.html", assigns) do
    assigns = Map.new(assigns)

    ~H"""
    <div class="error-page">
      <p class="error-page__code">403</p>
      <h1 class="error-page__title">{gettext("This area is reserved for administrators.")}</h1>
      <p class="error-page__hint">
        {gettext(
          "Admin rights are granted by the operator of this vutuv instance, from the server's command line:"
        )}
      </p>
      <p class="error-page__hint"><code>mix vutuv.admin.promote &lt;handle&gt;</code></p>
      <p class="error-page__hint">
        {gettext("If you do not run this instance yourself, please contact the operator.")}
        <a href="/impressum">{gettext("Legal notice")}</a>
      </p>
      <p class="error-page__actions">
        <a href="/" class="button">{gettext("Back to the start page")}</a>
      </p>
    </div>
    """
  end

  # The helper page for /username (and the German /benutzername): people copy
  # the literal placeholder out of instructions ("your profile lives at
  # vutuv.de/username") and land here. Instead of a bare 404 it explains that
  # the word is a placeholder for the person's real handle and links a concrete
  # example. The prominent note owns up to a newsletter that once shipped this
  # exact broken link. Rendered with a 404 status by VutuvWeb.PageController.
  def render("username_placeholder.html", assigns) do
    assigns =
      assigns |> Map.new() |> Map.put(:example_profile_url, PageHTML.example_profile_url())

    ~H"""
    <div class="error-page">
      <p class="error-page__code">404</p>
      <h1 class="error-page__title">{gettext("This page does not exist")}</h1>
      <p class="error-page__note">
        {gettext(
          "Mea culpa: we once sent this exact broken link in a newsletter. We are sorry!"
        )}
      </p>
      <p class="error-page__hint">
        {gettext("The word")} <code>username</code>
        {gettext(
          "in this address is only a placeholder. Replace it with the actual username of the person whose profile you want to visit."
        )}
      </p>
      <%!-- The example must exist on every installation, so it is an absolute
            URL rather than an assumption that this host has a member called
            wintermeyer. Which profile it is belongs to the operator
            (`:landing_example_profile_url`, LANDING_EXAMPLE_PROFILE_URL): the
            vutuv.de founder profile is only its default, and an installation
            that cleared the key gets no line at all rather than a link into
            somebody else's site. --%>
      <p :if={@example_profile_url} class="error-page__hint">
        {gettext("For example, this profile really exists:")}
        <a href={@example_profile_url}>{PageHTML.example_profile_label(@example_profile_url)}</a>
      </p>
      <p class="error-page__hint">
        {gettext("Do not know the username? Try the")}
        <a href="/search">{gettext("search page")}</a>.
      </p>
      <p class="error-page__actions">
        <a href="/" class="button">{gettext("Back to the start page")}</a>
      </p>
    </div>
    """
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  @doc """
  Who to write to when the page cannot say what went wrong, and what to quote.

  Shared by the 500 card and the service worker's offline page, which ask a
  visitor the same thing from opposite sides: one knows the request reached us
  and died, the other that it never arrived. Neither can tell how long it has
  been that way, so both end on a person rather than on a retry button.

  The name is the reader's link text and the address the `mailto:` behind it,
  both from `Vutuv.Operator` — a third-party installation names its own
  operator, never ours.
  """
  attr(:code, :integer,
    default: nil,
    doc: """
    The status to quote in the report. `nil` on the offline page, which has
    neither a status code nor a clock a reader could trust: it is served from
    the service worker's cache, so a rendered timestamp would be the moment it
    was stored, days before the failure it explains.
    """
  )

  # The stamp is bound once because two things have to quote the same minute:
  # the sentence the reader can copy, and the subject the mail client opens
  # with.
  def operator_contact(assigns) do
    assigns = assign(assigns, :stamp, assigns.code && utc_stamp())

    ~H"""
    <p class="error-page__hint">{gettext("If it takes longer, please write to:")}</p>
    <p class="error-page__hint">
      <a href={Operator.contact_mailto(mail_subject(@code, @stamp))}>
        {Operator.contact_name()}, {Operator.contact_email()}
      </a>
    </p>
    <p :if={@stamp} class="error-page__hint">
      {gettext("Please quote the error code %{code} and the time %{time}.",
        code: @code,
        time: @stamp
      )}
    </p>
    """
  end

  defp mail_subject(nil, _stamp), do: gettext("%{host} cannot be reached", host: host())

  defp mail_subject(code, stamp),
    do: gettext("Error %{code} on %{host}, %{time}", code: code, host: host(), time: stamp)

  # From config rather than `VutuvWeb.Endpoint.host/0`, whose persistent term
  # **raises** when the endpoint is not up. That is exactly the state this page
  # is the fallback for, and a raise inside `render_errors` drops Plug back to
  # the bare "Internal Server Error" text — the page this card exists to
  # replace. Every environment sets the key; reading it defensively costs
  # nothing.
  defp host do
    :vutuv
    |> Application.get_env(Endpoint, [])
    |> Keyword.get(:url, [])
    |> Keyword.get(:host)
  end

  # How long a deploy takes here. A per-installation value with a default of
  # ours, not a number typed into a translation, or every other installation
  # would promise a pipeline it does not run.
  defp deploy_minutes, do: Application.get_env(:vutuv, :deploy_minutes, 10)

  # Rendered, not merely asked for: the visitor is the only one who knows when
  # it happened and the operator's log is the only place the cause is, so the
  # minute that joins the two is printed rather than requested. UTC and
  # server-rendered on purpose — an error page must work when the asset
  # pipeline, and with it the local-time rewriting JS, is exactly what broke.
  defp utc_stamp, do: Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")

  # The plain card: a code and one sentence. What is left for it are the three
  # refusals that need no explaining (403, 410, 413) — every page that has
  # something to say beyond its own status line writes its own markup above.
  # Its three callers all merge a `:code`, so there is no default here.
  defp error_page(assigns) do
    ~H"""
    <div class="error-page">
      <p class="error-page__code">{@code}</p>
      <h1 class="error-page__title">{@message}</h1>
      <p class="error-page__actions">
        <a href="/" class="button">{gettext("Back to the start page")}</a>
      </p>
    </div>
    """
  end
end
