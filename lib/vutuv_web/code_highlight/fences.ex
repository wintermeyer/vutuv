defmodule VutuvWeb.CodeHighlight.Fences do
  @moduledoc """
  What a code fence's info string is allowed to say, and how that survives
  Earmark (issues #1137 and #1138).

  A fence names its language — ` ```php ` — and may add two more facts:

    * a **title**, usually the file the snippet comes from, so the code makes
      sense in context; and
    * for a `diff` block, the **language inside the diff**, which `diff` alone
      cannot express (it marks the added and removed lines but leaves the code
      itself uncoloured).

  Both are written either as a short form after a colon or as an attribute:

      ```php:config/app.php          ```php title="config/app.php"
      ```diff:php                    ```diff lang="php"

  ## Why the short form is the one that gets stored

  Two links in the chain only understand a **single word** after the fence:

    * **Earmark** does not merely ignore the rest of an info string — a fence
      whose info string contains a space is not parsed as a fence at all, and
      the whole block collapses into one run of inline code. So ` ```js react `
      has always rendered as garbage, not just ` ```php title="…" `.
    * **Milkdown** (the composer) keeps a code block's first word as its
      `language` attribute and drops everything after it, so re-opening a post
      in the editor would silently throw an attribute-form title away.

  `normalize/1` therefore rewrites every opening fence line into one canonical
  word before Earmark sees it, and `assets/js/markdown_editor.js` rewrites the
  attribute form into the colon form before Milkdown sees it. Members may write
  either; what ends up stored and rendered is the short form.

  ## The canonical word

      language[:sub-language][!percent-encoded-title]

  It is one word of `[a-z0-9+#._-]`, `:`, `!` and percent escapes, which is
  what Earmark copies into `class` on the `<code>` element and the sanitizer
  leaves alone — so `decode/1` can read all three facts back out of the class
  after the scrubber has run. Nothing here is ever shown to a member.

  `decode/1` reads the raw shapes too (`js:app.js` written by hand, an
  un-normalized `<pre><code class="…">` from somewhere else), so the two
  functions are not a matched pair that can drift apart: they share one
  grammar, and `normalize/1` is a fixed point over it.
  """

  alias VutuvWeb.CodeHighlight.Languages

  # An opening (or closing) fence: up to three spaces of indentation, then a run
  # of at least three backticks or tildes. CommonMark's own rule, minus the
  # list-item nesting we do not need — an indented fence inside a list still
  # matches, it just cannot be told from a top-level one, which changes nothing
  # about the info string we rewrite.
  @fence ~r/^(\s{0,3})(`{3,}|~{3,})(.*)$/

  # `title="…"` / `lang="…"`, quoted either way or bare. Deliberately anchored
  # on the two keys we support: anything else in the info string is dropped, so
  # a `showLineNumbers` copied in from another site cannot break the fence.
  @attr ~r/(?<!\S)(title|lang)\s*=\s*(?:"([^"]*)"|'([^']*)'|(\S+))/i

  # A file path is the point of a title; a paragraph is not. The cap is
  # generous enough for a deep path and short enough that a pasted essay cannot
  # ride into a class attribute.
  @max_title 120
  @max_word 24

  @doc """
  Rewrite every opening code fence in a Markdown source so its info string is
  the single canonical word `decode/1` reads back.

  A fence with no info string, or one that is already a single plain word, is
  returned byte for byte — which is almost every fence, so the common case
  costs one regex match per line of a body that has a fence at all.
  """
  def normalize(markdown) when is_binary(markdown) do
    if String.contains?(markdown, ["```", "~~~"]) do
      markdown
      |> String.split("\n")
      |> Enum.map_reduce(nil, &normalize_line/2)
      |> elem(0)
      |> Enum.join("\n")
    else
      markdown
    end
  end

  def normalize(markdown), do: markdown

  # `open` is the fence that is currently held open — `{char, length}` — or nil
  # outside a block. Only an opening fence carries an info string; a closing one
  # must be bare, and anything in between is code we must not touch.
  defp normalize_line(line, open) do
    case Regex.run(@fence, line) do
      [_whole, indent, marker, info] -> fence_line(line, open, indent, marker, info)
      nil -> {line, open}
    end
  end

  defp fence_line(_line, nil, indent, marker, info) do
    {indent <> marker <> encode(parse(info)), {String.first(marker), String.length(marker)}}
  end

  defp fence_line(line, {char, length} = open, _indent, marker, info) do
    closing? =
      String.first(marker) == char and String.length(marker) >= length and
        String.trim(info) == ""

    {line, if(closing?, do: nil, else: open)}
  end

  @doc """
  The three facts a fence's info string (or the `class` Earmark made of it)
  carries: `{language, sub_language, title}`, each `nil` when absent.

  The colon short form means different things either side of a `diff` fence,
  and deliberately so: ` ```diff:php ` names the language the diff is written
  in (a diff has no language of its own), while ` ```php:app.php ` names the
  file, because there is no second language to name.
  """
  def parse(info) when is_binary(info) do
    {rest, title_attr, lang_attr} = pop_attrs(String.trim(info))

    {language, colon, marked} =
      rest
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> split_token()

    diff? = language && Languages.slug(language) == "diff"

    {language, sub_from(diff?, colon, lang_attr), title_from(diff?, colon, marked, title_attr)}
  end

  # `{language, colon segment, title after the `!` marker}`. The colon segment
  # is whichever of the two the fence word makes it — the caller decides — and
  # the marked title only ever comes from a word this module encoded itself.
  defp split_token(token) do
    {head, marked} =
      case String.split(token, "!", parts: 2) do
        [head] -> {head, nil}
        [head, encoded] -> {head, URI.decode(encoded)}
      end

    case String.split(head, ":", parts: 2) do
      [word] -> {word(word), nil, marked}
      # The colon form cannot carry a space (the fence would stop being a
      # fence), so `%20` is how the editor writes one back after a member typed
      # `title="two words"`. `URI.decode/1` is lenient — a literal `%` in a
      # title comes back as it went in.
      [word, colon] -> {word(word), URI.decode(colon), marked}
    end
  end

  # A diff's colon segment is a language, so it goes through the same charset
  # reduction as the fence word; every other fence's is the file name.
  defp sub_from(true, colon, nil), do: word(colon)
  defp sub_from(true, _colon, attr), do: word(attr)
  defp sub_from(_not_diff, _colon, _attr), do: nil

  defp title_from(diff?, colon, marked, attr) do
    title(attr || marked || unless(diff?, do: colon))
  end

  @doc """
  The canonical single info word for a `{language, sub_language, title}` triple,
  or `""` when there is nothing to say.
  """
  def encode({nil, _sub, _title}), do: ""

  def encode({language, sub, title}) do
    language <> encode_sub(sub) <> encode_title(title)
  end

  defp encode_sub(nil), do: ""
  defp encode_sub(sub), do: ":" <> sub

  defp encode_title(nil), do: ""
  # Only `A-Za-z0-9-_.~` survive unescaped, so the encoded title can hold
  # neither a space (which would break the fence), a quote (which would break
  # out of the class attribute) nor one of our own separators.
  defp encode_title(title), do: "!" <> URI.encode(title, &URI.char_unreserved?/1)

  # Everything the info string says that is not a `title=` / `lang=` attribute,
  # plus the two values.
  defp pop_attrs(info) do
    attrs =
      @attr
      |> Regex.scan(info)
      |> Map.new(fn [_whole, key | values] ->
        {String.downcase(key), values |> Enum.reject(&(&1 == "")) |> List.first()}
      end)

    {String.replace(info, @attr, " "), attrs["title"], attrs["lang"]}
  end

  # The fence word, reduced to what is safe in both a class name and an
  # attribute value. Mirrors what a language name can look like — an alias like
  # `c++` or `objective-c` passes, a quote or a space cannot.
  defp word(nil), do: nil

  defp word(value) do
    value
    |> String.trim()
    |> String.trim("{")
    |> String.trim("}")
    |> String.trim_leading(".")
    |> String.downcase()
    |> String.replace_prefix("language-", "")
    |> String.replace(~r/[^a-z0-9+#._-]/, "")
    |> String.slice(0, @max_word)
    |> blank_to_nil()
  end

  defp title(nil), do: nil

  defp title(value) do
    value
    |> String.trim()
    |> String.slice(0, @max_title)
    |> blank_to_nil()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
