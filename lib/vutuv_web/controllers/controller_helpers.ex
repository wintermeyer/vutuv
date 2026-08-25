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
  alias Vutuv.SocialFeed.Http

  @doc """
  Renders the PIN-entry screen belonging to the flow the pending identity is in,
  and assigns what that screen needs (`:pending_email`, `:pin_flow`,
  `:pin_expires_at`).

  **Every place that renders a PIN screen goes through here.** There are five,
  across two controllers, and the rule they share — a registration in flight
  gets the registration screen, everything else the login one — is a fact about
  the signed cookie, not about the call site. It was written once inside the
  landing-page plug first, and the four sites that kept hardcoding the login
  template are exactly what that looked like: a member half-way through signing
  up who opened `/login`, or who simply tapped "Resend PIN", was handed the
  login screen and its advice to try one of their *other* addresses, which is
  the copy that change had just removed.

  Assigning the address here is the second half: the templates used to re-read
  the cookie themselves, so a page verified the same token three times and could
  in principle contradict the screen it was rendering. The deadline joins them
  from the same single read, so a screen can never count down one address's PIN
  while naming another's.
  """
  def render_pin_screen(%Conn{} = conn, opts \\ []) do
    pending = Vutuv.Accounts.pending_pin(conn) || %{email: nil, flow: :login, expires_at: nil}

    conn
    |> Conn.assign(:pending_email, pending.email)
    |> Conn.assign(:pin_flow, pending.flow)
    |> Conn.assign(:pin_expires_at, pending.expires_at)
    |> then(fn conn ->
      case opts[:status] do
        nil -> conn
        status -> Conn.put_status(conn, status)
      end
    end)
    |> pin_view(pending.flow)
  end

  # The two templates live in different view modules, so the branch has to pick
  # the view as well as the name.
  defp pin_view(conn, :registration) do
    conn
    |> Phoenix.Controller.put_view(VutuvWeb.PageHTML)
    |> Phoenix.Controller.render("pin_new_registration.html")
  end

  defp pin_view(conn, _login) do
    conn
    |> Phoenix.Controller.put_view(VutuvWeb.SessionHTML)
    |> Phoenix.Controller.render("pin_user_login.html")
  end

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
  user already resolved into `conn.assigns[:user]`. Raises `Ecto.NoResultsError`
  (a clean 404) on a miss — including a malformed (non-UUID) id, which is cast
  first so it 404s instead of raising an `Ecto.CastError` 500 (these ids come
  from crawlable public URLs like `/slug/emails/notauuid`).
  """
  def get_owned!(%Conn{} = conn, assoc, id) when is_atom(assoc) do
    queryable = Ecto.assoc(conn.assigns[:user], assoc)

    case Vutuv.UUIDv7.cast_or_nil(id) do
      nil -> raise Ecto.NoResultsError, queryable: queryable
      uuid -> Repo.get!(queryable, uuid)
    end
  end

  @doc """
  The non-raising sibling of `get_owned!/3` for the API: returns the owned
  resource or `nil` (so the caller can answer RFC 9457 `not_found` instead of a
  500), and tolerates a malformed id via `UUIDv7.cast_or_nil/1` rather than a
  CastError. `user` is the authorizing member; `assoc` its collection.
  """
  def get_owned(user, assoc, id) when is_atom(assoc) do
    Vutuv.UUIDv7.with_cast(id, &Repo.get(Ecto.assoc(user, assoc), &1))
  end

  @doc """
  The base session map every controller-embedded LiveView needs: the viewer id,
  resolved locale and request path. A LiveView mounted outside the
  `live_session` must be handed these explicitly (the profile/CV/board/feed
  pattern); pages layer their own extra keys on top with `Map.put/3`.

  Worth knowing before you layer one on: this map is signed once per **document**
  and replayed verbatim on every socket rejoin, so it is not a place for
  anything that changes while the page is open — a rejoin would hand back the
  value the page was born with.
  """
  def live_render_session(%Conn{} = conn) do
    %{
      "user_id" => conn.assigns[:current_user_id],
      "locale" => conn.assigns[:locale],
      "request_path" => conn.request_path
    }
  end

  @doc """
  Whether the link-preview screenshot browser is reading this page rather than a
  person (`Vutuv.PageScreenshot`, which sends vutuv's own user agent).

  The capture renders the document **from the top**, so a page that scrolls
  itself on arrival is shot before those tiles are painted and the stored
  preview is an empty page (issue #1033). The capture gets the same content,
  just no jump.

  Shared rather than private to `PostController` because a post permalink now
  comes in two shapes — the member's and the page's
  (`/organizations/:slug/posts/:id`) — and both embed the same scrolling
  `VutuvWeb.PostLive.Thread`. A second private copy of this is a second thing to
  remember when the next author kind appears.
  """
  def page_capture?(%Conn{} = conn) do
    conn |> Conn.get_req_header("user-agent") |> List.first() |> Http.own_agent?()
  end

  @doc """
  `path` with `query` appended, and no stray `?` when there is no query — the
  join three plugs each wrote out for themselves while redirecting somewhere
  that must keep the request's parameters.
  """
  def with_query(path, ""), do: path
  def with_query(path, query) when is_binary(query), do: path <> "?" <> query

  @doc """
  The bearer token on this request, or `nil` — the **one** reading of an
  `Authorization: Bearer …` header in this app.

  HTTP auth scheme names are case-insensitive (RFC 7235) and real clients do
  send a lowercase `bearer`, so the comparison is on the downcased scheme and
  the token is trimmed. It lives here because it had grown three spellings:
  two identical private copies in the Mastodon and `/api/2.0` auth plugs, and a
  stricter third in the bounce webhook that pattern-matched `"Bearer " <> rest`
  — which accepted only a capital B and exactly one space, so an operator whose
  sender wrote `bearer ` got a 401 that reads as a wrong secret.

  Callers that compare the result against a shared secret must still do it with
  `Plug.Crypto.secure_compare/2`; this only reads the header.
  """
  def bearer_token(%Conn{} = conn) do
    with [header] <- Conn.get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2, trim: true),
         "bearer" <- String.downcase(scheme) do
      String.trim(token)
    else
      _other -> nil
    end
  end

  @doc """
  Answers an `avatar.jpg` request with the derived bytes, or with the plain
  404 every failure shares.

  The two endpoints (`/:slug/avatar.jpg` for a member, `/organizations/:slug/avatar.jpg`
  for a page) differ only in the lookup and its visibility gate; the answer is
  the same both ways, and both halves of it are decisions rather than details:
  the cache lifetime keeps repeat scraper traffic off libvips, and the
  featureless plain-text 404 is what makes an unknown slug, a missing picture
  and a page nobody may see indistinguishable from outside.
  """
  def send_og_jpeg(%Conn{} = conn, {:ok, jpeg}) do
    conn
    |> Conn.put_resp_content_type("image/jpeg", nil)
    |> Conn.put_resp_header("cache-control", "public, max-age=86400")
    |> Conn.send_resp(200, jpeg)
  end

  def send_og_jpeg(%Conn{} = conn, _missing) do
    conn
    |> Conn.put_resp_content_type("text/plain")
    |> Conn.send_resp(404, "Not Found")
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
  Answers a form submission whose destination is another site: a 200 that
  names `url`, explains itself with `note`, and links on (issue #1569).

  **Use this instead of `redirect(conn, external: …)` in reply to a POST.**
  `form-action 'self'` is enforced on a submission's redirects too, so the 302
  is dropped by Chrome and WebKit with nothing to see on either side. The full
  reasoning, and why an `http(s)` destination still costs no click, is in
  `VutuvWeb.OutboundHTML`.

  A same-origin destination needs none of this — keep redirecting to those.
  """
  def hand_off(%Conn{} = conn, url, note) when is_binary(url) and is_binary(note) do
    copy = VutuvWeb.OutboundHTML.hand_off_copy(url)

    conn
    |> Conn.assign(:meta_refresh, copy.auto_forward)
    |> chrome_for(copy)
    |> Phoenix.Controller.put_view(html: VutuvWeb.OutboundHTML)
    |> Phoenix.Controller.render("hand_off.html", url: url, note: note, copy: copy)
  end

  # A page that forwards itself is never read, so it does not pay for the app
  # chrome. The saving is not the dead render itself — `ShellLive.mount_static/3`
  # runs no query, and it costs 20–30 KB and well under a millisecond. It is
  # that `app.html.heex` holds the document's **only live root**, so without it
  # `liveSocket.connect()` takes its dead branch and never opens a socket at
  # all: no connected `ShellLive` mount (5 queries and ~2.3 ms for a signed-in
  # member, measured), no presence track and untrack, for a document the
  # browser replaces in the same frame. Dropping the *app* layout keeps the
  # *root* one, which is where the meta refresh has to live anyway. The page
  # that waits for a click is read, so it keeps the chrome — a bare dead end
  # there is worse than the render.
  defp chrome_for(conn, %{auto_forward: nil}), do: conn
  defp chrome_for(conn, _forwards_itself), do: Phoenix.Controller.put_layout(conn, html: false)

  @doc """
  Renders the "this profile is currently unavailable" page and halts with the
  given status (issue #812): `403` for a reversible hold (frozen / suspended /
  unreachable), `410` for a permanently deactivated account. Unlike
  `render_error/2`'s generic 403 ("you are not allowed to view this page"), this
  gives a profile-specific body that owns up to "exists, withheld" without
  revealing *why*. `VutuvWeb.Plug.EnsureActivated` is the one caller.
  """
  def render_withheld_profile(%Conn{} = conn, status) when status in [403, 410] do
    conn
    |> Conn.put_status(status)
    |> Phoenix.Controller.put_view(html: VutuvWeb.ErrorHTML)
    |> Phoenix.Controller.render("profile_unavailable.html", code: status)
    |> Conn.halt()
  end

  @doc """
  Looks up a member by a caller-supplied id, returning `nil` for a missing
  *or malformed* id — a garbage (non-UUID) id is a no-op, never an
  `Ecto.CastError` 500. The safe lookup the block/connection/save create paths
  (which act on a user the viewer named in a form param) share.
  """
  def get_user(id) do
    Vutuv.UUIDv7.with_cast(id, &Repo.get(User, &1))
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
