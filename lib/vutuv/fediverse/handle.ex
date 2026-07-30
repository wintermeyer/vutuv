defmodule Vutuv.Fediverse.Handle do
  @moduledoc """
  How vutuv names an account that lives on another server: `@handle@host`, the
  form every one of those networks uses.

  One module because two different tables need the same answer — a stored reply
  (`Vutuv.Fediverse.Note`) and a stored reaction (`Vutuv.Fediverse.Reaction`) —
  and a reader must not see the same person written two ways on one page.

  The handle we store is the actor document's `preferredUsername`. When there is
  none (a row written before we kept it, or a server that omits it) the account
  URI still carries a usable name: every implementation puts it in the last path
  segment — Mastodon and Pleroma `/users/alice`, Lemmy `/u/alice`, Friendica
  `/profile/alice`, some servers `/@alice`.

  Deriving it is a **display** fallback and nothing more. It is guesswork: a
  server that puts an opaque id there gives an opaque name, which is why the
  chip is always a link to the account URI — that one is canonical. Where the
  segment is not even shaped like a name (empty, a path we cannot read) the bare
  host is shown instead, because the host is always true.
  """

  alias Vutuv.SearchText

  # Shaped like a name at all: one path segment, no whitespace, no separators,
  # and short enough not to be a wall of text in a chip.
  @username ~r/^[A-Za-z0-9_.-]{1,64}$/

  @doc """
  `@handle@host` for a stored `handle` (may be nil) and the account's URI.

  Falls back to the URI's last path segment, then to `@host` alone, and finally
  — for a URI we cannot even parse a host out of — to the stored handle or nil.
  """
  def display(handle, actor_uri) do
    case {SearchText.normalize_search(handle) || derive(actor_uri), host(actor_uri)} do
      {nil, nil} -> nil
      {name, nil} -> "@" <> name
      {nil, host} -> "@" <> host
      {name, host} -> "@" <> name <> "@" <> host
    end
  end

  @doc "The server an account URI names, or nil."
  def host(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  def host(_uri), do: nil

  # The last path segment, when it reads like a username. A leading "@" is part
  # of the URL style (`/@alice`), not part of the name.
  defp derive(uri) when is_binary(uri) do
    uri
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> String.split("/", trim: true)
    |> List.last()
    |> to_string()
    |> String.trim_leading("@")
    |> username()
  end

  defp derive(_uri), do: nil

  defp username(candidate) do
    if Regex.match?(@username, candidate), do: candidate
  end
end
