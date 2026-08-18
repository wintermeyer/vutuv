defmodule Vutuv.ApiAuth.UserAgent do
  @moduledoc """
  The device a token was minted from, as a member can read it.

  The Connected apps page listed rows a member could not tell apart: a Mastodon
  client registers a **new** OAuth app per install, so several installs of the
  same app are several rows all called "Ivory", and with neither a time nor a
  device on them there was no way to pick the one to withdraw.

  Two functions, and the split matters. `capture/1` is what goes in the column:
  the client's own string, whole, because it is evidence and cutting it up at
  write time throws away what a later question might need. `label/1` is what a
  page shows: a short, honest phrase read out of that string.

  **The label never guesses.** A User-Agent is a self-declaration by a remote
  client, and one that names nothing recognisable gets `nil` — a page then says
  "unknown device", which is true, rather than a confident wrong answer built
  out of a substring that happened to match. That is also why the platform
  patterns are matched in a deliberate order: an iPad and an iPhone both say
  "like Mac OS X", and Android says "Linux".
  """

  # A client string is not ours to bound, so the column is `text` — but nothing
  # here needs more than a header's worth, and an unbounded body must not become
  # a row. Long enough for the wordiest desktop browser several times over.
  #
  # Characters, not bytes: `String.slice/3` counts graphemes, and the column is
  # `text`, so there is no byte limit for the two to disagree about.
  @max_chars 500

  @doc """
  The string to store, from a `Plug.Conn` or a raw header value.

  `nil` for a request that sent none (every HTTP client sends one, but nothing
  makes it obligatory) or an empty one, so the column says "not recorded"
  rather than "".
  """
  def capture(%Plug.Conn{} = conn) do
    conn |> Plug.Conn.get_req_header("user-agent") |> List.first() |> capture()
  end

  def capture(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_chars)
    end
  end

  def capture(_absent), do: nil

  @doc "The cap `capture/1` applies, so a test can state it rather than assume it."
  def max_chars, do: @max_chars

  @doc """
  A short device phrase for a stored string, or `nil` when nothing in it is
  recognisable.

  Deliberately coarse — the platform, not a version — because the question a
  member is answering is "which of my devices is this", and a version number
  changes under them while the answer stays the same.
  """
  def label(value) when is_binary(value) do
    Enum.find_value(platforms(), fn {pattern, label} ->
      if String.contains?(value, pattern), do: label
    end)
  end

  def label(_absent), do: nil

  # Order is load-bearing: an iPad and an iPhone both carry "like Mac OS X", so
  # the specific device has to be asked about before the desktop; and Android
  # carries "Linux", so it has to come before it.
  defp platforms do
    [
      {"iPhone", "iPhone"},
      {"iPad", "iPad"},
      {"Android", "Android"},
      {"Mac OS X", "macOS"},
      {"Macintosh", "macOS"},
      {"Windows", "Windows"},
      {"CrOS", "ChromeOS"},
      {"Linux", "Linux"},
      {"FreeBSD", "FreeBSD"}
    ]
  end
end
