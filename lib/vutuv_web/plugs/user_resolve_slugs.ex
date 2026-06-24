defmodule VutuvWeb.Plug.UserResolveSlug do
  @moduledoc """
  Resolves the `:slug` / `:user_slug` path segment to the member whose
  `username` it is. There is exactly one live handle per member.

  A live handle always wins. Only when the slug resolves to no member do we
  fall back to `users.legacy_username` - the original handle a member was
  renamed away from (the dotted / over-length imports) - and 301 to that
  member's current handle, so an old profile URL keeps working. The
  reconstructed location swaps just the handle segment and carries the query
  string; the agent-format extension (`.md`, `.json`, ...) is re-appended by
  `VutuvWeb.Plug.AgentFormat`. Anything else is a plain 404 - retired handles
  are not otherwise reserved or redirected.
  """

  import Ecto.Query, only: [from: 2]

  alias Vutuv.Accounts.User
  alias Vutuv.Repo

  def init(opts) do
    opts
  end

  def call(%{params: %{"user_slug" => slug}} = conn, _opts), do: resolve(conn, slug)
  def call(%{params: %{"slug" => slug}} = conn, _opts), do: resolve(conn, slug)
  def call(conn, _opts), do: invalid_slug(conn)

  defp resolve(conn, slug) do
    case Repo.get_by(User, username: slug) do
      nil ->
        case redirect_target(slug) do
          nil -> invalid_slug(conn)
          current -> redirect_to_current(conn, slug, current)
        end

      user ->
        conn
        |> Plug.Conn.assign(:user_id, user.id)
        |> Plug.Conn.assign(:user, user)
    end
  end

  # The current handle of the member who used to answer to this retired one, or
  # nil. One indexed lookup on the (rare) miss path.
  defp redirect_target(slug) do
    Repo.one(from(u in User, where: u.legacy_username == ^slug, select: u.username))
  end

  defp redirect_to_current(conn, old_slug, current_slug) do
    conn
    |> Plug.Conn.put_status(:moved_permanently)
    |> Phoenix.Controller.redirect(to: current_path(conn, old_slug, current_slug))
    |> Plug.Conn.halt()
  end

  # Swap only the handle segment of the (extension-stripped) request path and
  # keep the query string. AgentFormat's `keep_extension/1` re-adds any
  # `.md`/`.json`/... it cut, so the redirect lands on the same format.
  defp current_path(conn, old_slug, current_slug) do
    path =
      Enum.map_join(conn.path_info, "/", fn segment ->
        if segment == old_slug, do: current_slug, else: segment
      end)

    case conn.query_string do
      "" -> "/" <> path
      query -> "/" <> path <> "?" <> query
    end
  end

  defp invalid_slug(conn) do
    VutuvWeb.ControllerHelpers.render_error(conn, 404)
  end
end
