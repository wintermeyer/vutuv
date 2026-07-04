defmodule VutuvWeb.DevDocMarkdown do
  @moduledoc """
  Renders the repo-authored developer docs (`priv/dev_docs/*.md`) to HTML and
  gives every heading a GitHub-style `id` anchor, so the in-page
  `[...](/developers/...#section)` links the docs use actually resolve. Earmark
  on its own emits bare `<h2>`/`<h3>` with no id, which left those anchors dead.

  The docs are trusted repo content (not user input), so Earmark runs directly
  here rather than through the `VutuvWeb.Markdown` sanitizer used for posts.
  """

  @headings ~w(h1 h2 h3 h4 h5 h6)

  @doc """
  A Markdown string to an HTML string, with an `id` on every heading derived
  from its text (lowercased, punctuation dropped, spaces to hyphens, duplicates
  suffixed `-1`, `-2`, ...), matching the slug GitHub generates.

  `opts` are Earmark options. The legal pages pass `breaks: true` (a single
  newline becomes a hard `<br>`, like the newsletter renderer) so admins can
  write address blocks naturally; the dev docs keep the default paragraph
  semantics.
  """
  def to_html(markdown, opts \\ []) when is_binary(markdown) do
    {:ok, ast, _messages} = Earmark.as_ast(markdown, opts)

    ast
    |> add_heading_ids()
    |> Earmark.Transform.transform()
  end

  @doc """
  The anchor slug for a heading's text. Public so tests (and the drift guard)
  can check a documented `#anchor` against the heading it points at.
  """
  def slug(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/u, "-")
  end

  defp add_heading_ids(ast) do
    {nodes, _seen} = Enum.map_reduce(ast, %{}, &anchor/2)
    nodes
  end

  defp anchor({tag, attrs, content, meta}, seen) when tag in @headings do
    if List.keymember?(attrs, "id", 0) do
      {{tag, attrs, content, meta}, seen}
    else
      {id, seen} = content |> text() |> slug() |> unique(seen)
      {{tag, [{"id", id} | attrs], content, meta}, seen}
    end
  end

  defp anchor(node, seen), do: {node, seen}

  defp text(content) when is_list(content), do: Enum.map_join(content, "", &text/1)
  defp text(string) when is_binary(string), do: string
  defp text({_tag, _attrs, content, _meta}), do: text(content)
  defp text(_other), do: ""

  defp unique(base, seen) do
    case seen do
      %{^base => count} -> {"#{base}-#{count}", Map.put(seen, base, count + 1)}
      _ -> {base, Map.put(seen, base, 1)}
    end
  end
end
