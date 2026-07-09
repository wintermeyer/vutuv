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

  @doc "Render an invitation message's Markdown to safe HTML (`Phoenix.HTML.safe`)."
  def render(text) when is_binary(text) do
    text
    # Escape `<` so typed HTML shows as literal text and Earmark stays out of
    # HTML-block mode. Earmark then escapes our `&` into `&amp;lt;`; undo that.
    |> String.replace("<", "&lt;")
    |> Earmark.as_html!(breaks: true, pure_links: true)
    |> String.replace("&amp;lt;", "&lt;")
    |> HtmlSanitizeEx.markdown_html()
    |> strip_img_tags()
    |> open_links_in_new_tab()
    |> Phoenix.HTML.raw()
  end

  def render(_), do: Phoenix.HTML.raw("")

  # An invitation email embeds no picture: a hotlinked remote image is a
  # tracking pixel that leaks the recipient's IP and trips spam filters. The
  # `HtmlSanitizeEx.markdown_html/1` scrubber keeps `<img>`, so drop it here.
  defp strip_img_tags(html), do: String.replace(html, ~r/<img\b[^>]*>/i, "")

  # Run after the sanitizer (which strips `target`/`rel`), so external links
  # open in a new tab without leaking the referrer.
  defp open_links_in_new_tab(html) do
    String.replace(html, "<a href", ~s(<a target="_blank" rel="noopener noreferrer" href))
  end
end
