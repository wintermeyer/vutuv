defmodule VutuvWeb.EmailMarkdown do
  @moduledoc """
  Full-Markdown → sanitized HTML for the one personal message a member writes in
  an invitation email (`Vutuv.Invitations`).

  This is the fuller sibling of `VutuvWeb.Markdown` (the chat/post renderer). A
  post or a chat bubble is a feed element read by many, so that renderer
  deliberately narrows Markdown: bare URLs collapse to a host-only display,
  post headings flatten to bold, `@handle`/`#hashtag` become site links. An
  invitation message is a one-off note a member writes to someone they know, so
  none of those apply — it should read like an ordinary email:

    * bare URLs autolink and keep their **full** text (Earmark `pure_links`), so
      a pasted link is clickable and shown in full — the reason this renderer
      exists (a plain-text message left the link unclickable);
    * the whole standard Markdown set renders — headings stay headings, plus
      lists, blockquotes, tables, inline/fenced code, bold/italic, horizontal
      rules;
    * no `@handle` / `#hashtag` rewriting (an invitation is not the feed).

  Safety is unchanged, because the rendered HTML is both mailed to the recipient
  and shown back to the inviter on the "sent" preview page: raw HTML the member
  types is escaped to literal text first (so it can never inject markup, and
  Earmark never enters HTML-block mode and swallows the surrounding Markdown),
  the output runs through `HtmlSanitizeEx`, links open in a new tab, and images
  are dropped — an invitation must not embed a remote picture (a tracking pixel
  and a spam-filter red flag).
  """

  alias VutuvWeb.Markdown

  @doc "Render an invitation message's Markdown to safe HTML (`Phoenix.HTML.safe`)."
  def render(text) when is_binary(text) do
    text
    # Escape `<` so typed HTML shows as literal text and Earmark stays out of
    # HTML-block mode. Earmark then escapes our `&` into `&amp;lt;`; undo that.
    |> String.replace("<", "&lt;")
    |> Earmark.as_html!(breaks: true, pure_links: true)
    |> String.replace("&amp;lt;", "&lt;")
    |> HtmlSanitizeEx.markdown_html()
    |> Markdown.strip_img_tags()
    |> Markdown.open_links_in_new_tab()
    |> Phoenix.HTML.raw()
  end

  def render(_), do: Phoenix.HTML.raw("")

  @doc """
  The same message as **plain text**, for the `text/plain` half of the mail.

  Both bodies must say the same thing, so the text part is this renderer's
  output flattened (`VutuvWeb.Markdown.html_to_plain_text/1`) rather than the
  Markdown source: nobody typed those `**` markers, the composer is a WYSIWYG
  editor, and a reader in a plain-text client should not be the only one who
  sees them.

  Flattening a link would otherwise throw its target away — and in a text body
  nothing is clickable, so the URL *is* the link. Each one is therefore expanded
  to `label (url)` first, or left as the bare URL when the label already is it.
  """
  def to_text(text) when is_binary(text) do
    text
    |> render()
    |> Phoenix.HTML.safe_to_string()
    |> expand_links()
    |> Markdown.html_to_plain_text()
  end

  def to_text(_), do: ""

  # `<a … href="url" …>label</a>` -> `label (url)`. The href is matched
  # independently of the other attributes because `open_links_in_new_tab/1` puts
  # `target`/`rel` in front of it, and the label may still hold inline tags
  # (`<strong>`), which the flattening drops a step later.
  defp expand_links(html) do
    Regex.replace(~r{<a\s[^>]*href="([^"]*)"[^>]*>(.*?)</a>}s, html, fn _match, url, label ->
      if String.trim(strip_tags(label)) == String.trim(url),
        do: label,
        else: "#{label} (#{url})"
    end)
  end

  defp strip_tags(html), do: String.replace(html, ~r/<[^>]*>/, "")
end
