defmodule VutuvWeb.MarkdownHashtagsTest do
  @moduledoc """
  `#hashtags` in user-written Markdown link to the tag page (`/tags/:slug`) —
  but **only** when the tag exists and has at least one visible member, so a
  link never lands on an empty tag page. Shares the entity-linking pass with
  `@handle` mentions; DB-backed, so it lives beside `markdown_mentions_test.exs`.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias Vutuv.Tags
  alias VutuvWeb.Markdown

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  defp render_post(text), do: text |> Markdown.render_post([]) |> Phoenix.HTML.safe_to_string()

  # A tag with one confirmed, non-hidden member carrying it (so its page is
  # non-empty and the hashtag is linkable).
  defp populated_tag(name) do
    {:ok, _user_tag} = Tags.add_user_tag(insert(:activated_user), name)
    :ok
  end

  test "a #hashtag of a non-empty tag links to the tag page" do
    populated_tag("Elixir")
    html = render("I love #Elixir and #elixir")

    assert html =~ ~s(href="/tags/elixir")
    assert html =~ ~s(class="hashtag")
    # the typed casing is preserved in the visible text
    assert html =~ ">#Elixir</a>"
    assert html =~ ">#elixir</a>"
  end

  test "a #hashtag with no matching tag stays plain text" do
    html = render("a #nonexistenttag here")

    refute html =~ "<a"
    assert html =~ "#nonexistenttag"
  end

  test "a #hashtag for a tag that exists but has NO members stays plain text" do
    insert(:tag, name: "Lonely", slug: "lonely")
    html = render("nobody uses #lonely")

    refute html =~ ~s(href="/tags/lonely")
    assert html =~ "#lonely"
  end

  test "a #hashtag whose only member is unconfirmed stays plain text" do
    {:ok, _} = Tags.add_user_tag(insert(:user, email_confirmed?: false), "Ghosttag")
    html = render("see #ghosttag")

    refute html =~ ~s(href="/tags/ghosttag")
    assert html =~ "#ghosttag"
  end

  test "matching is case-insensitive; the typed text shows, the slug is canonical" do
    populated_tag("PHP")
    html = render("ping #PHP now")

    assert html =~ ~s(href="/tags/php")
    assert html =~ ">#PHP</a>"
  end

  test "a # in the middle of a word is not a hashtag" do
    populated_tag("sharp")
    html = render("the key of C#sharp")

    refute html =~ ~s(href="/tags/sharp")
  end

  test "a hashtag inside inline code is left untouched" do
    populated_tag("Elixir")
    html = render("type `#elixir` to tag")

    refute html =~ ~s(href="/tags/elixir")
    assert html =~ "#elixir"
  end

  test "a hashtag inside a fenced code block is left untouched" do
    populated_tag("Elixir")
    html = render("```\n#elixir\n```")

    refute html =~ ~s(href="/tags/elixir")
  end

  test "a markdown heading is not turned into a hashtag link" do
    populated_tag("Heading")
    html = render("# Heading\n\nbody")

    assert html =~ "<h1"
    refute html =~ ~s(href="/tags/heading")
  end

  test "mentions and hashtags both resolve in the same body" do
    insert(:user, username: "ada", first_name: "Ada", last_name: "Lovelace")
    populated_tag("Elixir")
    html = render("@ada writes #elixir")

    assert html =~ ~s(href="/ada")
    assert html =~ ~s(href="/tags/elixir")
  end

  test "the internal hashtag link stays in the same tab" do
    populated_tag("Elixir")
    html = render("#elixir and https://example.com/x")

    assert html =~ ~r{<a href="/tags/elixir"[^>]*class="hashtag"[^>]*>#elixir</a>}
    refute html =~ ~r{<a href="/tags/elixir"[^>]*target="_blank"}
    # the external URL still opens in a new tab
    assert html =~ ~s(target="_blank")
  end

  test "hashtags also resolve in post bodies" do
    populated_tag("Elixir")
    html = render_post("Shipped with #elixir!")

    assert html =~ ~s(href="/tags/elixir")
  end
end
