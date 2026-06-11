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
          "Admin rights are granted by the operator of this vutuv instance, directly in the database:"
        )}
      </p>
      <p class="error-page__hint"><code>UPDATE users SET administrator = TRUE WHERE ...;</code></p>
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
