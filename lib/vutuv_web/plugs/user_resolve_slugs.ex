defmodule VutuvWeb.Plug.UserResolveSlug do
  @moduledoc """
  Resolves the `:slug` / `:user_slug` path segment to the member whose
  `active_slug` it is. There is exactly one live handle per member - old
  handles are neither reserved nor redirected, so an unknown handle is a
  plain 404.
  """

  alias Vutuv.Repo

  def init(opts) do
    opts
  end

  def call(%{params: %{"user_slug" => slug}} = conn, _opts), do: resolve(conn, slug)
  def call(%{params: %{"slug" => slug}} = conn, _opts), do: resolve(conn, slug)
  def call(conn, _opts), do: invalid_slug(conn)

  defp resolve(conn, slug) do
    case Repo.get_by(Vutuv.Accounts.User, active_slug: slug) do
      nil ->
        invalid_slug(conn)

      user ->
        conn
        |> Plug.Conn.assign(:user_id, user.id)
        |> Plug.Conn.assign(:user, user)
    end
  end

  defp invalid_slug(conn) do
    VutuvWeb.ControllerHelpers.render_error(conn, 404)
  end
end
