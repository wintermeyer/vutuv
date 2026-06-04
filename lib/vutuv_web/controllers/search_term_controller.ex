defmodule VutuvWeb.SearchTermController do
  use VutuvWeb, :controller

  # Search terms are the current user's private search history, so only the
  # owner may view them. This also guards index/2 against a nil current_user
  # (an anonymous request previously raised a BadMapError -> 500).
  plug(VutuvWeb.Plug.AuthUser)

  alias Vutuv.Accounts.SearchTerm

  def index(conn, _params) do
    search_terms =
      Repo.all(from(s in SearchTerm, where: s.user_id == ^conn.assigns[:current_user].id))

    render(conn, "index.html", search_terms: search_terms, user: conn.assigns[:current_user])
  end

  def show(conn, %{"id" => id}) do
    search_term =
      Repo.get_by!(SearchTerm, id: id, user_id: conn.assigns[:current_user].id)

    render(conn, "show.html", search_term: search_term, user: conn.assigns[:current_user])
  end
end
