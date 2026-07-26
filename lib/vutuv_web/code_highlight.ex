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

  ## Why it runs on the HTML and not on the Markdown

  `VutuvWeb.Markdown` sanitizes the rendered HTML, and the sanitizer allows a
  `class` on `<code>` but strips every attribute off `<pre>` and `<span>`. So
  the colouring cannot survive being produced earlier: this step runs **after**
  the scrubber and builds its own markup from parts it controls. Nothing
  user-written reaches an attribute — the label and the `language-*` class come
  from `VutuvWeb.CodeHighlight.Languages` for a known language, and from a
  `[a-z0-9+#._-]` slice of the fence word otherwise.

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

  alias VutuvWeb.CodeHighlight.Languages
  alias VutuvWeb.CodeHighlight.Lexer

  @block ~r{<pre><code([^>]*)>(.*?)</code></pre>}s
  @class ~r{class="([^"]*)"}
  @max_bytes 20_000
  @max_word 24

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
    case fence_word(attrs) do
      nil -> whole
      word -> code_block(word, body)
    end
  end

  defp code_block(word, body) do
    config = Languages.get(word)
    label = (config && config.label) || word

    ~s(<div class="codeblock" data-language="#{attr(label)}">) <>
      ~s(<pre><code class="language-#{attr(Languages.slug(word))}">) <>
      highlight(body, config) <>
      ~s(</code></pre></div>)
  end

  # The fence word this block should be labelled with, or nil when it should be
  # left alone (no info string, or one of the "no language" markers).
  defp fence_word(attrs) do
    with [_whole, class] <- Regex.run(@class, attrs),
         word when word != "" <- normalize(class),
         false <- Languages.plain?(word) do
      word
    else
      _no_language -> nil
    end
  end

  # ```` ```js:app.js ````, ```` ```{.python} ```` and ```` ```language-sql ````
  # all name one language; keep the first word and strip the decoration around
  # it, then reduce what is left to a charset that is safe in both an attribute
  # value and a class name.
  defp normalize(class) do
    class
    |> String.split([" ", "\t", ":", ",", ";"], parts: 2)
    |> hd()
    |> String.trim("{")
    |> String.trim("}")
    |> String.trim_leading(".")
    |> String.downcase()
    |> String.replace_prefix("language-", "")
    |> String.replace(~r/[^a-z0-9+#._-]/, "")
    |> String.slice(0, @max_word)
  end

  defp highlight(body, nil), do: body
  # `family: :none` means "labelled, body not ours" — the `diff` fence, whose
  # rows `VutuvWeb.Markdown.highlight_diff_blocks/1` builds after us.
  defp highlight(body, %{family: :none}), do: body

  defp highlight(body, config) do
    with true <- byte_size(body) <= @max_bytes,
         {:ok, code} <- decode(body) do
      code
      |> Lexer.tokens(config)
      |> Enum.map(&span/1)
      |> IO.iodata_to_binary()
    else
      _too_big_or_unfamiliar -> body
    end
  end

  defp span({nil, text}), do: encode(text)

  defp span({class, text}),
    do: [~s(<span class="hl-), @css[class], ~s(">), encode(text), "</span>"]

  # Earmark escapes exactly these three characters in a code block, so decoding
  # them is enough — and re-encoding has to reproduce the input to prove it.
  # Anything else (a `&nbsp;`, a numeric entity) fails the check and the block
  # is left as it is.
  defp decode(escaped) do
    code =
      escaped
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&amp;", "&")

    if encode(code) == escaped, do: {:ok, code}, else: :error
  end

  defp encode(code) do
    code
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp attr(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
