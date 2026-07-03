defmodule VutuvWeb.Markdown do
  @moduledoc """
  Chat-style Markdown rendering for user-generated text (messages).

  Pipeline: `<` is escaped first, so raw HTML a user types shows up as literal
  text instead of becoming markup (and Earmark never enters its HTML-block mode,
  which would swallow the Markdown around it). Bare `http(s)://` URLs become
  Markdown links whose display text is truncated (long URLs would wreck chat
  bubbles); trailing sentence punctuation and unbalanced `)` stay outside the
  link. Earmark renders the Markdown (bold, italics, links, inline code, lists,
  quotes; newlines become `<br>`), HtmlSanitizeEx strips anything dangerous as a
  second line of defence (`javascript:` hrefs etc.), and links open in a new tab.
  """

  alias Vutuv.Accounts
  alias Vutuv.Posts.PostImage
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
  @inline_image ~r/!\[([^\]]*)\]\(([^)\s]+)\)/

  # A `@handle` mention or a `#hashtag`. The leading `@`/`#` must not sit
  # mid-token: no email `a@b`, no numeric entity `&#39;`, no `@@`/`##`, no
  # `/path#frag` — hence the negative lookbehinds. The name is matched
  # permissively (any case/length) and validated against the DB by
  # `linkify_entities/1`: a non-member, or a missing/empty tag, never links.
  # Capture 1 = handle, capture 2 = hashtag (exactly one matches per hit).
  @entity ~r{(?<![\w@/])@([A-Za-z0-9_]+)|(?<![\w#/&])#([A-Za-z0-9_]+)}

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

  Same pipeline as `render/1`, plus inline images: `![alt](url)` renders as
  an `<img>` **only** when `url` is a served version of one of the post's
  own attachments (`images`). Everything else that would become an image —
  hotlinked remote pictures (a tracking hole: every reader's IP would leak
  to a third party), other posts' attachments, raw HTML — is dropped or
  stays escaped text. An empty Markdown alt is filled from the attachment's
  stored alt text.

  Mechanics: allowed references are swapped for unguessable plain-text
  markers *before* rendering, every `<img>` the pipeline produces is
  stripped *after* sanitizing, and the markers are then replaced with
  `<img>` tags built here from known-safe parts.
  """
  def render_post(text, images) when is_binary(text) and is_list(images) do
    {prepared, replacements} = extract_inline_images(text, images)

    prepared
    |> render_pipeline()
    |> strip_img_tags()
    |> open_links_in_new_tab()
    |> linkify_entities()
    |> inject_inline_images(replacements)
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
    * `@mentions` deliberately stay plain text — a Mastodon `@name` names an
      account in the fediverse, not the vutuv member who happens to share
      the handle, so linking it would point at the wrong person.

  Returns an HTML **string** (not `safe`): the caller renders it with
  `raw/1`; it is sanitized exactly like member-post HTML.
  """
  def render_remote(text) when is_binary(text) do
    text
    |> render_pipeline()
    |> strip_img_tags()
    |> open_links_in_new_tab()
    |> linkify_entities(:hashtags_only)
  end

  def render_remote(_), do: ""

  # The shared core both renderers run: escape raw HTML, autolink bare URLs,
  # render the Markdown, undo the double-escape, sanitize.
  defp render_pipeline(text) do
    text
    |> String.replace("<", "&lt;")
    |> autolink_bare_urls()
    |> Earmark.as_html!(breaks: true, pure_links: false)
    # Earmark escapes the ampersand of our pre-escaped `&lt;` — undo the double.
    |> String.replace("&amp;lt;", "&lt;")
    |> HtmlSanitizeEx.markdown_html()
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

  # Scheme-less display text for a URL, truncated to @url_display_max chars.
  defp truncate_url(url) do
    display =
      url
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("http://", "")

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

  ## @handle mentions and #hashtags

  # Turns every `@handle` of an existing member into a same-tab link to their
  # profile (name in a `title` hover tooltip), and every `#hashtag` of a
  # non-empty tag into a link to its `/tags/:slug` page. Runs on the
  # already-rendered, sanitized HTML (after `open_links_in_new_tab/1`, so these
  # internal links don't get `target="_blank"`), and only on text that is
  # **not** inside a `code`/`pre`/`a` element — an entity typed in code is
  # sample text and we never nest a link in a link.
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
      {[], []} ->
        html

      {mentions, hashtags} ->
        # With an empty user map every mention falls through as plain text
        # (`mention_link/3`), which is exactly what :hashtags_only wants.
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
    {mentions, hashtags} =
      reduce_linkable_text(tokens, {[], []}, fn text, acc ->
        @entity
        |> Regex.scan(text, capture: :all_but_first)
        |> Enum.reduce(acc, &collect_candidate/2)
      end)

    {Enum.uniq(mentions), Enum.uniq(hashtags)}
  end

  # `Regex.scan` truncates trailing unmatched groups, so a mention hit arrives
  # as `["handle"]` and a hashtag hit as `["", "hashtag"]` — match on the first
  # group being present (mention) vs empty (hashtag).
  defp collect_candidate([mention | _], {mentions, hashtags}) when mention != "",
    do: {[String.downcase(mention) | mentions], hashtags}

  defp collect_candidate([_, hashtag], {mentions, hashtags}),
    do: {mentions, [String.downcase(hashtag) | hashtags]}

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
      whole, handle, "" -> mention_link(whole, handle, users)
      whole, "", hashtag -> hashtag_link(whole, hashtag, tags)
    end)
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

  ## Inline post images

  # Swaps every allowed `![alt](url)` for a plain-text marker and returns the
  # replacement <img> HTML per marker. The marker carries a per-render nonce,
  # so an author cannot type a literal marker that collides with a real one.
  defp extract_inline_images(text, images) do
    allowed = allowed_srcs(images)
    nonce = Base.encode16(:crypto.strong_rand_bytes(6))

    @inline_image
    |> Regex.scan(text)
    |> Enum.reduce({text, []}, fn [full, alt, src], {text, replacements} ->
      case Map.get(allowed, src) do
        nil ->
          {text, replacements}

        {image, canonical_src} ->
          marker = "VUTUVIMG#{nonce}N#{length(replacements)}END"

          {String.replace(text, full, marker, global: false),
           [{marker, inline_img_html(canonical_src, alt, image)} | replacements]}
      end
    end)
  end

  # Every URL form an old or new body may carry (`PostImage.url_forms/2`,
  # incl. the pre-AVIF `.webp` form) maps to the image and its **canonical**
  # URL — the rendered <img> always points at the current format.
  defp allowed_srcs(images) do
    for image <- images,
        version <- PostImage.versions(),
        src <- PostImage.url_forms(image, version),
        into: %{} do
      {src, {image, PostImage.url(image, version)}}
    end
  end

  defp inline_img_html(src, md_alt, image) do
    alt = if md_alt == "", do: image.alt || "", else: md_alt

    dimensions =
      if image.width && image.height do
        ~s( width="#{image.width}" height="#{image.height}")
      else
        ""
      end

    ~s(<img src="#{escape(src)}" alt="#{escape(alt)}"#{dimensions} loading="lazy" class="post-inline-image">)
  end

  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  # Every <img> the pipeline produced is untrusted (remote hotlinks, foreign
  # attachments); only the marker-injected ones below may survive.
  defp strip_img_tags(html) do
    String.replace(html, ~r/<img\b[^>]*>/i, "")
  end

  defp inject_inline_images(html, replacements) do
    Enum.reduce(replacements, html, fn {marker, img_html}, html ->
      String.replace(html, marker, img_html)
    end)
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
