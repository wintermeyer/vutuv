defmodule VutuvWeb.MastodonApi.Errors do
  @moduledoc """
  The error responses every Mastodon-adapter endpoint speaks — the one place
  that decides their status codes and their wording.

  The shape is `%{error: "…"}`, which is Mastodon's, deliberately **not**
  `VutuvWeb.ApiV2.Problem`'s RFC 9457 `application/problem+json`: the two APIs
  answer to different client ecosystems and a client written against Mastodon
  parses `error`. `Problem` is the precedent for having one such module, not a
  module to reuse.

  It exists because these four answers were written out by hand across nine
  controllers — `not_found/1` alone in nine files, `changeset_error/1`
  byte-identical in four — and had already drifted: the same refusal was
  `"This identity cannot perform that action"` in two controllers and
  `"…action."` with a full stop in a third, so a client matching the string saw
  two different errors for one refusal. One spelling wins here (no full stop,
  matching `"Record not found"` beside it).
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias Ecto.Changeset

  @doc """
  The adapter's uniform 404, the same for "does not exist" and "exists but is
  hidden from you" — like the HTML pages, so the API cannot be used to probe
  for accounts or statuses somebody has hidden.
  """
  def not_found(conn), do: error(conn, 404, "Record not found")

  @doc "An arbitrary status with a message, in Mastodon's error shape."
  def error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  @doc """
  The 422 a rejected write answers with. Takes the detail as a string, or as a
  changeset to render through `changeset_error/1`.
  """
  def validation_error(conn, %Changeset{} = changeset),
    do: validation_error(conn, changeset_error(changeset))

  def validation_error(conn, message) when is_binary(message),
    do: error(conn, 422, "Validation failed: " <> message)

  @doc """
  A changeset's errors as one flat sentence, `"field message, field message"`.

  The non-changeset clause is the fallback for a write that failed without one
  (a permission refusal returning a bare atom), which is why callers can hand
  this whatever their context returned.
  """
  def changeset_error(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  def changeset_error(_other), do: "The status is invalid."

  @doc """
  The refusal when the acting identity — a page rather than a member, most of
  the time — may not perform the act at all. One sentence, one spelling.
  """
  def unsupported_identity, do: "This identity cannot perform that action"

  @doc "That same refusal as a 422 response."
  def unsupported(conn), do: error(conn, 422, unsupported_identity())
end
