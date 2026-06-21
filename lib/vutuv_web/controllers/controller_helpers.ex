defmodule VutuvWeb.ControllerHelpers do
  @moduledoc """
  Small helpers shared across controllers.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: VutuvWeb.Endpoint,
    router: VutuvWeb.Router,
    statics: ~w(assets fonts images favicon.ico)

  alias Plug.Conn
  alias Vutuv.Accounts.User
  alias Vutuv.ApiAuth.App
  alias Vutuv.Repo

  @doc """
  Returns the path of the request's `Referer` header, falling back to
  `fallback` when there is no usable referer.

  `fallback` is computed by the caller (typically a `~p` verified route) so the
  route sigil expands at the call site with that controller's correct default.
  """
  def referrer_url(%Conn{} = conn, fallback) when is_binary(fallback) do
    case Conn.get_req_header(conn, "referer") do
      [referer | _] -> URI.parse(referer).path || fallback
      [] -> fallback
    end
  end

  @doc """
  Sends the user back where they came from, falling back to their own profile
  (or the landing page when logged out). The shared shape behind the
  follow/connection controllers, whose redirects all want "back to the page you
  acted from, else your profile".
  """
  def referrer_or_profile(%Conn{} = conn, user) do
    referrer_url(conn, profile_path(user))
  end

  defp profile_path(%User{} = user), do: ~p"/#{user}"
  defp profile_path(_), do: ~p"/"

  @doc """
  Validates a caller-supplied redirect target, returning the path only when it
  is a same-origin absolute path (`/foo`) and `nil` otherwise.

  Protocol-relative URLs (`//evil.com`) are external and rejected; matching the
  prefixes (rather than slicing) also keeps the bare `"/"` from raising.
  """
  def safe_return_to("//" <> _), do: nil
  def safe_return_to("/" <> _ = path), do: path
  def safe_return_to(_), do: nil

  @doc """
  Loads an owned member resource: `Repo.get!` scoped to the path user's
  `assoc` collection, so a caller can only fetch a resource that hangs off the
  user already resolved into `conn.assigns[:user]`. Raises (404) on a miss, the
  same as the inline `Repo.get!(assoc(...), id)` it replaces.
  """
  def get_owned!(%Conn{} = conn, assoc, id) when is_atom(assoc) do
    Repo.get!(Ecto.assoc(conn.assigns[:user], assoc), id)
  end

  @doc """
  The non-raising sibling of `get_owned!/3` for the API: returns the owned
  resource or `nil` (so the caller can answer RFC 9457 `not_found` instead of a
  500), and tolerates a malformed id via `UUIDv7.cast_or_nil/1` rather than a
  CastError. `user` is the authorizing member; `assoc` its collection.
  """
  def get_owned(user, assoc, id) when is_atom(assoc) do
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(Ecto.assoc(user, assoc), uuid)
    end
  end

  @doc """
  Renders the bare `VutuvWeb.ErrorHTML` 403/404 page and halts: the one shape
  every auth/resolve plug and the controller-side guards use to refuse a
  request.
  """
  def render_error(%Conn{} = conn, status) when status in [403, 404] do
    conn
    |> Conn.put_status(status)
    |> Phoenix.Controller.put_view(html: VutuvWeb.ErrorHTML)
    |> Phoenix.Controller.render("#{status}.html")
    |> Conn.halt()
  end

  @doc """
  Looks up a member by a caller-supplied id, returning `nil` for a missing
  *or malformed* id — a garbage (non-UUID) id is a no-op, never an
  `Ecto.CastError` 500. The safe lookup the block/connection/save create paths
  (which act on a user the viewer named in a form param) share.
  """
  def get_user(id) do
    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(User, uuid)
    end
  end

  @doc """
  Owner-scoped OAuth app lookup with the uniform 404: fetches the app the
  current user owns by `id` and calls `fun.(conn, app)`, or renders the shared
  404 page. The shape the developer app + webhook controllers share.
  """
  def with_app(%Conn{} = conn, id, fun) when is_function(fun, 2) do
    case Vutuv.ApiAuth.get_app(conn.assigns.current_user, id) do
      %App{} = app -> fun.(conn, app)
      nil -> render_error(conn, 404)
    end
  end

  @doc """
  Folds the plain "insert/update then flash+redirect or re-render" case shared
  by the straightforward create/update actions.

  Pass the `Repo.insert/1`/`Repo.update/1` result and:

    * `:flash` — the success info message,
    * `:redirect_to` — the success path, either a binary or a 1-arity function
      of the inserted/updated record (for routes that interpolate it),
    * `:render` — the template to re-render on `{:error, changeset}`,
    * `:assigns` — extra assigns for that re-render (the failed changeset is
      merged in automatically as `:changeset`).

  Only the sites whose success/error shape is exactly this plain one use it;
  divergent sites (screenshot side effects, `:bad_request` status,
  provider-specific flashes) keep their explicit `case`.
  """
  def save(%Conn{} = conn, result, opts) do
    case result do
      {:ok, record} ->
        conn
        |> Phoenix.Controller.put_flash(:info, Keyword.fetch!(opts, :flash))
        |> Phoenix.Controller.redirect(to: redirect_target(opts[:redirect_to], record))

      {:error, %Ecto.Changeset{} = changeset} ->
        assigns = Keyword.put(opts[:assigns] || [], :changeset, changeset)

        # A failed validation is not a 200: answer 422 (the browser renders
        # the error form all the same, machines see the truth).
        conn
        |> Conn.put_status(:unprocessable_entity)
        |> Phoenix.Controller.render(Keyword.fetch!(opts, :render), assigns)
    end
  end

  @doc """
  Folds the plain "delete then flash+redirect" case the section delete actions
  share — the delete leg of `save/3`, with no error branch (`Repo.delete!`
  raises if the row is already gone). Pass the loaded `record` (scoped to the
  owner by the caller, e.g. via `get_owned!/3`) plus `:flash` (the success
  message) and `:redirect_to` (the index path).
  """
  def delete(%Conn{} = conn, record, opts) do
    Repo.delete!(record)

    conn
    |> Phoenix.Controller.put_flash(:info, Keyword.fetch!(opts, :flash))
    |> Phoenix.Controller.redirect(to: Keyword.fetch!(opts, :redirect_to))
  end

  defp redirect_target(to, _record) when is_binary(to), do: to
  defp redirect_target(fun, record) when is_function(fun, 1), do: fun.(record)
end
