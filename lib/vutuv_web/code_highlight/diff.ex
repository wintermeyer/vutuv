defmodule VutuvWeb.CodeHighlight.Diff do
  @moduledoc """
  Turns a ```` ```diff ```` block into a real diff (issue #1108): every line
  becomes its own row carrying what it is — added, removed, context, hunk
  header, file header — and the leading `+`/`-` moves into a gutter column so
  it stops reading as part of the code. All the styling lives in `.diff-*` in
  `components.css`; this only supplies the structure.

  When the fence also named the language the diff is written in — ` ```diff:php `
  or ` ```diff lang="php" ` (issue #1138) — each row's code is coloured through
  `VutuvWeb.CodeHighlight` as well. Without that, a diff is the one block that
  stays a grey wall however well we know its language: `diff` marks the changed
  lines but says nothing about what is in them.

  It runs **after** the sanitizer on purpose. The scrubber allows a `class` on
  `<code>` (so the fence language survives to be read here) but strips every
  attribute off a `<span>`, which would throw the per-line classes away if they
  were emitted earlier. Everything injected here is built from known-safe
  parts: the class attributes are literals of ours, and the line text is the
  already-escaped output of the scrubber, re-emitted verbatim.

  The `+`/`-` stays **real text** rather than a CSS glyph, for three reasons: a
  copied block is still a valid diff, the added/removed distinction does not
  rest on colour alone (WCAG 1.4.1), and the same HTML goes out over RSS, mail
  and the fediverse, where none of our CSS applies and the marker is all a
  reader has left.
  """

  alias VutuvWeb.CodeHighlight
  alias VutuvWeb.CodeHighlight.Languages

  # The fence languages whose code block renders as a diff.
  @languages ~w(diff patch)

  # A fenced code block as Earmark, the sanitizer and `CodeHighlight` leave it.
  # The content is already escaped at this point — it can hold no `<` — so the
  # non-greedy match can never run past the end of its own block.
  @block ~r{<pre>\s*<code class="([^"]*)">([\s\S]*?)</code>\s*</pre>}

  # The same ceiling `VutuvWeb.CodeHighlight` puts on a block it colours, but
  # measured once for the whole diff rather than per row — and taken from there
  # rather than written out again beside a comment claiming they are equal.
  @highlight_max VutuvWeb.CodeHighlight.max_bytes()

  # Diff lines that carry no +/- of their own: the file headers a `git diff`
  # emits above the first hunk, and the "no newline" note below the last one.
  # `+++`/`---` are matched before the single-character `+`/`-`, so a file
  # header never reads as an added or removed line.
  @meta_prefixes [
    "+++",
    "---",
    "diff ",
    "index ",
    "new file mode",
    "deleted file mode",
    "old mode",
    "new mode",
    "similarity index",
    "rename from",
    "rename to",
    "\\ No newline"
  ]

  @doc """
  Rewrite every `diff`-fenced code block in already-rendered, already-sanitized
  HTML into diff rows. Everything else comes back unchanged.
  """
  def render(html) when is_binary(html) do
    # Cheap bail-out: a body with no fenced code block at all skips the scan.
    if String.contains?(html, ~s(<code class=")) do
      Regex.replace(@block, html, &rewrite/3)
    else
      html
    end
  end

  def render(html), do: html

  defp rewrite(whole, class, content) do
    words = class_words(class)

    if Enum.any?(words, &(&1 in @languages)) do
      block_html(content, row_language(words, content))
    else
      whole
    end
  end

  defp class_words(class) do
    class
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&(&1 |> String.downcase() |> String.replace_prefix("language-", "")))
  end

  # `VutuvWeb.CodeHighlight` puts the diff's own language on the code element as
  # a second `language-*` class when the fence named one.
  defp row_language(words, content) do
    with true <- byte_size(content) <= @highlight_max,
         name when is_binary(name) <- Enum.find(words, &(&1 not in @languages)),
         config when is_map(config) <- Languages.get(name) do
      {name, config}
    else
      _no_second_language -> nil
    end
  end

  # The block keeps its real newlines between the rows, so copying it (and
  # `VutuvWeb.Markdown.to_plain_text/1`, which just drops the tags) still yields
  # the diff line by line. They are not *rendered* twice because `.diff-block`
  # drops the `<pre>` back to `white-space: normal` — whitespace-only text
  # between two block-level rows then collapses away — while each row sets
  # `white-space: pre` again to keep its own indentation.
  defp block_html(content, language) do
    rows =
      content
      # Earmark emits no trailing newline of its own; a fence that ends with a
      # blank line does, and it would render as a stray empty row.
      |> String.replace_suffix("\n", "")
      |> String.split("\n")
      |> Enum.map_join("\n", &row_html(&1, language))

    ~s(<pre class="diff-block"><code class="#{code_class(language)}">) <>
      rows <> "</code></pre>"
  end

  # The rebuilt block keeps naming the language of the code inside it, so a
  # reader that never sees our stylesheet — an RSS client, a fediverse server —
  # still gets the fact, and a copied block still says what it is.
  defp code_class(nil), do: "diff"
  defp code_class({name, _config}), do: "diff language-" <> name

  defp row_html(line, language) do
    {kind, marker, text} = classify(line)

    ~s(<span class="diff-line diff-line--#{kind}">) <>
      ~s(<span class="diff-line__marker">#{marker}</span>) <>
      row_code(text, kind, language) <> "</span>"
  end

  # A hunk header and the `diff --git` scaffolding are not code in the diff's
  # language, so they keep their own quiet styling rather than being lexed as
  # if they were.
  defp row_code(text, _kind, nil), do: text
  defp row_code(text, kind, _language) when kind in ~w(hunk meta), do: text

  defp row_code(text, _kind, {_name, config}),
    do: CodeHighlight.highlight_escaped(text, config)

  # Every row renders a gutter span, empty ones included, so the code columns of
  # a loose diff (context lines written without the unified format's leading
  # space, which is how people paste them) line up with the +/- rows anyway.
  defp classify(line) do
    cond do
      String.starts_with?(line, "@@") -> {"hunk", "", line}
      String.starts_with?(line, @meta_prefixes) -> {"meta", "", line}
      String.starts_with?(line, "+") -> {"add", "+", drop_marker(line)}
      String.starts_with?(line, "-") -> {"del", "-", drop_marker(line)}
      String.starts_with?(line, " ") -> {"context", " ", drop_marker(line)}
      true -> {"context", "", line}
    end
  end

  defp drop_marker(line), do: binary_part(line, 1, byte_size(line) - 1)
end
