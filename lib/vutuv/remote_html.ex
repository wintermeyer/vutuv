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
    * HTML entities are decoded exactly **once** (`decode_entities/1`),
    * the sending server's own **custom-emoji shortcodes** go out with it
      (`strip_shortcodes/1`), and
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
  renderer then links to the remote profile like any typed fediverse handle —
  **including a mention of one of our own members**, whose address on our host
  the renderer now resolves to their profile (issue #1560); it used to be left
  short, because the full form was linked straight back at this server as
  `https://host/@user`, a path vutuv does not serve.
  """

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

  # A run of custom-emoji shortcodes as these networks spell them:
  # `[a-zA-Z0-9_]{2,}` between colons, one or more in a row because two adjacent
  # emoji are written `:blobcat::heart:` with no space between them.
  #
  # The delimiters are the whole point — they are what keeps a time ("10:30:45")
  # and a scheme ("daniel:// stenberg://") out of it. A **colon** is not one of
  # them, or `std::vector::size` would read as a `:vector:` emoji between two
  # colons and come out `std::size`.
  @shortcode ~r/(?<![\w:])(?::[a-zA-Z0-9_]{2,}:)+(?![\w:])/

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
    |> defuse_wide_charrefs()
    |> HtmlSanitizeEx.strip_tags()
    |> scrub_nul()
    |> decode_entities()
    |> String.trim()
    |> strip_shortcodes()
    |> expand_mentions(tags)
    |> clamp(max)
  end

  def to_text(_html, _max, _tags), do: ""

  @doc """
  `text` — already plain, not HTML — with its custom-emoji shortcodes taken out
  and the gap each one leaves closed.

  Those networks let an account put its **own server's** emoji in a post and
  send it as a shortcode (`":tux:"`), with the picture it stands for in the
  object's `tag` array. That picture is that server's, and vutuv shows no remote
  picture it has not cached and put past the AI gate, so the token has nothing
  to render as and reads on the card as a literal `":tux:"`.

  `to_text/3` applies it to everything that arrives as HTML. It is public for
  the two plain-text paths that never see any: a poll's option names
  (`Vutuv.Fediverse`) and a Mastodon status' content warning (`Vutuv.Mastodon`),
  which the REST API sends as text. Everything a remote server wrote and vutuv
  stores goes through one of those three.

  Cleaned on the way **in**, unlike a display name (`Handle.display_name/1`,
  which calls this too) — the name is re-derived from its column on every
  render, while this text *is* the column, and every reader of it would
  otherwise need the same repair. Text carrying no shortcode comes back
  untouched rather than merely unchanged: `translations.source_sha256` keys a
  cached translation to the exact string, so a cosmetic byte would re-run the
  whole stored corpus past Ollama.
  """
  def strip_shortcodes(text) when is_binary(text) do
    # One whole-text `match?` before the line pass, and `match?` rather than a
    # replace whose result is thrown away: nearly every post carries no
    # shortcode at all, and for those this is the only work done (measured: 16
    # reductions against 235 for splitting into lines and letting each line
    # answer for itself, which grows with the post).
    if Regex.match?(@shortcode, text) do
      text
      |> String.split("\n")
      |> Enum.flat_map(&strip_line/1)
      |> Enum.join("\n")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()
    else
      text
    end
  end

  defp clamp(text, nil), do: Post.truncate(text)
  defp clamp(text, max), do: Post.truncate(text, max)

  # A NUL byte is valid UTF-8 and Postgres refuses it (`22021
  # character_not_in_repertoire`), so one in here is not a display problem, it
  # is a raise on `Repo.insert` — and this text is stored: `Vutuv.Fediverse`'s
  # `remote_text/3` writes it into a delivered post's body, so any federating
  # server can reach that by putting `&#0;` in a Note.
  #
  # Its own step, and not part of `decode_entities/1`, where the same guard
  # already lives (`entity_text/2` refuses to build a NUL). That guard cannot
  # help: `strip_tags/1` decodes numeric entities **itself**, so `&#0;` is
  # already a raw byte by the time the decoder runs. A guard the pipeline steps
  # around is not a guard.
  defp scrub_nul(text), do: String.replace(text, <<0>>, "")

  # `strip_tags/1` decodes numeric character references itself, and its parser
  # builds every one it sees: `:mochiutf8.codepoint_to_bytes/1` has no clause
  # past 0x10FFFF, so `&#1114112;` does not become a replacement character, it
  # RAISES a FunctionClauseError from inside `strip_tags/1` — before
  # `scrub_nul/1` or `decode_entities/1` below can look at anything. Any
  # federating server can stop an inbound Note that way, the same reach the NUL
  # above has, and one line earlier in the pipeline.
  #
  # So the reference is defused before the parser sees it, by escaping its `&`.
  # That leaves it standing as literal text, which is exactly what mochiweb
  # already does with a lone surrogate (`&#xD800;` comes through untouched) —
  # the point is that a number nobody can render is not worth an exception.
  @wide_charref ~r/&#([xX])?0*([0-9a-fA-F]+);/
  defp defuse_wide_charrefs(html) do
    Regex.replace(@wide_charref, html, fn whole, hex, digits ->
      base = if hex == "", do: 10, else: 16

      case Integer.parse(digits, base) do
        {codepoint, ""} when codepoint > 0x10FFFF ->
          "&amp;" <> binary_part(whole, 1, byte_size(whole) - 1)

        _ ->
          whole
      end
    end)
  end

  @entity_regex ~r/&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z][a-zA-Z0-9]*);/

  # The HTML entities `strip_tags/1` leaves escaped, resolved to the text they
  # stand for. An entity nothing knows is left standing rather than swallowed.
  #
  # **One pass, not a chain of replacements.** A chain has to decode `&amp;`
  # LAST or a literal `&amp;amp;` unescapes twice, and that ordering was a rule
  # somebody had to keep obeying — it lived in a comment above the version this
  # replaced. A single pass cannot double-decode at all, because
  # `Regex.replace/3` does not re-scan what it has written.
  defp decode_entities(text) do
    Regex.replace(@entity_regex, text, fn whole, body -> entity(body, whole) end)
  end

  # `:mochiweb_charref` is the full HTML5 table, and it already ships here —
  # `:html_sanitize_ex` depends on it and `strip_tags/1` above leans on it. It
  # answers all three spellings the regex captures (`rsquo`, `#8217`, `#x2019`)
  # and `:undefined` for anything it does not know.
  #
  # What this replaced was a six-entry table typed out by hand. Measured before
  # replacing it, those six were not a gap: `strip_tags/1` resolves the whole
  # HTML5 table itself and re-escapes only the four HTML-special entities, so
  # `&rsquo;`, `&mdash;`, `&eacute;` and the rest already came through correctly,
  # and the hand-written list covered exactly what was left. The reason to use
  # the real table anyway is that nobody can tell that by reading it — the list
  # looked like an arbitrary six of two thousand — and that the chain carried an
  # ordering rule (`&amp;` last, or `&amp;amp;` unescapes twice) which lived in a
  # comment and had to keep being obeyed. One pass over the real table cannot be
  # short, and cannot be mis-ordered.
  #
  # Case matters and is not folded: `&Aacute;` is Á and `&aacute;` is á.
  defp entity(body, whole) do
    case :mochiweb_charref.charref(body) do
      :undefined -> whole
      codepoint -> entity_text(codepoint, whole)
    end
  end

  # A lone surrogate is not a codepoint `<<n::utf8>>` can build (it raises), and
  # neither is a number past the Unicode range: those stay text. `0` is refused
  # with them, for the reason `scrub_nul/1` sets out above.
  defp entity_text(number, _whole)
       when is_integer(number) and (number in 1..0xD7FF or number in 0xE000..0x10FFFF),
       do: <<number::utf8>>

  # A few entities are two codepoints (`&NotEqualTilde;` is ≂ plus a combining
  # slash); each half goes through the same guard.
  defp entity_text(numbers, whole) when is_list(numbers) do
    Enum.map_join(numbers, &entity_text(&1, whole))
  end

  defp entity_text(_number, whole), do: whole

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
         true <- linkable?(user, host) do
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

  # A line with no shortcode in it is left byte for byte alone, so the repair
  # can only ever touch the lines it emptied out.
  defp strip_line(line) do
    case String.replace(line, @shortcode, "") do
      ^line -> [line]
      stripped -> close_gap(stripped)
    end
  end

  # What the removed token leaves behind: a doubled space mid-sentence, a space
  # in front of the comma that followed it, an indent at the start of the line
  # it opened. A line that was **nothing but** emoji goes with them — the author
  # gave it a line of its own, so an empty one in its place is not what they
  # wrote either. (`strip_line/1` only calls this for a line that carried one,
  # so an empty result here always means "emoji and nothing else".)
  defp close_gap(stripped) do
    repaired =
      stripped
      |> String.replace(~r/\s+/u, " ")
      |> String.replace(~r/ +(?=[,.)\]])/u, "")
      |> String.trim()

    if repaired == "", do: [], else: [repaired]
  end
end
