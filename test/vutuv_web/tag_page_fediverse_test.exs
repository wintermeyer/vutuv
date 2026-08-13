defmodule VutuvWeb.TagPageFediverseTest do
  @moduledoc """
  The tag page's own half of issue #1330: a visitor who arrived from another
  server can see the topic's address and follow it where their account lives,
  and the follower count means everyone following the topic rather than only
  the members.

  This is the friction the issue set out to remove. The follow button renders
  only for a signed-in member, so before this a visitor from Mastodon saw a
  count and had no way in short of registering.

  `async: false`: points `:fediverse_tag_host` at a known host, which is global.
  """
  use VutuvWeb.ConnCase, async: false

  alias Vutuv.Fediverse
  alias Vutuv.Tags

  @tag_host "tags.example.test"

  setup do
    original = Application.fetch_env(:vutuv, :fediverse_tag_host)
    Application.put_env(:vutuv, :fediverse_tag_host, @tag_host)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :fediverse_tag_host, was)
        :error -> Application.delete_env(:vutuv, :fediverse_tag_host)
      end
    end)

    :ok
  end

  defp topic do
    n = System.unique_integer([:positive])
    insert(:tag, name: "Elixir #{n}", slug: "elixir_#{n}")
  end

  test "a logged-out visitor is shown the address and a way in", %{conn: conn} do
    tag = topic()

    html = conn |> get(~p"/tags/#{tag.slug}") |> html_response(200)

    assert html =~ "@#{tag.slug}@#{@tag_host}"
    assert html =~ ~s(action="/tags/#{tag.slug}/fediverse/follow")
  end

  test "the follower count sums the members and the remote accounts", %{conn: conn} do
    tag = topic()
    member = insert(:activated_user)
    {:ok, _} = Tags.follow_tag(member, tag.id)

    {:ok, _} =
      Fediverse.add_tag_follower(tag, %{
        actor_uri: "https://remote.example/users/frida",
        inbox_uri: "https://remote.example/users/frida/inbox"
      })

    html = conn |> get(~p"/tags/#{tag.slug}") |> html_response(200)

    # One figure, because it is one thing: everyone following this topic.
    assert html =~ "2 followers"
  end

  test "a member who names an address of ours gets a plain vutuv follow", %{conn: conn} do
    tag = topic()
    {conn, member} = create_and_login_user(conn)

    # The tag host counts as us, which is what `own_host?/1` is for: asking it
    # over the network would be vutuv WebFingering itself, and the answer could
    # only ever route them back here. So they get what they actually asked for,
    # the plain tag follow.
    conn =
      post(conn, ~p"/tags/#{tag.slug}/fediverse/follow",
        address: "@#{member.username}@#{@tag_host}"
      )

    assert redirected_to(conn) =~ "/tags/#{tag.slug}"
    assert Tags.tag_followed?(member, tag)
  end

  test "the address of an unknown topic is a 404, not a redirect", %{conn: conn} do
    conn = post(conn, ~p"/tags/gibt_es_nicht/fediverse/follow", address: "@a@remote.example")

    assert conn.status == 404
  end
end
