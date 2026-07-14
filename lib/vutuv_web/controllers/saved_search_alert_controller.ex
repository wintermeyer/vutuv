defmodule VutuvWeb.SavedSearchAlertController do
  @moduledoc """
  Switching **one** saved search's e-mail alert off without a login — the
  per-search link the alert digest carries next to each search (issue #935).
  The GET renders a confirmation page, the POST flips that search's cadence to
  `none`. The signed token (`VutuvWeb.SavedSearchToken`) is the only
  authorization; anything else 404s.

  Lives outside CSRF (the `:unsubscribe` pipeline) and renders `layout: false`,
  exactly like `VutuvWeb.UnsubscribeController` — the page is opened from a mail
  by a usually logged-out recipient, and the action only ever switches one
  cadence off. The member-level "switch off *all* alert mail" one-click is the
  ordinary unsubscribe flow (`saved_search_emails?`).
  """

  use VutuvWeb, :controller

  alias Vutuv.SavedSearches
  alias Vutuv.SavedSearches.SavedSearch
  alias VutuvWeb.ControllerHelpers
  alias VutuvWeb.SavedSearchToken

  plug(:put_layout, html: false)

  def show(conn, %{"token" => token}) do
    case saved_search_for_token(token) do
      %SavedSearch{} = saved_search ->
        render(conn, "show.html", saved_search: saved_search, token: token)

      _ ->
        ControllerHelpers.render_error(conn, 404)
    end
  end

  def create(conn, %{"token" => token}) do
    with %SavedSearch{} = saved_search <- saved_search_for_token(token),
         {:ok, saved_search} <- SavedSearches.disable(saved_search) do
      render(conn, "done.html", saved_search: saved_search)
    else
      _ -> ControllerHelpers.render_error(conn, 404)
    end
  end

  defp saved_search_for_token(token) do
    case SavedSearchToken.verify(token) do
      {:ok, id} -> SavedSearches.get(id)
      _ -> nil
    end
  end
end
