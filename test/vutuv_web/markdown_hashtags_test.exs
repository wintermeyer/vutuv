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

  # Per-module unique tag name so async files never share a tags.slug lock
  # (see the test guidelines in .claude/rules/elixir.md). Dashless on purpose:
  # the hashtag grammar is `#([A-Za-z0-9_]+)`, a dash would end the match.
  hashtag_mod_id = :erlang.phash2(__MODULE__, 4_294_967_296)
  @elixir_tag "Elixir#{hashtag_mod_id}"
  @elixir_tag_down String.downcase(@elixir_tag)

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  defp render_post(text), do: text |> Markdown.render_post([]) |> Phoenix.HTML.safe_to_string()

  # A tag with one confirmed, non-hidden member carrying it (so its page is
  # non-empty and the hashtag is linkable).
  defp populated_tag(name) do
    {:ok, _user_tag} = Tags.add_user_tag(insert(:activated_user), name)
    :ok
  end

  test "a #hashtag of a non-empty tag links to the tag page" do
    populated_tag(@elixir_tag)
    html = render("I love ##{@elixir_tag} and ##{@elixir_tag_down}")

    assert html =~ ~s(href="/tags/#{@elixir_tag_down}")
    assert html =~ ~s(class="hashtag")
    # the typed casing is preserved in the visible text
    assert html =~ ">##{@elixir_tag}</a>"
    assert html =~ ">##{@elixir_tag_down}</a>"
  end

  test "a #hashtag with no matching tag stays plain text" do
    html = render("a #nonexistenttag here")

    refute html =~ "<a"
    assert html =~ "#nonexistenttag"
  end

  test "a #hashtag for a tag that exists but has NO members stays plain text" do
    # Dashless unique name: a dash would end the hashtag match (see the grammar
    # in Vutuv.Mentions), so unique_tag_name/1 is not usable inside a hashtag.
    name = "Lonely#{System.unique_integer([:positive])}"
    slug = String.downcase(name)
    insert(:tag, name: name, slug: slug)
    html = render("nobody uses ##{slug}")

    refute html =~ ~s(href="/tags/#{slug}")
    assert html =~ "##{slug}"
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
    populated_tag(@elixir_tag)
    html = render("type `##{@elixir_tag_down}` to tag")

    refute html =~ ~s(href="/tags/#{@elixir_tag_down}")
    assert html =~ "##{@elixir_tag_down}"
  end

  test "a hashtag inside a fenced code block is left untouched" do
    populated_tag(@elixir_tag)
    html = render("```\n##{@elixir_tag_down}\n```")

    refute html =~ ~s(href="/tags/#{@elixir_tag_down}")
  end

  test "a markdown heading is not turned into a hashtag link" do
    populated_tag("Heading")
    html = render("# Heading\n\nbody")

    assert html =~ "<h1"
    refute html =~ ~s(href="/tags/heading")
  end

  test "mentions and hashtags both resolve in the same body" do
    handle = "ada#{System.unique_integer([:positive])}"
    insert(:user, username: handle, first_name: "Ada", last_name: "Lovelace")
    populated_tag(@elixir_tag)
    html = render("@#{handle} writes ##{@elixir_tag_down}")

    assert html =~ ~s(href="/#{handle}")
    assert html =~ ~s(href="/tags/#{@elixir_tag_down}")
  end

  test "the internal hashtag link stays in the same tab" do
    populated_tag(@elixir_tag)
    html = render("##{@elixir_tag_down} and https://example.com/x")

    assert html =~
             ~r{<a href="/tags/#{@elixir_tag_down}"[^>]*class="hashtag"[^>]*>##{@elixir_tag_down}</a>}

    refute html =~ ~r{<a href="/tags/#{@elixir_tag_down}"[^>]*target="_blank"}
    # the external URL still opens in a new tab
    assert html =~ ~s(target="_blank")
  end

  test "hashtags also resolve in post bodies" do
    populated_tag(@elixir_tag)
    html = render_post("Shipped with ##{@elixir_tag_down}!")

    assert html =~ ~s(href="/tags/#{@elixir_tag_down}")
  end
end
