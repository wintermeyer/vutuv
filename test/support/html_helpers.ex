defmodule VutuvWeb.HTMLHelpers do
  @moduledoc """
  Assertions that read a rendered page rather than match a string in it.

  Imported into every `VutuvWeb.ConnCase` test. It is a module of its own rather
  than more lines in that case template's `quote` block, which is already at the
  length Credo will refuse.
  """

  @doc """
  Every `<a href="/<slug>">` in `html` that carries `rel="nofollow"` — the marker
  a public listing puts on a member who asked search engines to leave their
  profile alone (`VutuvWeb.UserHelpers.profile_rel/1`).

  Read out of the parsed document, so the attribute order a template happens to
  emit is not part of the promise.

  The `Enum.to_list/1` is load-bearing: a LazyHTML node set is never `== []`, so
  an empty one satisfies a `!= []` assertion with nothing in it and the test
  passes whether or not the `rel` is there.
  """
  def nofollow_links(html, slug) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(a[href="/#{slug}"][rel~="nofollow"]))
    |> Enum.to_list()
  end

  @doc """
  The visible text of the first element matching `selector`, whitespace
  trimmed.

  For a promise about what a member (or a script reading the DOM) actually gets
  out of an element, rather than about a string appearing anywhere in the
  document: the TOTP page's copy button hands the clipboard the text of the
  element it names, so the assertion has to read that element and not the page.
  """
  def text_of(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end
end
