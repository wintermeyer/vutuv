defmodule VutuvWeb.Admin.LocaleController do
  use VutuvWeb, :controller

  alias Vutuv.Accounts.Locale

  def index(conn, _params) do
    locales = Repo.all(Locale)
    render(conn, "index.html", locales: locales)
  end

  def show(conn, %{"id" => id}) do
    locale =
      Repo.get!(Locale, id)
      |> Repo.preload(exonyms: [:locale, :exonym_locale])

    render(conn, "show.html", loc: locale)
  end
end
