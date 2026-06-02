defmodule VutuvWeb.ErrorHTML do
  @moduledoc false

  use Gettext, backend: VutuvWeb.Gettext

  def render("404.html", _assigns) do
    "</header> <h1 style=\"text-align:center;\">#{Gettext.gettext(VutuvWeb.Gettext, "Page not found")}</h1>"
    |> Phoenix.HTML.raw()
  end

  def render("403.html", _assigns) do
    "</header> <h1 style=\"text-align:center;\">#{Gettext.gettext(VutuvWeb.Gettext, "You are not allowed to view this page.")}</h1>"
    |> Phoenix.HTML.raw()
  end

  def render("500.html", _assigns) do
    "</header> <h1 style=\"text-align:center;\">#{Gettext.gettext(VutuvWeb.Gettext, "Pardon us! Something went wrong. If you think this is a bug, please %{link_open}submit a bug report.", link_open: "<a href = \"https://github.com/wintermeyer/vutuv/issues/new\">")}</a></h1>"
    |> Phoenix.HTML.raw()
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
