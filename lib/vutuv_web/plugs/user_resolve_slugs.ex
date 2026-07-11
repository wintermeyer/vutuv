defmodule VutuvWeb.Plug.UserResolveSlug do
  @moduledoc """
  Resolves the `:slug` / `:user_slug` path segment to the member whose
  `username` it is. There is exactly one live handle per member.

  A live member handle always wins, and the member fast-path is unchanged: one
  indexed `users.username` lookup. Only on a miss do we consider the shared
  handle namespace (issue #941): when the plug is used with
  `dispatch_organization: true` (the bare profile route `/:slug` only), a miss that
  matches a **organization** handle (`organizations.username`) renders that organization's
  page in place and halts, so `/lufthansa` serves the Lufthansa page exactly
  like `/organizations/lufthansa`. The member sub-page pipeline (`:user_pipe`) uses
  the plug **without** the option, so `/:organization_handle/followers` and friends
  stay member-only and 404.

  Failing both, we fall back to `users.legacy_username` — the original handle a
  member was renamed away from (the dotted / over-length imports) - and 301 to
  that member's current handle, so an old profile URL keeps working. The
  reconstructed location swaps just the handle segment and carries the query
  string; the agent-format extension (`.md`, `.json`, ...) is re-appended by
  `VutuvWeb.Plug.AgentFormat`. Anything else is a plain 404 - retired handles
  are not otherwise reserved or redirected.
  """

  import Ecto.Query, only: [from: 2]

  alias Vutuv.Accounts.User
  alias Vutuv.Organizations
  alias Vutuv.Repo
  alias VutuvWeb.OrganizationController

  def init(opts) do
    opts
  end

  def call(%{params: %{"user_slug" => slug}} = conn, opts), do: resolve(conn, slug, opts)
  def call(%{params: %{"slug" => slug}} = conn, opts), do: resolve(conn, slug, opts)
  def call(conn, _opts), do: invalid_slug(conn)

  defp resolve(conn, slug, opts) do
    case Repo.get_by(User, username: slug) do
      nil ->
        miss(conn, slug, opts)

      user ->
        conn
        |> Plug.Conn.assign(:user_id, user.id)
        |> Plug.Conn.assign(:user, user)
    end
  end

  # No member holds this handle. On the bare profile route, an organization handle
  # renders the organization page in place; otherwise fall back to the retired-handle
  # 301, else 404.
  defp miss(conn, slug, opts) do
    organization =
      Keyword.get(opts, :dispatch_organization, false) && visible_organization(conn, slug)

    cond do
      organization ->
        conn
        |> OrganizationController.render_page(organization)
        |> Plug.Conn.halt()

      current = redirect_target(slug) ->
        redirect_to_current(conn, slug, current)

      true ->
        invalid_slug(conn)
    end
  end

  # An organization whose root handle is this slug and which `viewer` may see (an
  # active, non-frozen page for the public; owner/admin also see it earlier), or
  # nil.
  defp visible_organization(conn, slug) do
    case Organizations.get_organization_by_username(slug) do
      nil ->
        nil

      organization ->
        if Organizations.organization_visible_to?(organization, conn.assigns[:current_user]),
          do: organization,
          else: nil
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
