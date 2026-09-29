defmodule VutuvWeb.MarkdownEmailTest do
  @moduledoc """
  A bare email address in a post becomes a `mailto:` link the browser never
  breaks across two lines. Before, `sw@wintermeyer-consulting.de` was plain
  text and wrapped at its hyphen, so a reader copied half an address.
  """
  # A `DataCase` because a fediverse address asks whether we hold the account.
  use Vutuv.DataCase, async: true

  alias VutuvWeb.Markdown

  @link ~s(<a href="mailto:sw@wintermeyer-consulting.de" class="email">sw@wintermeyer-consulting.de</a>)

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  defp render_post(text), do: text |> Markdown.render_post([]) |> Phoenix.HTML.safe_to_string()

  test "a post links the address as mailto, sentence punctuation stays outside" do
    html = render_post("Bitte an sw@wintermeyer-consulting.de mailen. Danke!")

    assert html =~ "an #{@link} mailen."
    refute html =~ "target="
  end

  test "a message links it the same way, before a trailing full stop" do
    assert render("Schreib an sw@wintermeyer-consulting.de.") =~ "#{@link}."
  end

  test "a fediverse address is a mention, not an email" do
    html = render_post("Folge @sw@wintermeyer-consulting.de")

    refute html =~ "mailto:"
    assert html =~ ~s(class="mention")
  end

  test "an address inside code or an existing link is left alone" do
    refute render_post("`sw@wintermeyer-consulting.de`") =~ "mailto:"

    html = render_post("[Mail](mailto:sw@wintermeyer-consulting.de) und https://x.de/?to=a@b.de")
    assert length(String.split(html, "mailto:")) == 2
  end

  test "something without a top-level domain is not an address" do
    refute render_post("user@localhost und a@b") =~ "mailto:"
  end
end
