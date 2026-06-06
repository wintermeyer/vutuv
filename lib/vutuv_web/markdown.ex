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

  @url_display_max 40
  @trailing_punct ~w(. , ; : ! ?)
  @preview_limit 1000
  @inline_image ~r/!\[([^\]]*)\]\(([^)\s]+)\)/

  @doc "Render untrusted Markdown to safe HTML (`Phoenix.HTML.safe()`)."
  def render(text) when is_binary(text) do
    text
    |> String.replace("<", "&lt;")
    |> autolink_bare_urls()
    |> Earmark.as_html!(breaks: true, pure_links: false)
    # Earmark escapes the ampersand of our pre-escaped `&lt;` — undo the double.
    |> String.replace("&amp;lt;", "&lt;")
    |> HtmlSanitizeEx.markdown_html()
    |> open_links_in_new_tab()
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
    |> String.replace("<", "&lt;")
    |> autolink_bare_urls()
    |> Earmark.as_html!(breaks: true, pure_links: false)
    |> String.replace("&amp;lt;", "&lt;")
    |> HtmlSanitizeEx.markdown_html()
    |> strip_img_tags()
    |> open_links_in_new_tab()
    |> inject_inline_images(replacements)
    |> Phoenix.HTML.raw()
  end

  def render_post(_, _), do: Phoenix.HTML.raw("")

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

        image ->
          marker = "VUTUVIMG#{nonce}N#{length(replacements)}END"

          {String.replace(text, full, marker, global: false),
           [{marker, inline_img_html(src, alt, image)} | replacements]}
      end
    end)
  end

  defp allowed_srcs(images) do
    for image <- images, version <- Vutuv.Posts.PostImage.versions(), into: %{} do
      {Vutuv.Posts.PostImage.url(image, version), image}
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

    if new_length > limit do
      join_blocks(kept)
    else
      accumulate_blocks(rest, [block | kept], new_length, limit)
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
