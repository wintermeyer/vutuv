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

  # Ada with a per-test-unique handle (dot/dash-free: the mention grammar in
  # Vutuv.Mentions stops at them). Returns the handle for interpolation.
  defp ada do
    handle = "ada#{System.unique_integer([:positive])}"
    insert(:user, username: handle, first_name: "Ada", last_name: "Lovelace")
    handle
  end

  test "an @handle of an existing member links to their profile with a name tooltip" do
    handle = ada()
    html = render("Thanks @#{handle} for the help!")

    assert html =~ ~s(href="/#{handle}")
    assert html =~ ~s(title="Ada Lovelace")
    assert html =~ ~s(class="mention")
    assert html =~ ">@#{handle}</a>"
  end

  test "an @handle that is not a member stays plain text" do
    html = render("Hello @nobody_here, are you there?")

    refute html =~ "<a"
    assert html =~ "@nobody_here"
  end

  test "a bare username without @ is never linked" do
    handle = ada()
    html = render("#{handle} is great")

    refute html =~ "<a"
    assert html =~ "#{handle} is great"
  end

  test "matching is case-insensitive but the typed text and canonical slug are preserved" do
    handle = ada()
    typed = String.capitalize(handle)
    html = render("ping @#{typed} now")

    assert html =~ ~s(href="/#{handle}")
    assert html =~ ">@#{typed}</a>"
  end

  test "an email address is not mistaken for a mention" do
    handle = ada()
    html = render("write to me at info@#{handle}.example")

    refute html =~ ~s(href="/#{handle}")
    assert html =~ "info@#{handle}.example"
  end

  test "a mention inside inline code is left untouched" do
    handle = ada()
    html = render("type `@#{handle}` to mention them")

    refute html =~ ~s(href="/#{handle}")
    assert html =~ "@#{handle}"
  end

  test "a mention inside a fenced code block is left untouched" do
    handle = ada()
    html = render("```\n@#{handle}\n```")

    refute html =~ ~s(href="/#{handle}")
    assert html =~ "@#{handle}"
  end

  test "a mention inside bold text still links" do
    handle = ada()
    html = render("**hi @#{handle}**")

    assert html =~ "<strong>"
    assert html =~ ~s(href="/#{handle}")
  end

  test "several mentions in one text all resolve" do
    handle = ada()
    insert(:user, username: "grace", first_name: "Grace", last_name: "Hopper")

    html = render("cc @#{handle} and @grace")

    assert html =~ ~s(href="/#{handle}")
    assert html =~ ~s(href="/grace")
    assert html =~ ~s(title="Grace Hopper")
  end

  test "the internal mention link stays in the same tab while external URLs open a new tab" do
    handle = ada()
    html = render("see @#{handle} and https://example.com/page")

    # the mention is an internal link: no target/rel
    assert html =~ ~r{<a href="/#{handle}"[^>]*class="mention"[^>]*>@#{handle}</a>}
    refute html =~ ~r{<a href="/#{handle}"[^>]*target="_blank"}
    # the external URL still opens in a new tab
    assert html =~ ~s(href="https://example.com/page")
    assert html =~ ~s(target="_blank")
  end

  test "mentions also resolve in post bodies" do
    handle = ada()
    html = render_post("Welcome @#{handle}!")

    assert html =~ ~s(href="/#{handle}")
    assert html =~ ~s(title="Ada Lovelace")
  end

  test "a nameless member falls back to the @handle in the tooltip" do
    insert(:user, username: "ghost", first_name: nil, last_name: nil)
    html = render("ping @ghost")

    assert html =~ ~s(href="/ghost")
    assert html =~ ~s(title="@ghost")
  end
end
