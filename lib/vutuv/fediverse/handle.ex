defmodule Vutuv.Fediverse.Handle do
  @moduledoc """
  How vutuv names an account that lives on another server: `@handle@host`, the
  form every one of those networks uses.

  One module because two different tables need the same answer — a stored reply
  (`Vutuv.Fediverse.Note`) and a stored reaction (`Vutuv.Fediverse.Reaction`) —
  and a reader must not see the same person written two ways on one page. The
  same reason puts the *display name* here too (`display_name/1`): the name and
  the handle are the two halves of one card header.

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

  alias Vutuv.RemoteHtml
  alias Vutuv.SearchText

  # Shaped like a name at all: one path segment, no whitespace, no separators,
  # and short enough not to be a wall of text in a chip.
  @username ~r/^[A-Za-z0-9_.-]{1,64}$/

  @doc """
  What a remote account is called on screen, from the display name its server
  sent: the string with its custom-emoji shortcodes taken out, or nil when
  nothing readable is left.

  Those networks let an account put its **own server's** emoji in its name, and
  send it as a shortcode (`"Droid Boy :coolified:"`) with the picture it stands
  for in the actor document's `tag` array. That picture is that server's, and
  vutuv shows no remote picture it has not cached and put past the AI gate
  (`Vutuv.RemoteMedia`) — a name is not worth that pipeline. So the token has
  nothing to render as, and left in it reads as a literal `":coolified:"` on
  the card. Drop it; the Mastodon inline feed has made the same call since it
  shipped. The grammar lives in `Vutuv.RemoteHtml.strip_shortcodes/1`, which a
  remote post's *text* reads too — one owner, or the same server's `:blobcat:`
  would vanish from the card's name and stay in its text.

  A **name** is cleaned on the way **out**, unlike that text: it is re-derived
  from its column on every render, so the stored value stays what the server
  said and a row written before this can never be the odd one out.
  """
  def display_name(name) when is_binary(name) do
    name
    |> RemoteHtml.strip_shortcodes()
    |> String.replace(~r/\s+/u, " ")
    |> SearchText.normalize_search()
  end

  def display_name(_name), do: nil

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

  @doc """
  The handle without its server: `"@tagesschau@ard.social"` → `"@tagesschau"`.

  What a card header shows once the server is already on the card in its own
  right — the globe chip beside the name says `ard.social`, so spelling it out a
  second time in the handle only pushed the timestamp off the line. The full
  form stays the link's `title`, so it is one hover away and still copyable from
  the account page, where it is the address somebody pastes into their own
  server.

  A handle we could only derive as `@host` (no username anywhere in the actor
  document or its URI) has nothing to cut and is returned unchanged: the host is
  the name there.
  """
  def short("@" <> rest = handle) do
    case String.split(rest, "@", parts: 2) do
      [name, host] when name != "" and host != "" -> "@" <> name
      _ -> handle
    end
  end

  def short(handle), do: handle

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
