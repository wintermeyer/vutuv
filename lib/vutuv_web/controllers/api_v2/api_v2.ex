defmodule VutuvWeb.ApiV2 do
  @moduledoc """
  Shared response helpers for the `/api/2.0` controllers: success bodies are
  the same doc maps the public AgentDocs `.json` siblings serve (rendered
  by `VutuvWeb.AgentDocs.JSON`), so the authenticated API and the anonymous
  JSON pages speak one schema. Errors are `VutuvWeb.ApiV2.Problem`.
  """

  import Plug.Conn

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Moderation
  alias VutuvWeb.AgentDocs.JSON
  alias VutuvWeb.ApiV2.Problem

  def send_json(conn, doc, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.render(doc))
  end

  @cursor_salt "api v1 cursor"

  @doc """
  Keyset cursors cross the wire signed: opaque to clients, tamper-proof for
  us (`Phoenix.Token` only term-decodes after verifying the signature).
  Shared by every cursor-paginated endpoint (feed, messages, notifications).
  `false` is the no-more-pages value the callers compute via `page.more? &&
  page.next_cursor`.
  """
  def encode_cursor(false), do: nil

  def encode_cursor(cursor) do
    Phoenix.Token.sign(VutuvWeb.Endpoint, @cursor_salt, cursor)
  end

  @doc "The inverse: `{:ok, cursor | nil}` or `:error` on a foreign/tampered value."
  def decode_cursor(nil), do: {:ok, nil}
  def decode_cursor(""), do: {:ok, nil}

  def decode_cursor(value) when is_binary(value) do
    case Phoenix.Token.verify(VutuvWeb.Endpoint, @cursor_salt, value, max_age: 86_400) do
      {:ok, cursor} -> {:ok, cursor}
      {:error, _reason} -> :error
    end
  end

  def decode_cursor(_other), do: :error

  @doc """
  The cursor-pagination plumbing every paginated endpoint shares: decodes
  `params["cursor"]` and hands it to `fun`, or answers the uniform 400.
  Pair with `page_fields/1` for the response envelope.
  """
  def with_cursor(conn, params, fun) do
    case decode_cursor(params["cursor"]) do
      {:ok, cursor} ->
        fun.(cursor)

      :error ->
        Problem.send_problem(conn, 400, "Bad cursor",
          detail: "Pass the next_cursor value from a previous page, unmodified."
        )
    end
  end

  @doc "The shared tail of every cursor-paginated response."
  def page_fields(page) do
    %{more: page.more?, next_cursor: encode_cursor(page.more? && page.next_cursor)}
  end

  @doc "Clamped per-page limit from the request params."
  def page_limit(params, default \\ 25) do
    case Integer.parse(to_string(params["limit"] || "")) do
      {n, ""} when n in 1..100 -> n
      _default -> default
    end
  end

  @doc """
  Resolves a slug to a user the viewer may see, or `:error` (one shape for
  unknown / never-activated / moderation-hidden, so the API cannot probe).
  The rule itself is `Vutuv.Moderation.profile_visible_to?/2` — the same
  one the HTML gate (`VutuvWeb.Plug.EnsureActivated`) enforces, with the
  token's user as viewer: the API reads through their eyes.
  """
  def fetch_visible_user(slug, viewer) do
    with %User{} = user <- Accounts.get_user_by_slug(slug),
         true <- Moderation.profile_visible_to?(user, viewer) do
      {:ok, user}
    else
      _missing_or_hidden -> :error
    end
  end

  @doc "`fetch_visible_user/2` with the uniform 404 — the shape every slug endpoint shares."
  def with_visible_user(conn, slug, fun) do
    case fetch_visible_user(slug, conn.assigns.current_user) do
      {:ok, user} -> fun.(user)
      :error -> Problem.not_found(conn)
    end
  end
end
