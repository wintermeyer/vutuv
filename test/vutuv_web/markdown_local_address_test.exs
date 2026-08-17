defmodule VutuvWeb.MarkdownLocalAddressTest do
  @moduledoc """
  An address on **our own** host renders as a mention (issue #1560).

  `@ada@vutuv.de` is the member `@ada` written out in full — the spelling every
  other server uses to name one of us — so it links to the profile, in the same
  tab, keeping the address as its visible text. It used to be sent through the
  Mastodon-web convention `https://<host>/@<user>`, a path vutuv does not serve,
  so the one clickable thing in a sentence naming a member 404ed on our own
  domain and opened in a second tab to do it.

  `async: false` and its own file because `with_endpoint_host/1` changes global
  endpoint config the SQL sandbox does not roll back; the test endpoint's
  "localhost" has no dot and cannot match the address grammar at all.
  """
  use Vutuv.DataCase, async: false

  import Vutuv.EndpointHostHelper
  import Vutuv.Factory

  alias VutuvWeb.Markdown

  setup do
    with_endpoint_host("vutuv.test")
    :ok
  end

  defp render(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  defp ada do
    handle = "ada#{System.unique_integer([:positive])}"
    insert(:user, username: handle, first_name: "Ada", last_name: "Lovelace")
    handle
  end

  test "an address on our host links to the profile, same tab, address intact" do
    handle = ada()
    html = render("Thanks @#{handle}@vutuv.test for the help!")

    assert html =~ ~s(href="/#{handle}")
    assert html =~ ~s(title="Ada Lovelace")
    assert html =~ ">@#{handle}@vutuv.test</a>"
    refute html =~ "target=\"_blank\""
    refute html =~ "vutuv.test/@"
  end

  test "the www alias is us too" do
    handle = ada()
    html = render("cc @#{handle}@www.vutuv.test")

    assert html =~ ~s(href="/#{handle}")
    assert html =~ ">@#{handle}@www.vutuv.test</a>"
  end

  test "an organization on our host links to its page" do
    handle = "acme#{System.unique_integer([:positive])}"
    organization = insert(:organization, username: handle, name: "Acme GmbH")
    html = render("join @#{handle}@vutuv.test")

    assert html =~ ~s(href="#{Vutuv.Organizations.canonical_path(organization)}")
    assert html =~ ~s(title="Acme GmbH")
  end

  test "an address of a handle nobody holds stays plain text" do
    html = render("hi @nobody_here@vutuv.test")

    refute html =~ "<a"
    assert html =~ "@nobody_here@vutuv.test"
  end

  test "an address on another server still leaves the site" do
    html = render("boost @bob@geno.social")

    assert html =~ ~s(href="https://geno.social/@bob")
    assert html =~ ~s(target="_blank")
  end

  test "an address inside inline code is sample text" do
    handle = ada()
    html = render("type `@#{handle}@vutuv.test` to mention them")

    refute html =~ ~s(href="/#{handle}")
  end

  # Remote content deliberately leaves a bare `@name` unlinked — over there it
  # names an account in the fediverse, not the vutuv member sharing the handle.
  # A full address on our host carries no such ambiguity: the host names us.
  test "remote content links an address on our host but not a bare handle" do
    handle = ada()
    html = Markdown.render_remote("hallo @#{handle}@vutuv.test und @#{handle}")

    assert html =~ ~s(href="/#{handle}")
    assert html =~ ">@#{handle}@vutuv.test</a>"
    refute html =~ ">@#{handle}</a>"
  end

  test "our own profile link in remote content is not nofollowed" do
    handle = ada()
    html = Markdown.render_remote("hallo @#{handle}@vutuv.test")

    refute html =~ "nofollow"
  end
end
