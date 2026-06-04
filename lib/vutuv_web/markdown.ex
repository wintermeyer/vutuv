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
end
