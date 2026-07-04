defmodule VutuvWeb.ErrorHTML do
  @moduledoc """
  Styled error pages. Rendered inside the app layout when a plug halts a
  request (`Plug.All404`, `EnsureActivated`, authorization checks), and bare
  (config `render_errors` has `layout: false`) when Phoenix itself rescues an
  exception — the markup must read fine either way, so it leans on the
  `.error-page` classes from `components.css` and stays sensible without them.
  """

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  def render("404.html", assigns) do
    assigns
    |> Map.new()
    |> Map.merge(%{code: 404, message: gettext("Page not found")})
    |> error_page()
  end

  def render("403.html", assigns) do
    assigns
    |> Map.new()
    |> Map.merge(%{code: 403, message: gettext("You are not allowed to view this page.")})
    |> error_page()
  end

  def render("500.html", assigns) do
    assigns
    |> Map.new()
    |> Map.merge(%{code: 500, message: gettext("Pardon us! Something went wrong.")})
    |> error_page()
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
    assigns = Map.new(assigns)

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
      <%!-- The example must exist on every installation, so it points at the
            founder's profile on vutuv.de absolutely instead of assuming this
            host has a member called wintermeyer. --%>
      <p class="error-page__hint">
        {gettext("For example, this profile really exists:")}
        <a href="https://vutuv.de/wintermeyer">vutuv.de/wintermeyer</a>
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

  defp error_page(assigns) do
    assigns = Map.put_new(assigns, :code, 404)

    ~H"""
    <div class="error-page">
      <p class="error-page__code">{@code}</p>
      <h1 class="error-page__title">{@message}</h1>
      <p :if={@code == 500} class="error-page__hint">
        {gettext("If you think this is a bug, please")}
        <a href="https://github.com/wintermeyer/vutuv/issues/new">{gettext("submit a bug report")}</a>.
      </p>
      <p class="error-page__actions">
        <a href="/" class="button">{gettext("Back to the start page")}</a>
      </p>
    </div>
    """
  end
end
