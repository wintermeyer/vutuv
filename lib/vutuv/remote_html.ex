defmodule Vutuv.RemoteHtml do
  @moduledoc """
  The one place where HTML written by a *remote* server becomes something vutuv
  is willing to store and show: plain text.

  Two callers, one rule. `Vutuv.Mastodon` reduces the statuses of a member's own
  linked account for their profile feed, and `Vutuv.Fediverse` reduces the posts
  and replies other networks deliver (issues #1069, #1161). Both hold text an
  attacker controls, and neither has any use for the remote markup, so the
  answer to "how do we sanitise this safely" is to not keep HTML at all:

    * `<script>` and `<style>` elements go **with their contents**,
    * `<br>` and `</p>` become the line breaks that carried the meaning,
    * every remaining tag is stripped (`HtmlSanitizeEx.strip_tags/1`), so there
      is no allowlist to get wrong and nothing to render `raw`,
    * the base entities are decoded exactly **once**, and
    * the result is clamped, so one hostile delivery cannot park a novel.

  The script/style pass matters because `strip_tags/1` removes the *tags* and
  keeps the *text between them*: without it `<script>alert(1)</script>Hallo`
  reduces to the literal `alert(1)Hallo`. That was never an execution risk (the
  output is escaped again on the way to the page), but it let a remote server
  push arbitrary invisible text into a member's profile feed, and it would have
  put the same junk into a stored reply.

  What comes out is plain text that HEEx escapes again on the way to the page,
  and that the agent-format siblings can carry unchanged. Links survive as bare
  URLs, which `VutuvWeb.Markdown` linkifies anyway — including the `@user@host`
  handles of those networks, which it maps to the right remote profile.

  **Mentions** need one repair on the way through: those networks render a
  mention as the bare `@user` short form, while the full address that names the
  account lives only in the anchor the strip throws away — and in the object's
  `tag` array. Stripped naively, `@herrkaschke` is just a word, and the renderer
  deliberately leaves a bare `@name` in remote content unlinked (it would point
  at whatever vutuv member shares the handle). So `to_text/3` takes those
  `Mention` tags and widens each short form to the full `@user@host`, which the
  renderer then links to the remote profile like any typed fediverse handle.
  """

  alias Vutuv.Fediverse
  alias Vutuv.Mentions
  alias Vutuv.SocialFeed.Post

  # The bare `@user` short form a remote server renders a mention as. The
  # boundaries mirror the shared entity grammar (`Vutuv.Mentions`): not
  # mid-token (no email `a@b`, no URL `/@user`), and not the first half of an
  # already-full `@user@host`.
  @short_mention ~r{(?<![A-Za-z0-9_@/])@([A-Za-z0-9_]+)(?![A-Za-z0-9_@])}

  # A hostile server could park thousands of Mention tags on one delivery;
  # nothing real mentions more than a handful.
  @max_mention_tags 50

  @doc """
  Reduces a remote server's HTML to clamped plain text, at most `max`
  characters (the shared social-feed clamp by default).

  `tags` is the object's ActivityPub `tag` value (or the REST `mentions` list
  normalized to that shape): each `Mention` in it widens the bare `@user` the
  content shows to the full `@user@host` the renderer can link. Expansion runs
  before the clamp, so the cap bounds the stored result either way.
  """
  def to_text(html, max \\ nil, tags \\ [])

  def to_text(html, max, tags) when is_binary(html) do
    html
    |> String.replace(~r{<(script|style)\b[^>]*>.*?</\1\s*>}is, "")
    # An element left open runs to the end of the document by definition, so
    # there is nothing after it worth keeping either.
    |> String.replace(~r{<(script|style)\b[^>]*>.*}is, "")
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{</p>}i, "\n\n")
    |> HtmlSanitizeEx.strip_tags()
    |> decode_entities()
    |> String.trim()
    |> expand_mentions(tags)
    |> clamp(max)
  end

  def to_text(_html, _max, _tags), do: ""

  defp clamp(text, nil), do: Post.truncate(text)
  defp clamp(text, max), do: Post.truncate(text, max)

  # strip_tags/1 returns text with the base named entities still escaped (the
  # numeric ones it decodes itself); undo them exactly once. `&amp;` must come
  # last so a literal "&amp;amp;" cannot double-unescape.
  defp decode_entities(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
  end

  defp expand_mentions(text, tags) do
    map = mention_map(tags)

    if map_size(map) == 0 or not String.contains?(text, "@") do
      text
    else
      Regex.replace(@short_mention, text, fn whole, user ->
        Map.get(map, String.downcase(user), whole)
      end)
    end
  end

  # short form (downcased) => the one full `@user@host` it names.
  defp mention_map(tags) do
    tags
    |> List.wrap()
    |> Enum.take(@max_mention_tags)
    |> Enum.flat_map(&mention_handle/1)
    |> Enum.group_by(fn {user, _host} -> String.downcase(user) end)
    |> Enum.flat_map(&expansion/1)
    |> Map.new()
  end

  # Two mentioned accounts sharing a short name are indistinguishable in the
  # stripped text, so neither is expanded — never guess which the author meant.
  defp expansion({short, pairs}) do
    case Enum.uniq_by(pairs, fn {_user, host} -> host end) do
      [{user, host}] -> [{short, "@#{user}@#{host}"}]
      _ambiguous -> []
    end
  end

  defp mention_handle(%{"type" => "Mention", "name" => name, "href" => href})
       when is_binary(name) and is_binary(href) do
    with {user, host} <- split_mention(name, href),
         true <- linkable?(user, host),
         # A mention of an account on this very installation stays short: the
         # renderer would link the full form straight back at this server
         # (`https://host/@user`), which is not a page vutuv serves.
         false <- Fediverse.local_host?(host) do
      [{user, host}]
    else
      _ -> []
    end
  end

  defp mention_handle(_tag), do: []

  # `name` carries the full `user@host` for a cross-server mention and only the
  # bare user for a same-server one, where the host comes from the href.
  defp split_mention(name, href) do
    case name |> String.trim() |> String.trim_leading("@") |> String.split("@") do
      [user, host] when user != "" and host != "" ->
        {user, String.downcase(host)}

      [user] when user != "" ->
        case href_host(href) do
          nil -> :error
          host -> {user, host}
        end

      _ ->
        :error
    end
  end

  defp href_host(href) do
    case URI.parse(href) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.downcase(host)

      _ ->
        nil
    end
  end

  # Only an expansion the renderer will actually link is worth writing into the
  # text: the full handle must match the shared entity grammar as one whole
  # fediverse handle (which also validates both charsets — a dotted Misskey
  # user name, say, would come out a plain word plus a broken half-link).
  defp linkable?(user, host) do
    handle = "@#{user}@#{host}"

    case Regex.run(Mentions.entity_regex(), handle) do
      [^handle, u, h | _] -> u != "" and h != ""
      _ -> false
    end
  end
end
