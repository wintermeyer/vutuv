defmodule VutuvWeb.CV.MarkdownBlocks do
  @moduledoc """
  A work-experience / education description's Markdown (issue #905) reduced
  to the simple block structure the hand-built CV documents can carry
  (issue #920): paragraphs with explicit line breaks, bullet and numbered
  lists — inline markers stripped to their text, a `[label](url)` link kept
  as "label (url)" so the URL survives on paper.

  This is the shared floor for Word (`.docx`), OpenDocument (`.odt`) and
  LaTeX, whose renderers assemble their markup by hand and cannot take the
  profile's HTML pipeline. The HTML/print CV renders the full
  `VutuvWeb.Markdown` pipeline instead, and the JSON Resume keeps the raw
  source (its `summary` is CommonMark by spec). Headings and blockquotes
  flatten to plain paragraphs — the same "a stray heading must not blow up
  a compact rendering" stance the profile takes — and images are dropped
  like everywhere else. Escaping stays with each renderer: every returned
  string is plain text.
  """

  @type block :: {:p, String.t()} | {:ul, [String.t()]} | {:ol, [String.t()]}

  @doc """
  The description as a list of blocks: `{:p, text}` (inner line breaks as
  `\\n`), `{:ul, items}` and `{:ol, items}`. A description Earmark cannot
  parse falls back to one paragraph of the raw source.
  """
  @spec blocks(String.t()) :: [block()]
  def blocks(markdown) when is_binary(markdown) do
    case Earmark.Parser.as_ast(markdown, breaks: true) do
      {:ok, ast, _messages} -> ast |> Enum.flat_map(&block/1) |> Enum.reject(&empty_block?/1)
      {:error, _ast, _messages} -> [{:p, markdown}]
    end
  end

  @doc """
  The description as a single line of plain text — for compact one-line
  hints (the CV builder's entry checklist). Bullet items join with a
  middle dot, everything else with spaces.
  """
  @spec plain(String.t()) :: String.t()
  def plain(markdown) when is_binary(markdown) do
    markdown
    |> blocks()
    |> Enum.map_join(" ", fn
      {:p, text} -> text
      {:ul, items} -> Enum.join(items, " · ")
      {:ol, items} -> items |> Enum.with_index(1) |> Enum.map_join(" ", &numbered_item/1)
    end)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp numbered_item({item, index}), do: "#{index}. #{item}"

  defp block({"p", _attrs, children, _meta}), do: [{:p, inline_text(children)}]

  defp block({heading, _attrs, children, _meta}) when heading in ~w(h1 h2 h3 h4 h5 h6),
    do: [{:p, inline_text(children)}]

  defp block({"ul", _attrs, items, _meta}), do: [{:ul, item_texts(items)}]
  defp block({"ol", _attrs, items, _meta}), do: [{:ol, item_texts(items)}]

  # A blockquote's inner blocks surface as plain blocks of their own.
  defp block({"blockquote", _attrs, children, _meta}), do: Enum.flat_map(children, &block/1)

  # A fenced/indented code block: its lines, verbatim.
  defp block({"pre", _attrs, children, _meta}), do: [{:p, text_content(children)}]

  defp block({"hr", _attrs, _children, _meta}), do: []
  defp block({:comment, _attrs, _children, _meta}), do: []

  # Loose top-level text, and any exotic block (a table, raw HTML): its
  # visible text as one paragraph — nothing a description carries is lost.
  defp block(text) when is_binary(text), do: [{:p, String.trim(text)}]
  defp block({_tag, _attrs, children, _meta}), do: [{:p, inline_text(children)}]

  # A list item's inline content; a nested list folds into the item as
  # dash-prefixed extra lines (the parent renderer owns the bullet marker).
  defp item_texts(items) do
    Enum.map(items, fn {"li", _attrs, children, _meta} ->
      {nested, inline} = Enum.split_with(children, &nested_list?/1)
      lines = [inline_text(inline) | Enum.flat_map(nested, &nested_lines/1)]

      lines
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end)
  end

  defp nested_list?({tag, _attrs, _children, _meta}) when tag in ~w(ul ol), do: true
  defp nested_list?(_node), do: false

  defp nested_lines({_tag, _attrs, items, _meta}),
    do: items |> item_texts() |> Enum.map(&("– " <> &1))

  defp inline_text(children) do
    children |> Enum.map_join("", &inline/1) |> String.trim()
  end

  defp inline(text) when is_binary(text), do: text
  defp inline({"br", _attrs, _children, _meta}), do: "\n"
  defp inline({"img", _attrs, _children, _meta}), do: ""
  defp inline({:comment, _attrs, _children, _meta}), do: ""

  # A link keeps its target when the visible text doesn't already carry it
  # (an autolinked bare URL is its own text — never doubled).
  defp inline({"a", attrs, children, _meta}) do
    text = children |> Enum.map_join("", &inline/1) |> String.trim()

    case List.keyfind(attrs, "href", 0) do
      {"href", href} when href != text and text != "" -> "#{text} (#{href})"
      {"href", href} when text == "" -> href
      _no_href -> text
    end
  end

  # A loose li wraps its content in p's; inner p's read as inner lines.
  defp inline({"p", _attrs, children, _meta}), do: inline_text(children) <> "\n"

  # Everything else (strong/em/del/code/span...) contributes its text.
  defp inline({_tag, _attrs, children, _meta}), do: Enum.map_join(children, "", &inline/1)

  defp text_content(children) do
    children
    |> Enum.map_join("", fn
      text when is_binary(text) -> text
      {_tag, _attrs, inner, _meta} -> text_content(inner)
      _other -> ""
    end)
    |> String.trim()
  end

  defp empty_block?({:p, text}), do: String.trim(text) == ""
  defp empty_block?({_list, items}), do: items == [] or Enum.all?(items, &(&1 == ""))
end
