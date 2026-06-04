defmodule VutuvWeb.Plug.UserResolveSlug do
  @moduledoc false

  import Plug.Conn
  import Ecto.Query
  import Phoenix.Controller
  alias Vutuv.Repo

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico robots.txt)

  def init(opts) do
    opts
  end

  def call(%{params: %{"user_slug" => slug}} = conn, _opts), do: resolve(conn, slug)
  def call(%{params: %{"slug" => slug}} = conn, _opts), do: resolve(conn, slug)
  def call(conn, _opts), do: invalid_slug(conn)

  defp resolve(conn, slug) do
    Repo.one(
      from(s in Vutuv.Accounts.Slug,
        join: u in assoc(s, :user),
        where: s.value == ^slug and not is_nil(u.id),
        preload: [:user]
      )
    )
    |> eval_slug(conn)
  end

  defp eval_slug(%{disabled: false, user: user, value: slug}, conn) do
    if user.active_slug != slug do
      conn
      |> redirect(to: ~p"/users/#{user}")
      |> halt()
    else
      conn
      |> assign(:user_id, user.id)
      |> assign(:user, user)
    end
  end

  defp eval_slug(_, conn) do
    invalid_slug(conn)
  end

  defp invalid_slug(conn) do
    VutuvWeb.ControllerHelpers.render_error(conn, 404)
  end
end
