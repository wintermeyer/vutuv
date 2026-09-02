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
  handles of those networks, which it maps to the right remote profile. That
  they survive is the repair below, though, not a property of the strip: the
  strip keeps a link's *label* and drops the address with the tag.

  Two things need a repair on the way through, and it is the same repair twice:
  what names the thing is in the anchor the strip throws away. A **link** keeps
  its address that way (`restore_cut_links/1`) — some servers show only a
  cut-short rendering of it.

  **Mentions** need the other: those networks render a
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

  # This reads a stranger's document, so both runs are **bounded** and so is what
  # reaches them — the same reasoning as `@anchor` below, which was bounded for
  # exactly this and left these two alone.
  #
  # Same shape as `@anchor` below, on the element that carries a body: many
  # opens and no close, so every one expands its lazy run to the end of the
  # subject before failing. Measured on 720 KB of that, **232 s** unbounded —
  # and the inbox reduces content synchronously, before its 202, so that is one
  # request holding a process for four minutes inside a 300/hour per-IP budget.
  #
  # **The run bound is what fixes it**, and its tightness is the whole lever:
  # 200 KB costs 8.9 s at 65535 against 525 ms at 4096. The input clamp is worth
  # its line on top (100 KB x 4096 measures ~530 ms), but its real job is the
  # rest of the pipeline — every *other* regex below reads whatever arrives, and
  # this is the only place that bounds them. The attribute run gets the same
  # treatment for the same reason, at a length no real tag approaches.
  #
  # 100 KB is ten times the 10,000-character content cap the callers pass
  # (`Note.max_content/0`, `RemotePost.max_content/0`) — a 10,000-character
  # status is about 10,000 bytes of Mastodon HTML even with a mention on every
  # line — and an ordinary status costs the same either way (~450 us on a
  # deliberately huge 39 KB one).
  @max_input 100_000
  @script_body 4_096

  @script_pair ~r/<(script|style)\b[^>]{0,1024}>.{0,#{@script_body}}?<\/\1\s*>/is
  @script_open ~r/<(script|style)\b[^>]{0,1024}>.*/is

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
    |> clamp_input()
    |> String.replace(@script_pair, "")
    # An element left open runs to the end of the document by definition, so
    # there is nothing after it worth keeping either. A body longer than
    # `@script_body` counts as open for the same reason: nothing after it is
    # worth the cost of finding out.
    |> String.replace(@script_open, "")
    |> restore_cut_links()
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

  # BYTES, because that is what bounds the work: the patterns below carry no
  # `u` flag, so `@script_body` counts bytes too, and `String.slice/3` would
  # count graphemes — which on a body of combining marks let four times the cap
  # through to every regex in the chain. `String.byte_slice/3` cuts on a
  # codepoint boundary, so the result stays valid UTF-8.
  #
  # The guard is not a micro-optimisation but the common case: a status is a few
  # hundred bytes, and slicing allocates a copy of the whole body whether or not
  # anything is cut (0.005 us against 0.234 us on a typical one). UTF-8 never
  # spends fewer bytes than characters, so under the byte cap nothing can need
  # cutting.
  defp clamp_input(html) when byte_size(html) <= @max_input, do: html
  defp clamp_input(html), do: String.byte_slice(html, 0, @max_input)

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

  # An anchor as these servers write one: the opening tag's attributes, then the
  # label up to its own `</a>` (anchors never nest, so the lazy run stops
  # there). Both runs are **bounded** because this reads a stranger's document,
  # and an unbounded one costs the rest of that document for every `<a` it then
  # fails on. The shape that hurts is a body of `<a x>` with no `</a>` in it at
  # all, where every one of them pays the label bound: measured over a megabyte
  # of that, 2.3 s unbounded, 0.6 s at 256 characters. A cut label is a few
  # dozen characters (`codeberg.org/superseriousbusin…` is 31), so 256 is eight
  # times what one needs, and an anchor past either bound is simply left to the
  # strip — which is what happened to every anchor before this.
  @anchor ~r/<a\s([^>]{0,1024})>(.{0,256}?)<\/a\s*>/is

  # The `href` of that opening tag. A URL carrying a quote is not one this
  # rewrites (`link_url?/1` refuses it), so one character class covers both
  # spellings.
  @href ~r/\bhref\s*=\s*["']([^"']*)["']/i

  # A label the server cut short, and what it cut it down to: everything before
  # a closing ellipsis or three dots. Requiring a non-empty prefix is what makes
  # a label of nothing but the marker no candidate.
  @cut_marker ~r/\A(.+?)(?:…|\.\.\.)\s*\z/us

  # The same marker anywhere in the document — the necessary condition for any
  # anchor in it being a cut one, asked once instead of per anchor. A literal
  # `…` and `...` only: a server that spells it `&hellip;` is not one this has
  # seen, and the marker above would not read it either, so the two agree.
  @cut_gate ~r/…|\.\.\./

  # Those servers render a link as the full address in the `href` plus a
  # **shortened** label, and the strip below keeps the label and throws the
  # `href` away. Mastodon survives that: it hides the ends of the URL in
  # `<span class="invisible">` rather than cutting them, so the strip
  # reassembles the whole address by itself — which is why this went unnoticed
  # for as long as it did. Friendica really cuts, and what was left of
  # `https://github.com/mastodon/mastodon/issues` on the card was
  # `github.com/mastodon/mastodon/i…`: no scheme, no tail, so the renderer had
  # nothing it could link and the reader nothing they could copy.
  #
  # So an anchor whose label is that server's own cut rendering of its address
  # gives way to the address. The cut is what says so: without it, a prose label
  # that happens to open like its own link ("mastodon" over a mastodon.social
  # URL) would be replaced by a URL the author never wrote. A `@user` mention
  # and a `#hashtag` are anchors too and the same test leaves them alone — their
  # labels are no prefix of their hrefs, and the label is exactly what the
  # renderer wants from them.
  #
  # The anchor, and not the object's `tag` array `expand_mentions/2` reads: a
  # `Link` tag (where a server sends one at all — Mastodon does not) says which
  # addresses a post holds, never which cut label belongs to which, and pairing
  # them up again would be this prefix test with the markup taken away.
  #
  # The gate asks for the **cut marker**, not for an anchor: those networks
  # render every mention, every hashtag and every URL as an anchor, so almost no
  # real post would skip a gate on `<a`, while almost every one skips this. A
  # label with no marker in it cannot be a cut rendering, so nothing that would
  # have been rewritten is missed — a `...` split across tags inside a label is
  # the one shape it would, and no server writes that. It is worth the line:
  # measured on an ordinary Mastodon status, five anchors that are all mentions,
  # hashtags and invisible-span URLs cost 17 µs to prove uninteresting and 1 µs
  # to skip; over a hostile megabyte of `<a x>`, 2.3 s against 0.5 ms.
  defp restore_cut_links(html) do
    if Regex.match?(@cut_gate, html) do
      Regex.replace(@anchor, html, &restore_one_link/3)
    else
      html
    end
  end

  # One anchor: its address if the three questions above answer yes, and
  # otherwise the anchor exactly as it stood, for the strip to deal with.
  defp restore_one_link(whole, attrs, label) do
    with [href] <- Regex.run(@href, attrs, capture: :all_but_first),
         true <- link_url?(href),
         true <- cut_rendering?(label, href) do
      href
    else
      _ -> whole
    end
  end

  # Only an ordinary web address is ever written into a post body: a
  # `javascript:` or `data:` href has no business there. Whitespace and angle
  # brackets are refused for a second reason — this address becomes *text*, and
  # the renderer's autolinker reads it back by exactly those boundaries.
  # `@anchor`'s bounded attribute run already keeps it well inside the 2 KB
  # `Vutuv.Fediverse.RemotePost` allows a remote URI.
  defp link_url?(href) do
    Regex.match?(~r{\Ahttps?://[^\s<>]+\z}i, href)
  end

  # The label with its inner markup taken out — Mastodon wraps parts of a URL in
  # `<span>`s, and those spans are not the reader's text. Done with a plain
  # regex rather than `HtmlSanitizeEx.strip_tags/1`, which cannot be called this
  # early: `defuse_wide_charrefs/1` has not run yet, and a `&#1114112;` in the
  # label would raise inside it (see there).
  defp cut_rendering?(label, href) do
    text = label |> String.replace(~r{<[^>]*>}, "") |> String.trim()

    case Regex.run(@cut_marker, text) do
      [_, cut] -> String.starts_with?(display_form(href), display_form(cut))
      nil -> false
    end
  end

  @doc """
  What a server *shows* of an address: no scheme, no `www.`, no trailing slash.

  Written for comparing a cut anchor label against its own `href` (neither is in
  the other's form as it stands), and public because it is also how an address
  is written when a **reader** is meant to check where a link goes — the account
  card's way out (`VutuvWeb.RemoteActorCardHTML.origin_address/1`) reduces an
  actor URI with it before cutting it to the card's width.

  The scheme goes by a case-insensitive match on purpose (a remote server may
  well write `HTTPS://`), which is also why `Vutuv.WebVerification.normalize_url/1`
  cannot serve here: it works on a parsed `%URI{}`, and a cut label does not
  parse as one.
  """
  def display_form(url) do
    url
    |> String.replace(~r{\Ahttps?://}i, "")
    |> String.replace_prefix("www.", "")
    |> String.trim_trailing("/")
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
