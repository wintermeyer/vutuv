defmodule VutuvWeb.ApiV2 do
  @moduledoc """
  Shared response helper for the `/api/2.0` controllers: success bodies are
  the same doc maps the public AgentDocs `.json` siblings serve (rendered
  by `VutuvWeb.AgentDocs.JSON`), so the authenticated API and the anonymous
  JSON pages speak one schema. Errors are `VutuvWeb.ApiV2.Problem`.
  """

  import Plug.Conn

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Moderation
  alias VutuvWeb.AgentDocs.JSON

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
  """
  def encode_cursor(nil), do: nil
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
  Mirrors `VutuvWeb.Plug.EnsureActivated`: hidden accounts stay visible to
  themselves and admins — the API reads through the viewer's eyes.
  """
  def fetch_visible_user(slug, viewer) do
    with %User{} = user <- Accounts.get_user_by_slug(slug),
         true <- visible_to?(user, viewer) do
      {:ok, user}
    else
      _missing_or_hidden -> :error
    end
  end

  defp visible_to?(user, viewer) do
    activated?(user) and (not Moderation.account_hidden?(user) or bypass?(user, viewer))
  end

  defp activated?(%User{activated?: true}), do: true
  defp activated?(%User{activated?: nil}), do: true
  defp activated?(_user), do: false

  defp bypass?(%User{id: id}, %User{id: id}), do: true
  defp bypass?(_user, %User{admin?: true}), do: true
  defp bypass?(_user, _viewer), do: false
end
