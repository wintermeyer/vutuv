defmodule VutuvWeb.MarkdownMentionsTest do
  @moduledoc """
  `@handle` mentions in user-written Markdown become links to the member's
  profile, with the member's name as a hover tooltip (`title`). This is the
  one feature that gives the Markdown renderer DB access, so it lives in its
  own `DataCase` file — `markdown_test.exs` stays a pure, DB-free unit test.
  """
  use Vutuv.DataCase, async: true

  import Vutuv.Factory

  alias VutuvWeb.Markdown

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  defp render_post(text), do: text |> Markdown.render_post([]) |> Phoenix.HTML.safe_to_string()

  defp ada do
    insert(:user, username: "ada", first_name: "Ada", last_name: "Lovelace")
  end

  test "an @handle of an existing member links to their profile with a name tooltip" do
    ada()
    html = render("Thanks @ada for the help!")

    assert html =~ ~s(href="/ada")
    assert html =~ ~s(title="Ada Lovelace")
    assert html =~ ~s(class="mention")
    assert html =~ ">@ada</a>"
  end

  test "an @handle that is not a member stays plain text" do
    html = render("Hello @nobody_here, are you there?")

    refute html =~ "<a"
    assert html =~ "@nobody_here"
  end

  test "a bare username without @ is never linked" do
    ada()
    html = render("ada is great")

    refute html =~ "<a"
    assert html =~ "ada is great"
  end

  test "matching is case-insensitive but the typed text and canonical slug are preserved" do
    ada()
    html = render("ping @Ada now")

    assert html =~ ~s(href="/ada")
    assert html =~ ">@Ada</a>"
  end

  test "an email address is not mistaken for a mention" do
    ada()
    html = render("write to me at info@ada.example")

    refute html =~ ~s(href="/ada")
    assert html =~ "info@ada.example"
  end

  test "a mention inside inline code is left untouched" do
    ada()
    html = render("type `@ada` to mention them")

    refute html =~ ~s(href="/ada")
    assert html =~ "@ada"
  end

  test "a mention inside a fenced code block is left untouched" do
    ada()
    html = render("```\n@ada\n```")

    refute html =~ ~s(href="/ada")
    assert html =~ "@ada"
  end

  test "a mention inside bold text still links" do
    ada()
    html = render("**hi @ada**")

    assert html =~ "<strong>"
    assert html =~ ~s(href="/ada")
  end

  test "several mentions in one text all resolve" do
    ada()
    insert(:user, username: "grace", first_name: "Grace", last_name: "Hopper")

    html = render("cc @ada and @grace")

    assert html =~ ~s(href="/ada")
    assert html =~ ~s(href="/grace")
    assert html =~ ~s(title="Grace Hopper")
  end

  test "the internal mention link stays in the same tab while external URLs open a new tab" do
    ada()
    html = render("see @ada and https://example.com/page")

    # the mention is an internal link: no target/rel
    assert html =~ ~r{<a href="/ada"[^>]*class="mention"[^>]*>@ada</a>}
    refute html =~ ~r{<a href="/ada"[^>]*target="_blank"}
    # the external URL still opens in a new tab
    assert html =~ ~s(href="https://example.com/page")
    assert html =~ ~s(target="_blank")
  end

  test "mentions also resolve in post bodies" do
    ada()
    html = render_post("Welcome @ada!")

    assert html =~ ~s(href="/ada")
    assert html =~ ~s(title="Ada Lovelace")
  end

  test "a nameless member falls back to the @handle in the tooltip" do
    insert(:user, username: "ghost", first_name: nil, last_name: nil)
    html = render("ping @ghost")

    assert html =~ ~s(href="/ghost")
    assert html =~ ~s(title="@ghost")
  end
end
