defmodule VutuvWeb.Markdown do
  @moduledoc """
  Chat-style Markdown rendering for user-generated text (messages).

  Pipeline: `<` is escaped first, so raw HTML a user types shows up as literal
  text instead of becoming markup (and Earmark never enters its HTML-block mode,
  which would swallow the Markdown around it). Bare `http(s)://` URLs become
  Markdown links whose display text is shortened to the host and its first path
  directory — two directories for GitHub and this installation's own host, whose
  meaningful unit is two segments deep (long URLs would wreck chat bubbles);
  trailing sentence punctuation and unbalanced `)` stay outside the
  link. Earmark renders the Markdown (bold, italics, links, inline code, lists,
  quotes; newlines become `<br>`), HtmlSanitizeEx strips anything dangerous as a
  second line of defence (`javascript:` hrefs etc.), and links open in a new tab.

  **Images are always stripped**: no body embeds a picture. A post's uploaded
  images are attachments shown as a gallery (`VutuvWeb.PostComponents`), a
  message carries none, and a hotlinked remote image would leak every reader's
  IP. `Vutuv.MarkdownContent.validate_no_images/2` keeps the `![](…)` from being
  stored in the first place; `render_pipeline/1` drops any `<img>` that a body
  already carries at display time.
  """

  alias Vutuv.Accounts
  alias Vutuv.Tags
  alias VutuvWeb.UserHelpers

  @url_display_max 40
  # `…` included: remote (Mastodon) text is length-capped with a trailing
  # ellipsis that must not become part of a link target.
  @trailing_punct ~w(. , ; : ! ? …)
  @preview_limit 1000
  # When a whole block would overflow the preview, keep a word-cut of it (so a
  # one-line intro above a long block doesn't leave a one-line preview) — but
  # only if at least this many characters of budget remain, else just stop.
  @preview_min_block 200

  # A fediverse handle `@user@host.tld`, a local `@handle` mention, or a
  # `#hashtag`. The leading `@`/`#` must not sit mid-token: no email `a@b`, no
  # numeric entity `&#39;`, no `@@`/`##`, no `/path#frag` — hence the negative
  # lookbehinds. The fediverse form is tried **first**, so `@a@b.social` links
  # to the remote account instead of being mistaken for the local member `@a`;
  # its host is dot-separated alphanumeric labels ending in a TLD (a trailing
  # sentence dot stays outside). Handles/tags are matched permissively (any
  # case/length) and validated against the DB by `linkify_entities/1`: a
  # non-member, or a missing/empty tag, never links; a fediverse handle needs
  # no lookup. Captures: 1 = fediverse user, 2 = fediverse host, 3 = local
  # handle, 4 = hashtag (exactly one kind is set per hit).
  @entity ~r{(?<![\w@/])@([A-Za-z0-9_]+)@([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+)|(?<![\w@/])@([A-Za-z0-9_]+)|(?<![\w#/&])#([A-Za-z0-9_]+)}

  # Inside these elements an entity is left as plain text (a handle/hashtag in a
  # code span/block is sample text, and we never nest a link inside a link).
  @entity_skip_tags ~w(a code pre)

  @doc "Render untrusted Markdown to safe HTML (`Phoenix.HTML.safe()`)."
  def render(text) when is_binary(text) do
    text
    |> render_pipeline()
    |> open_links_in_new_tab()
    |> linkify_entities()
    |> Phoenix.HTML.raw()
  end

  def render(_), do: Phoenix.HTML.raw("")

  @doc """
  Render a post's Markdown (`Phoenix.HTML.safe()`).

  Same pipeline as `render/1`. Post **bodies never embed images**: every
  `<img>` the pipeline would produce — an author's own attachment referenced
  as `![](…)`, a hotlinked remote picture (a tracking hole: every reader's IP
  would leak to a third party), raw `<img>` HTML — is dropped or stays escaped
  text. Uploaded pictures are shown as a separate gallery by the post card
  (`VutuvWeb.PostComponents`), not inline in the prose. The `images` argument
  is kept for call-site compatibility and is ignored.
  """
  def render_post(text, _images) when is_binary(text) do
    text
    |> render_pipeline()
    |> open_links_in_new_tab()
    |> linkify_entities()
    |> Phoenix.HTML.raw()
  end

  def render_post(_, _), do: Phoenix.HTML.raw("")

  @doc """
  Render **remote** plain text — a Mastodon post reduced to text by
  `Vutuv.Mastodon.text_content/1` — with the same treatment a member post
  gets, minus what must not apply to a foreign namespace:

    * bare URLs autolink (display-truncated), Markdown formatting renders,
      everything is sanitized — the same `render_pipeline/1` as posts;
    * every `<img>` is dropped: there is no own-attachment whitelist for
      remote content, and a hotlink would leak each reader's IP;
    * `#hashtags` link to our tag pages through the same non-empty-tag gate;
    * a fully-qualified `@user@host` fediverse handle links to that remote
      account (it unambiguously names one), the same as in a member post;
    * bare `@mentions` deliberately stay plain text — a Mastodon `@name` names
      an account in the fediverse, not the vutuv member who happens to share
      the handle, so linking it would point at the wrong person.

  Returns an HTML **string** (not `safe`): the caller renders it with
  `raw/1`; it is sanitized exactly like member-post HTML.
  """
  def render_remote(text) when is_binary(text) do
    text
    |> render_pipeline()
    |> open_links_in_new_tab()
    |> linkify_entities(:hashtags_only)
  end

  def render_remote(_), do: ""

  # The shared core every renderer runs: escape raw HTML, autolink bare URLs,
  # render the Markdown, undo the double-escape, sanitize, and drop images.
  # No body — a post, a message, remote content — ever embeds a picture: post
  # attachments show as a gallery, messages carry none, and a hotlinked remote
  # image would leak every reader's IP. `MarkdownContent.validate_no_images/2`
  # stops the `![](…)` from being stored; this stops any already stored one from
  # displaying (`strip_img_tags/1` runs last, after the sanitizer emits its
  # `<img>`).
  defp render_pipeline(text) do
    text
    |> strip_break_artifacts()
    |> String.replace("<", "&lt;")
    |> autolink_bare_urls()
    |> Earmark.as_html!(breaks: true, pure_links: false)
    # Earmark escapes the ampersand of our pre-escaped `&lt;` — undo the double.
    |> String.replace("&amp;lt;", "&lt;")
    |> HtmlSanitizeEx.markdown_html()
    |> strip_img_tags()
  end

  # The Milkdown editor emits a literal `<br />` for content it has no plain
  # Markdown for: an **empty paragraph** (a blank line the writer adds with
  # Enter, serialized as a standalone `<br />` block) and an **empty table cell**
  # (`| <br /> |`). Since the pipeline escapes `<` a step below (typed HTML must
  # show as literal text), those would otherwise render as literal "<br />" text
  # in the body. Drop every `<br />` tag — an empty paragraph collapses to a
  # normal break, an empty cell stays empty — while leaving **fenced code
  # blocks** verbatim so a real `<br>` in a code sample survives. Real hard
  # breaks serialize as a trailing backslash, not `<br>`, so they are untouched.
  # The editor also normalizes this away at write time
  # (`assets/js/markdown_editor.js`); this is the rendering-side guard for
  # anything already stored or typed in source mode.
  defp strip_break_artifacts(text) do
    # Fast path: almost every body has neither a `<br>` nor a run of 3+ newlines
    # (the editor already normalizes both away at write time), so skip the fence
    # tokenization + regex passes entirely — the same cheap substring guard the
    # `linkify_entities/1` hot path uses one function over.
    if String.contains?(text, ["<br", "\n\n\n"]) do
      ~r/(```[\s\S]*?```|~~~[\s\S]*?~~~)/
      |> Regex.split(text, include_captures: true)
      |> Enum.with_index()
      |> Enum.map_join("", fn
        {chunk, index} when rem(index, 2) == 0 ->
          chunk
          |> String.replace(~r/<br\s*\/?>/i, "")
          |> String.replace(~r/\n{3,}/, "\n\n")

        {fenced_chunk, _index} ->
          fenced_chunk
      end)
    else
      text
    end
  end

  @doc """
  Render a feed preview: the Markdown source is cut at a block boundary
  around `:limit` (default #{@preview_limit}) characters — never inside a
  fenced code block — then rendered like `render_post/2`. Returns
  `{safe_html, truncated?}`; pair the flag with a "Read more" link and a
  CSS line-clamp for visual consistency.
  """
  def render_preview(text, images, opts \\ [])

  def render_preview(text, images, opts) when is_binary(text) do
    limit = Keyword.get(opts, :limit, @preview_limit)
    {snippet, truncated?} = truncate_markdown(text, limit)
    {render_post(snippet, images), truncated?}
  end

  def render_preview(_, _images, _opts), do: {Phoenix.HTML.raw(""), false}

  # Bare URLs become `[truncated-display](url)`. The lookbehind skips URLs that
  # are already the target of a Markdown link (`](http…`).
  defp autolink_bare_urls(text) do
    Regex.replace(~r{(?<!\]\()(?<![\w/])(https?://[^\s<>]+)}, text, fn _, raw ->
      {url, trailing} = split_trailing_punct(raw)
      "[#{truncate_url(url)}](#{url})#{trailing}"
    end)
  end

  # "…wiki/Elixir_(programming_language)), see!" — sentence punctuation and any
  # `)` beyond the balanced ones belong to the sentence, not the URL.
  defp split_trailing_punct(url) do
    last = String.last(url)

    cond do
      last in @trailing_punct ->
        {u, t} = url |> String.slice(0..-2//1) |> split_trailing_punct()
        {u, t <> last}

      last == ")" and closes_more_than_opens?(url) ->
        {u, t} = url |> String.slice(0..-2//1) |> split_trailing_punct()
        {u, t <> last}

      true ->
        {url, ""}
    end
  end

  defp closes_more_than_opens?(url) do
    graphemes = String.graphemes(url)
    Enum.count(graphemes, &(&1 == ")")) > Enum.count(graphemes, &(&1 == "("))
  end

  # Scheme-less, www-less display text for a bare URL, shortened to the host
  # plus its leading path directory (or **two** directories for the hosts in
  # `keep_two_dirs?/1`) — any deeper path is collapsed into a trailing `…`. So a
  # long "https://www.hostsharing.net/downloads/hostsharing-manual.pdf" reads as
  # "hostsharing.net/downloads/…" instead of a mid-word character cut.
  # `@url_display_max` stays a final safety cap for a pathologically long host
  # or first segment (or a query string on a single-segment path).
  defp truncate_url(url) do
    url
    |> strip_url_scheme()
    |> String.replace_prefix("www.", "")
    |> shorten_url_display()
    |> cap_url_display()
  end

  defp strip_url_scheme(url) do
    url
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
  end

  # host + its leading path directory (two for `keep_two_dirs?/1` hosts),
  # eliding anything deeper. A bare host — or one with only a trailing slash or
  # fewer directories than the kept count — keeps its full text; the `…` appears
  # only when there is a further path segment to hide.
  defp shorten_url_display(display) do
    host = display |> String.split("/", parts: 2) |> hd()
    elide_path(display, if(keep_two_dirs?(host), do: 2, else: 1))
  end

  # Hosts whose display keeps TWO leading path directories, because their
  # meaningful unit is two segments deep: GitHub (`/:owner/:repo`) and this
  # installation's own host (a vutuv profile section is `/:slug/<section>`, so
  # the section — `/tags`, `/work_experiences` — is worth showing). Every other
  # host still collapses after the first directory. `www.` is stripped from both
  # the display host (in `truncate_url/1`) and the endpoint host so the two
  # forms compare equal, and the own host is derived from the endpoint rather
  # than a literal `vutuv.de`, so it is correct on any third-party installation.
  @two_dir_hosts ~w(github.com)

  defp keep_two_dirs?(host) do
    host in @two_dir_hosts or host == own_host()
  end

  defp own_host, do: String.replace_prefix(VutuvWeb.Endpoint.host(), "www.", "")

  # Keep the host plus up to `keep` leading path directories; a deeper, non-empty
  # segment collapses into a trailing `/…`. A lone trailing slash (or any empty
  # deeper segment) is ignored, so it never adds a spurious `…`.
  defp elide_path(display, keep) do
    [host | rest] = String.split(display, "/")
    {shown, deeper} = Enum.split(rest, keep)
    path = Enum.join([host | Enum.reject(shown, &(&1 == ""))], "/")

    if Enum.any?(deeper, &(&1 != "")), do: path <> "/…", else: path
  end

  defp cap_url_display(display) do
    if String.length(display) > @url_display_max do
      String.slice(display, 0, @url_display_max - 1) <> "…"
    else
      display
    end
  end

  # Safe to do post-sanitization: every remaining <a> came out of the scrubber.
  defp open_links_in_new_tab(html) do
    String.replace(html, "<a href", ~s(<a target="_blank" rel="noopener noreferrer" href))
  end

  ## @handle / fediverse mentions and #hashtags

  # Turns every `@handle` of an existing member into a same-tab link to their
  # profile (name in a `title` hover tooltip), every fully-qualified
  # `@user@host` fediverse handle into a **new-tab** link to that remote
  # account, and every `#hashtag` of a non-empty tag into a link to its
  # `/tags/:slug` page. Runs on the already-rendered, sanitized HTML (after
  # `open_links_in_new_tab/1`, so the internal member/tag links stay same-tab
  # while the fediverse link sets its own `target="_blank"`), and only on text
  # that is **not** inside a `code`/`pre`/`a` element — an entity typed in code
  # is sample text and we never nest a link in a link.
  #
  # Each body resolves its handles and its hashtags in **one** DB query each;
  # a body with no `@`/`#` at all does no work (so the pure, DB-free unit tests
  # in `markdown_test.exs` keep working without a sandbox).
  defp linkify_entities(html, mode \\ :all) do
    # Cheap bail-out for the common case: no `@`/`#` means no entity to link,
    # so the feed hot path skips tokenizing and scanning entirely.
    if String.contains?(html, "@") or String.contains?(html, "#") do
      linkify_present_entities(html, mode)
    else
      html
    end
  end

  defp linkify_present_entities(html, mode) do
    tokens = tokenize_html(html)

    case entity_candidates(tokens) do
      {[], [], false} ->
        html

      {mentions, hashtags, _fediverse?} ->
        # With an empty user map every mention falls through as plain text
        # (`mention_link/3`), which is exactly what :hashtags_only wants. A body
        # carrying only fediverse handles still reaches here (they need no
        # lookup, so both `mentions` and `hashtags` stay empty) and gets linked.
        users =
          if mode == :all, do: Accounts.get_users_by_usernames(mentions), else: %{}

        tags = Tags.linkable_slugs(hashtags)

        tokens
        |> map_linkable_text(&link_entities_in_text(&1, users, tags))
        |> IO.iodata_to_binary()
    end
  end

  # Splits HTML into alternating text / tag tokens (tags kept as their own
  # tokens), so a tag-depth walk can tell text apart from markup.
  defp tokenize_html(html), do: Regex.split(~r/<[^>]+>/, html, include_captures: true)

  # The unique, lowercased {handles, hashtags} sitting in linkable text.
  defp entity_candidates(tokens) do
    {mentions, hashtags, fediverse?} =
      reduce_linkable_text(tokens, {[], [], false}, fn text, acc ->
        @entity
        |> Regex.scan(text, capture: :all_but_first)
        |> Enum.reduce(acc, &collect_candidate/2)
      end)

    {Enum.uniq(mentions), Enum.uniq(hashtags), fediverse?}
  end

  # `Regex.scan` truncates trailing unmatched groups, so each hit arrives at a
  # different length: a fediverse handle as `["user", "host"]`, a mention as
  # `["", "", "handle"]`, a hashtag as `["", "", "", "hashtag"]`. Dispatch on
  # which group is set. A fediverse handle needs no DB lookup, so it only raises
  # the `fediverse?` flag — that keeps the token walk from being skipped for a
  # body whose only entities are fediverse handles.
  defp collect_candidate([user, host | _], {mentions, hashtags, _fediverse?})
       when user != "" and host != "",
       do: {mentions, hashtags, true}

  defp collect_candidate([_, _, handle | _], {mentions, hashtags, fediverse?})
       when handle != "",
       do: {[String.downcase(handle) | mentions], hashtags, fediverse?}

  defp collect_candidate([_, _, _, hashtag], {mentions, hashtags, fediverse?}),
    do: {mentions, [String.downcase(hashtag) | hashtags], fediverse?}

  # Walks the token stream, applying `fun` to every text token outside a
  # skip element and leaving tags and skipped text untouched.
  defp map_linkable_text(tokens, fun) do
    {mapped, _depth} =
      Enum.map_reduce(tokens, 0, fn token, depth ->
        cond do
          tag_token?(token) -> {token, entity_skip_depth(depth, token)}
          depth > 0 -> {token, depth}
          true -> {fun.(token), depth}
        end
      end)

    mapped
  end

  # Folds `fun` over every text token outside a skip element.
  defp reduce_linkable_text(tokens, acc, fun) do
    {acc, _depth} =
      Enum.reduce(tokens, {acc, 0}, fn token, {acc, depth} ->
        cond do
          tag_token?(token) -> {acc, entity_skip_depth(depth, token)}
          depth > 0 -> {acc, depth}
          true -> {fun.(token, acc), depth}
        end
      end)

    acc
  end

  defp tag_token?(token), do: String.starts_with?(token, "<")

  # Tracks how deeply nested we are inside skip elements (a/code/pre).
  defp entity_skip_depth(depth, tag) do
    case Regex.run(~r{^<\s*(/?)\s*([a-zA-Z0-9]+)}, tag) do
      [_, "/", name] -> if skip_tag?(name), do: max(depth - 1, 0), else: depth
      [_, "", name] -> if skip_tag?(name), do: depth + 1, else: depth
      _ -> depth
    end
  end

  defp skip_tag?(name), do: String.downcase(name) in @entity_skip_tags

  defp link_entities_in_text(text, users, tags) do
    Regex.replace(@entity, text, fn
      _whole, user, host, "", "" -> fediverse_link(user, host)
      whole, "", "", handle, "" -> mention_link(whole, handle, users)
      whole, "", "", "", hashtag -> hashtag_link(whole, hashtag, tags)
    end)
  end

  # A fediverse handle `@user@host` links to that remote account's profile at
  # the Mastodon-web convention `https://host/@user` (geno.social and the vast
  # majority of servers). This is a pure string mapping — no WebFinger lookup —
  # so it also works on air-gapped installs and never leaks a reader's request
  # to the remote host at render time. The host is lowercased (hostnames are
  # case-insensitive); the typed user case is kept in both the URL and the
  # label. Opens in a new tab like other external links; both parts are a
  # validated charset (`[A-Za-z0-9_]` / `[A-Za-z0-9.-]`), so no escaping needed.
  defp fediverse_link(user, host) do
    href = "https://#{String.downcase(host)}/@#{user}"

    ~s(<a href="#{href}" target="_blank" rel="noopener noreferrer" class="mention">@#{user}@#{host}</a>)
  end

  defp mention_link(whole, handle, users) do
    case Map.get(users, String.downcase(handle)) do
      nil -> whole
      user -> mention_anchor(user, handle)
    end
  end

  defp hashtag_link(whole, hashtag, tags) do
    slug = String.downcase(hashtag)
    if MapSet.member?(tags, slug), do: hashtag_anchor(slug, hashtag), else: whole
  end

  # The display text is the handle the author typed (case preserved); the href
  # is the canonical lowercase slug; the title is the member's full name (or the
  # handle itself for a nameless member).
  defp mention_anchor(user, typed_handle) do
    name =
      case UserHelpers.full_name(user) do
        "" -> "@" <> user.username
        full -> full
      end

    ~s(<a href="/#{user.username}" title="#{escape(name)}" class="mention">@#{typed_handle}</a>)
  end

  # The display text is the hashtag the author typed (case preserved); the href
  # is the canonical lowercase tag slug. Only non-empty tags reach here, so the
  # link never lands on a tag page with nothing on it. Both parts are from a
  # validated charset (`[a-z0-9-]` slug, `[A-Za-z0-9_]` typed), so no escaping.
  defp hashtag_anchor(slug, typed_hashtag) do
    ~s(<a href="/tags/#{slug}" class="hashtag">##{typed_hashtag}</a>)
  end

  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  # Post bodies never embed images and remote content never hotlinks one, so
  # every <img> the Markdown pipeline produces is dropped.
  defp strip_img_tags(html) do
    String.replace(html, ~r/<img\b[^>]*>/i, "")
  end

  ## Preview truncation

  # Cuts Markdown source at a block boundary near `limit` chars. Blocks are
  # blank-line separated, except inside fenced code blocks (``` / ~~~), which
  # stay atomic — cutting a fence in half breaks the rendering of everything
  # after it. A single overlong non-fence first block is word-cut instead.
  defp truncate_markdown(text, limit) do
    if String.length(text) <= limit do
      {text, false}
    else
      [first | rest] = split_blocks(text)

      first =
        if String.length(first) > limit and not fence_block?(first) do
          word_cut(first, limit)
        else
          first
        end

      {accumulate_blocks(rest, [first], String.length(first), limit), true}
    end
  end

  defp accumulate_blocks([], kept, _length, _limit), do: join_blocks(kept)

  defp accumulate_blocks([block | rest], kept, length, limit) do
    new_length = length + 2 + String.length(block)
    remaining = limit - length - 2

    cond do
      new_length <= limit ->
        accumulate_blocks(rest, [block | kept], new_length, limit)

      # Near-full already: stop. There is plenty above for the CSS clamp.
      remaining < @preview_min_block ->
        join_blocks(kept)

      # The next whole block overflows but there is room. Don't drop it — that is
      # what left a one-line intro stranded above a long list. A fence is atomic
      # (cutting it breaks rendering everything after), so include it whole and
      # let the CSS line-clamp trim it; any other block is word-cut to the budget.
      fence_block?(block) ->
        join_blocks([block | kept])

      true ->
        join_blocks([word_cut(block, remaining) | kept])
    end
  end

  defp join_blocks(kept), do: kept |> Enum.reverse() |> Enum.join("\n\n")

  # Splits into blank-line separated blocks, treating fenced code as atomic:
  # a blank line inside an open fence does not end the block.
  defp split_blocks(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({[], [], false}, &collect_block_line/2)
    |> then(fn {blocks, current, _in_fence} ->
      blocks = if current == [], do: blocks, else: [Enum.reverse(current) | blocks]

      blocks
      |> Enum.reverse()
      |> Enum.map(&Enum.join(&1, "\n"))
    end)
  end

  defp collect_block_line(line, {blocks, current, in_fence}) do
    in_fence = if fence_delimiter?(line), do: not in_fence, else: in_fence

    cond do
      String.trim(line) != "" or in_fence -> {blocks, [line | current], in_fence}
      current == [] -> {blocks, [], in_fence}
      true -> {[Enum.reverse(current) | blocks], [], in_fence}
    end
  end

  defp fence_delimiter?(line), do: Regex.match?(~r/^\s*(```|~~~)/, line)

  defp fence_block?(block) do
    block |> String.trim_leading() |> String.starts_with?(["```", "~~~"])
  end

  defp word_cut(text, limit) do
    cut =
      text
      |> String.slice(0, limit)
      # Drop the (likely cut-through) last word so the cut lands on a boundary.
      |> String.replace(~r/\S*\z/, "")
      |> String.trim_trailing()

    cut <> " …"
  end
end
