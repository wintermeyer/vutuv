defmodule VutuvWeb.PostTeaser do
  @moduledoc """
  What a post says in one line: which line that is, who wrote it, and whether
  this reader may be shown it at all.

  ## Which line

  `line/2` — and its flattened twin `plain_line/2` — is the single owner of the
  app's one-line post teaser, read by the RSS `<description>`, the Open Graph
  description, a `/search` result, every agent-format doc that lists posts
  rather than rendering one, an organization's activity list, the
  /notifications breadcrumb, the operator's daily report, and `text/1` below.

  Every one of those used to pick that line for itself, which is why this half
  exists: a teaser rule is a **product** decision — what does a reader learn
  about this post in one line? — and it has to be made once, not nine times.
  Add the next exception to `@skippable` and every surface gets it.

  A body's first line is usually the right teaser. Where it is not, it is
  because the line was written for a machine rather than for a reader:

    * **`RE: <url>`** — how Mastodon and its kin spell the status a quote post
      quotes. It names that status by id, so a reader who sees only that line
      learns nothing whatsoever about what was said. The rendered card still
      shows it (it is the link to the quoted post); the teaser skips it and the
      line the author actually wrote takes its place.
    * **A line with no words in it** — a `---` rule, a lone code fence, a line
      that is nothing but inline images. Teasing a post with `![](…)` says less
      than nothing.
    * **A line that is nothing but hashtags** — the filing a post opens or
      closes with (`#Solarpunk #klimakrise #klimawandel …`). It says which
      shelf the post belongs on, never what it says.

  A post that is *nothing but* skippable lines keeps the best line it has, and
  they are not equally bad: hashtags are words a reader can read, a quoted URL
  and a horizontal rule are not. So a post whose whole body is a `RE: <url>`
  and a row of hashtags is teased with the hashtags — which is a real shape in
  the data, not a hypothetical. Below that, the first line, whatever it is: a
  URL makes a poor teaser, an empty one is worse.

  Both functions pick the **same** line — the choice is made on the source — so
  no two surfaces can quote one post differently. They differ only in how they
  present it. `line/2` keeps the post's own source form (Markdown for a
  member's post, plain text for a post or reply from another network), which is
  what a `.md` doc, an RSS description and a search result want. `plain_line/2`
  flattens it (`VutuvWeb.Markdown.to_plain_text/1`) for the surfaces that
  render no markup at all, so `**fett**` reads as `fett` rather than showing
  its markers. Only the picked line goes through the renderer, never the whole
  body.

  ## Who, and whether

  Two surfaces quote a post the reader is not looking at, and neither may drift
  from the other. The feed's source-tab ticker quotes it beside the tab it
  landed on (issue #1668); the browser tab's title teases it while the whole
  window sits behind something else (issue #1681). Both ask the same three
  questions, so all three answers live here instead of twice.

  `title_frames/1` is the browser tab's half and belongs here for the same
  reason: it cuts the quote the two surfaces share, and where it cuts is a
  decision about how a tab strip reads, not about the feed.
  """

  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse.Handle
  alias Vutuv.Fediverse.RemoteAccount
  alias Vutuv.Identity
  alias Vutuv.Mentions
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias VutuvWeb.Markdown

  # Long enough that no surface has to ask for more, short enough that a 10k
  # body never travels just to be truncated by CSS at the far end.
  @length 200

  # Lines a teaser passes over, in the order the moduledoc explains them. Each
  # matches a **whole** trimmed line: "RE: what Daniel said" is prose the author
  # wrote and stays, and so does a paragraph that merely contains a picture.
  # The angle brackets are there because a server may write the quoted URL as
  # `<https://…>`.
  @skippable [
    ~r{\ARE:\s*<?https?://\S+>?\z}i,
    ~r/\A(?:-{3,}|\*{3,}|_{3,})\z/,
    ~r/\A(?:```|~~~)/,
    ~r/\A(?:!\[[^\]]*\]\([^)]*\)\s*)+\z/
  ]

  # A line of nothing but hashtags — skipped like the rest, but the one that
  # wins the fallback in `pick/1`, because a reader gets *something* out of
  # "#Solarpunk #klimakrise" and nothing at all out of a status URL.
  #
  # The token is deliberately **narrower** than `Vutuv.Mentions`' canonical one,
  # which spans Unicode letters so that `#Thüringen` names a tag rather than
  # `#Th`. Here ASCII-only is the safe direction and stays: this regex decides
  # what to *drop*, and skipping a line the reader wanted is the expensive
  # mistake, so a line carrying `#Grüne` does not match and is kept. Widen it
  # only together with a test that says what a German hashtag line should do.
  # A Markdown heading cannot match either: `# Titel` has a space after the `#`,
  # and this demands a word character.
  @hashtags_only ~r/\A(?:#[A-Za-z0-9_]+[\s,]*)+\z/

  # How wide one browser-tab frame is written. A tab in a window holding a
  # handful of others shows roughly twenty characters of its title, and the
  # marker the hook keeps in front ("• (2) ") spends some of those, so a frame
  # is cut a little above what is certainly visible: the tail of a frame is
  # truncated, and the words after it arrive in the next one anyway.
  @frame_width 24

  # How many frames a teaser may run to. Not a taste decision — browsers clamp
  # timers in a hidden tab to about one per second, and Chrome drops a chained
  # timer to one per *minute* once the page has been hidden for five minutes
  # ("intensive throttling", Chrome 88), which is exactly the tab this feature
  # is for. Measured in headless Chrome 151, a frame asking for a second gets
  # two, so three frames plus the closing one take about eight seconds of the
  # window the browser is willing to give. Whatever stands last has to still be
  # true a minute later.
  @max_frames 3

  @doc """
  The teaser line of `post`, in its own source form, at most `:length`
  characters (200 by default).

  Takes a `%Vutuv.Posts.Post{}`, a `%Vutuv.Fediverse.RemotePost{}` or a
  `%Vutuv.Fediverse.Note{}` — the record, not its body, so no caller has to
  know which column each kind keeps its text in (`Vutuv.Posts.text/1` owns
  that). A post with nothing written on it — a photograph and no words —
  answers `""`; anything else raises rather than teasing quietly.
  """
  def line(post, opts \\ []), do: teaser(post, &fold/1, opts)

  @doc """
  `line/2` flattened to plain text: Markdown markers gone, whitespace folded to
  single spaces. For a surface that renders no markup of its own.
  """
  def plain_line(post, opts \\ [])

  def plain_line(%Post{} = post, opts), do: teaser(post, &flatten/1, opts)

  # A remote body is plain text already (`Vutuv.RemoteHtml.to_text/3` reduced it
  # at the inbox), so it must never go through the Markdown renderer: that would
  # shorten a URL the author never wrote as a link and eat a leading `1.` into a
  # list marker. Folding its whitespace is all it needs.
  def plain_line(post, opts), do: teaser(post, &fold/1, opts)

  @doc """
  The quote for one feed entry — `%{who: …, text: …}` — or nil where this
  reader has muted it.

  nil rather than a redacted line: the member silenced that word, and a teaser
  is the one place they cannot scroll past it. Both surfaces then fall back to
  the bare dot, which says *that* something landed without saying what.
  """
  def quote_for(entry, compiled, viewer_id) do
    if filtered_pattern(entry, compiled, viewer_id) do
      nil
    else
      %{who: who(entry), text: text(entry)}
    end
  end

  @doc """
  The record a feed entry is about: a remote reply, a cached remote post, or the
  vutuv post itself.

  Spelled once, because every question asked of an entry that is really a
  question about the post behind it — its id, the line to quote, what could be
  translated — used to re-derive it, and a fourth entry shape would then have to
  be remembered in each.
  """
  def record(entry) do
    cond do
      Posts.remote_reply_entry?(entry) -> entry.note
      Posts.remote_feed_entry?(entry) -> entry.remote_post
      true -> entry.post
    end
  end

  @doc """
  Which of this reader's content filters hides `entry`, or nil.

  A cached post from another network (issue #1161) is filtered on its plain
  text: the member muted a word because they do not want to read it, and where
  it was written changes nothing about that. Never the member's own posts — a
  remote post cannot reach that arm, having no author here.
  """
  def filtered_pattern(entry, compiled, viewer_id) do
    cond do
      Posts.remote_feed_entry?(entry) ->
        entry |> record() |> Posts.text() |> ContentFilters.filtered_text(compiled)

      entry.post.user_id == viewer_id ->
        nil

      true ->
        ContentFilters.filtered_pattern(entry.post, compiled)
    end
  end

  @doc """
  Who wrote it, as a name a reader recognises — or nil.

  The handle without its server (`Handle.short/1`): the surfaces quoting this
  are short of room, and the domain would take half of it. A page that never
  claimed a root handle has none to show, so it is named instead.
  """
  def who(entry) do
    cond do
      Posts.remote_reply_entry?(entry) ->
        Handle.short(Handle.display(entry.note.handle, entry.note.actor_uri))

      Posts.remote_feed_entry?(entry) ->
        Handle.short(RemoteAccount.display_handle(entry.remote_post.remote_account))

      true ->
        case Posts.author(entry.post) do
          nil -> nil
          author -> local_who(author)
        end
    end
  end

  @doc """
  How it opens: the entry's teaser line, flattened — or nil for a post with no
  text to quote (a photo without a caption), which is what lets both quoting
  surfaces fall back to the bare dot.
  """
  def text(entry) do
    case entry |> record() |> plain_line() do
      "" -> nil
      line -> line
    end
  end

  @doc """
  The quote cut into browser-tab-sized frames, at word boundaries, newest words
  last. `[]` where there is nothing to say.

  Paging beats scrolling here. Under a budget of about four frames a character
  scroll spends most of them re-showing words it already showed, while paging
  puts a fresh line in the tab each second — roughly seventy characters of the
  post against sixteen. The author leads the first frame and is not repeated:
  a reader who glances late gets the words, and the tab is the member's own, so
  the question "who is this from" is the smaller one.
  """
  def title_frames(nil), do: []

  def title_frames(%{who: who, text: text}) do
    case join(who, text) do
      "" -> []
      line -> line |> chunks(@frame_width) |> Enum.take(@max_frames)
    end
  end

  defp teaser(post, present, opts) do
    limit = Keyword.get(opts, :length, @length)

    case Posts.text(post) do
      body when is_binary(body) ->
        body
        |> lines()
        |> pick()
        # Presenting is the expensive half (a Markdown render, a Unicode
        # regex), so the line is cut to a generous multiple of the cap first:
        # neither `fold/1` nor `flatten/1` can grow a line, so nothing that
        # would have survived the final cut is lost. Without it a 10k body
        # written as one long line paid for all 10k to yield 200 characters.
        |> String.slice(0, limit * 4)
        |> present.()
        |> String.slice(0, limit)

      _no_text ->
        ""
    end
  end

  # Lazy on purpose: almost every post is teased by its first line, and this
  # walks a 10k body only as far as it has to. `String.splitter/2` is
  # re-enumerable, so `pick/1` may read it twice.
  defp lines(body) do
    body
    |> String.splitter("\n")
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
  end

  # Real prose if there is any; else the hashtags, which at least name the
  # subject; else the first line, whatever it turned out to be. `lines/1` is a
  # re-enumerable stream, so the two extra passes cost nothing on the common
  # case — they only run for a post that had no prose to find.
  defp pick(lines) do
    Enum.find(lines, &(not skippable?(&1))) ||
      Enum.find(lines, &hashtags_only?/1) ||
      Enum.at(lines, 0) || ""
  end

  defp skippable?(line),
    do: hashtags_only?(line) or Enum.any?(@skippable, &Regex.match?(&1, line))

  defp hashtags_only?(line), do: Regex.match?(@hashtags_only, line)

  defp flatten(line), do: line |> Markdown.to_plain_text() |> fold()

  # A mention of one of our accounts reads short here, as it does in the post
  # itself: `to_local_form/1` turns `@ada@vutuv.de` back into `@ada`. Every
  # teaser passes through this step, which is what makes a body from another
  # network — where naming us in full is the only spelling there is — read like
  # one of ours. A local body arrives already shortened through
  # `to_plain_text/1` and has nothing left to change.
  defp fold(line) do
    line
    |> Mentions.to_local_form()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # A page that never claimed a root handle has none to show, so it is named.
  defp local_who(author) do
    case Identity.handle(author) do
      handle when is_binary(handle) -> "@" <> handle
      _ -> Identity.display_name(author)
    end
  end

  defp join(who, text) when is_binary(who) and is_binary(text), do: who <> ": " <> text
  defp join(who, nil) when is_binary(who), do: who
  defp join(nil, text) when is_binary(text), do: text
  defp join(_who, _text), do: ""

  # Greedy word wrap. A word wider than a frame gets a frame of its own, cut
  # hard — a pasted URL must not swallow the two frames after it as well.
  defp chunks(line, width) do
    line
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.flat_map(&split_long(&1, width))
    |> wrap(width, [], [])
  end

  defp split_long(word, width) do
    if String.length(word) <= width do
      [word]
    else
      word
      |> String.graphemes()
      |> Enum.chunk_every(width)
      |> Enum.map(&Enum.join/1)
    end
  end

  defp wrap([], _width, [], done), do: Enum.reverse(done)
  defp wrap([], _width, current, done), do: Enum.reverse([finish(current) | done])

  defp wrap([word | rest], width, current, done) do
    cond do
      current == [] ->
        wrap(rest, width, [word], done)

      String.length(finish([word | current])) <= width ->
        wrap(rest, width, [word | current], done)

      true ->
        wrap([word | rest], width, [], [finish(current) | done])
    end
  end

  defp finish(current), do: current |> Enum.reverse() |> Enum.join(" ")
end
