defmodule VutuvWeb.CodeHighlight do
  @moduledoc """
  Names and colours the fenced code blocks in already-rendered Markdown, on the
  server (issues #1106 and #1107).

  A writer who fences a snippet as ` ```elixir ` gets two things back: the
  language in the corner of the block, and comments, strings, numbers and
  keywords in colour. Both are produced here, in Elixir, from the HTML the
  Markdown pipeline already emits — the page ships **no** highlighting
  JavaScript and no extra bytes for the readers who never see a code block.
  Everything the browser needs is the `.codeblock` / `.hl-*` rules in
  `assets/css/components.css`.

  A fence may also name the **file the snippet comes from** (issue #1137) —
  ` ```php:config/app.php ` or ` ```php title="config/app.php" ` — and that
  title is rendered as a real header bar above the code, not as a CSS label:
  a file name is information the reader needs, and the same HTML goes out over
  RSS, mail and the fediverse, where none of our stylesheet applies. The
  language name stays in that bar's right-hand corner when there is one, and in
  its own floating corner label otherwise.

  ## Why it runs on the HTML and not on the Markdown

  `VutuvWeb.Markdown` sanitizes the rendered HTML, and the sanitizer allows a
  `class` on `<code>` but strips every attribute off `<pre>` and `<span>`. So
  the colouring cannot survive being produced earlier: this step runs **after**
  the scrubber and builds its own markup from parts it controls. Nothing
  user-written reaches an attribute — the label and the `language-*` class come
  from `VutuvWeb.CodeHighlight.Languages` for a known language, and from a
  `[a-z0-9+#._-]` slice of the fence word otherwise; the title is escaped both
  as text and, for `data-title`, as an attribute value.

  The code text is escaped when it arrives, so highlighting has to decode it,
  tokenize, and escape each token again. `decode/1` only accepts a block it can
  rebuild byte for byte (`encode(decode(x)) == x`); anything else is left
  exactly as it was rather than risk mangling someone's snippet. A block over
  `#{div(20_000, 1000)}KB` keeps its label and skips the colouring.

  Unknown languages are not an error: the block still gets its label, just no
  colours. The conventional "no language" fence words (`text`, `plain`,
  `none`, …) get neither, and a fence with no info string at all is returned
  untouched, so the common case costs one `String.contains?/2`.
  """

  alias VutuvWeb.CodeHighlight.Fences
  alias VutuvWeb.CodeHighlight.Languages
  alias VutuvWeb.CodeHighlight.Lexer

  @block ~r{<pre><code([^>]*)>(.*?)</code></pre>}s
  @class ~r{class="([^"]*)"}
  @max_bytes 20_000

  @css %{
    comment: "com",
    string: "str",
    number: "num",
    keyword: "key",
    type: "typ",
    literal: "lit",
    tag: "tag",
    attr: "att",
    meta: "met"
  }

  @doc """
  Rewrite every labelled `<pre><code>` block in `html` into a titled, coloured
  code block. Everything else — including a fence with no language — comes back
  unchanged.
  """
  def render(html) when is_binary(html) do
    if String.contains?(html, "<pre><code") do
      Regex.replace(@block, html, &block/3)
    else
      html
    end
  end

  def render(html), do: html

  defp block(whole, attrs, body) do
    case fence_facts(attrs) do
      nil -> whole
      facts -> code_block(facts, body)
    end
  end

  defp code_block({word, sub, title}, body) do
    config = Languages.get(word)
    label = (config && config.label) || word

    ~s(<div class="#{wrapper_class(title)}" data-language="#{attr(label)}"#{title_attr(title)}>) <>
      title_bar(title, label) <>
      ~s(<pre><code class="#{code_class(word, sub)}">) <>
      highlight(body, config) <>
      ~s(</code></pre></div>)
  end

  # The title is a real element, so it survives every surface that drops our
  # CSS; `data-title` beside it is what a test (and any later JS) reads without
  # having to parse the bar. The language keeps its corner label only when
  # there is no bar to name it in.
  defp title_bar(nil, _label), do: ""

  defp title_bar(title, label) do
    ~s(<div class="codeblock__title"><span class="codeblock__file">#{attr(title)}</span>) <>
      ~s(<span class="codeblock__lang">#{attr(label)}</span></div>)
  end

  defp wrapper_class(nil), do: "codeblock"
  defp wrapper_class(_title), do: "codeblock codeblock--titled"

  defp title_attr(nil), do: ""
  defp title_attr(title), do: ~s( data-title="#{attr(title)}")

  # A diff block carries both languages: `language-diff` is what
  # `VutuvWeb.Markdown.highlight_diff_blocks/1` keys on, `language-<sub>` what
  # it colours the rows with (issue #1138).
  defp code_class(word, nil), do: "language-" <> attr(Languages.slug(word))

  defp code_class(word, sub),
    do: code_class(word, nil) <> " language-" <> attr(Languages.slug(sub))

  # What this block should be labelled with, or nil when it should be left
  # alone (no info string, or one of the "no language" markers).
  defp fence_facts(attrs) do
    with [_whole, class] <- Regex.run(@class, attrs),
         {word, sub, title} when is_binary(word) <- Fences.parse(class),
         false <- Languages.plain?(word) do
      {word, sub, title}
    else
      _no_language -> nil
    end
  end

  @doc """
  Colour one already-escaped run of code the way `render/1` colours a block
  body: decode, tokenize, escape each token again.

  Public for `VutuvWeb.Markdown.highlight_diff_blocks/1`, which colours a diff
  **row by row** — the marker has to come off first, and a row is the unit that
  gets its own added / removed tint. A construct that spans several lines (a
  block comment, a triple-quoted string) is therefore not carried from one row
  to the next, which is the right trade for a diff: a hunk is a fragment, and
  its first line is as likely to be the middle of such a construct as its
  start.
  """
  def highlight_escaped(escaped, config), do: highlight(escaped, config)

  defp highlight(body, nil), do: body
  # `family: :none` means "labelled, body not ours" — the `diff` fence, whose
  # rows `VutuvWeb.Markdown.highlight_diff_blocks/1` builds after us.
  defp highlight(body, %{family: :none}), do: body

  defp highlight(body, config) do
    with true <- byte_size(body) <= @max_bytes,
         {:ok, code, quotes} <- decode(body) do
      code
      |> Lexer.tokens(config)
      |> Enum.map(&span(&1, quotes))
      |> IO.iodata_to_binary()
    else
      _too_big_or_unfamiliar -> body
    end
  end

  defp span({nil, text}, quotes), do: encode(text, quotes)

  defp span({class, text}, quotes),
    do: [~s(<span class="hl-), @css[class], ~s(">), encode(text, quotes), "</span>"]

  # A code block reaches us escaped, and the two renderers that feed this module
  # escape it slightly differently: `Earmark.as_html!` (posts) leaves a `"`
  # alone, while `Earmark.as_ast` + `Transform` (the docs and legal pages)
  # writes it as `&quot;`. Which one it was is read off the block itself and
  # threaded back into `encode/2`, because the safety rule here is not an entity
  # list but a round trip: re-encoding has to reproduce the input byte for byte,
  # or the block is left exactly as it was rather than risk mangling someone's
  # snippet. Anything else (a `&nbsp;`, another numeric entity) fails that check.
  #
  # Missing the `&quot;` spelling used to fail it for every documentation block
  # containing a double quote, which is most of them — a `curl -H "…"` line lost
  # its colours while the same snippet in a post kept them.
  defp decode(escaped) do
    quotes = String.contains?(escaped, "&quot;")

    code =
      escaped
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> then(&if quotes, do: String.replace(&1, "&quot;", "\""), else: &1)
      |> String.replace("&amp;", "&")

    if encode(code, quotes) == escaped, do: {:ok, code, quotes}, else: :error
  end

  defp encode(code, quotes) do
    code
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> then(&if quotes, do: String.replace(&1, "\"", "&quot;"), else: &1)
  end

  defp attr(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
