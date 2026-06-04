defmodule VutuvWeb.ControllerHelpers do
  @moduledoc """
  Small helpers shared across controllers.
  """

  alias Plug.Conn
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
  Loads an owned member resource: `Repo.get!` scoped to the path user's
  `assoc` collection, so a caller can only fetch a resource that hangs off the
  user already resolved into `conn.assigns[:user]`. Raises (404) on a miss, the
  same as the inline `Repo.get!(assoc(...), id)` it replaces.
  """
  def get_owned!(%Conn{} = conn, assoc, id) when is_atom(assoc) do
    Repo.get!(Ecto.assoc(conn.assigns[:user], assoc), id)
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
        Phoenix.Controller.render(conn, Keyword.fetch!(opts, :render), assigns)
    end
  end

  defp redirect_target(to, _record) when is_binary(to), do: to
  defp redirect_target(fun, record) when is_function(fun, 1), do: fun.(record)
end
