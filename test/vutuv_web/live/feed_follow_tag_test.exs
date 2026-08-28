defmodule VutuvWeb.PostLive.FeedFollowTagTest do
  @moduledoc """
  Following a tag from the feed's rail.

  Until this existed the only way in was a tag's own page, which is a long way
  round for a topic the reader is looking straight at — so the card offers the
  tags on the page and takes a typed name.

  The one rule worth a test of its own: **an unknown name is answered, never
  minted.** Creating a topic because somebody typed a word into a follow box
  puts an empty tag into a namespace every member shares, with the reader as its
  only inhabitant.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.Tags

  defp with_tagged_post(conn) do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:activated_user)
    insert(:follow, follower: user, followee: friend)

    name = Vutuv.Factory.unique_tag_name("Bremen")
    tag = insert(:tag, name: name, slug: Vutuv.SlugHelpers.tagify(name))
    {:ok, post} = Posts.create_post(friend, %{body: "moin", tags: name})

    %{conn: conn, user: user, tag: tag, name: name, post: post}
  end

  test "a tag on the page is offered, and one press follows it", %{conn: conn} do
    %{conn: conn, user: user, tag: tag, name: name} = with_tagged_post(conn)

    {:ok, live, html} = live(conn, ~p"/feed")

    assert html =~ name
    refute html =~ ~s(id="followed-tag-#{tag.id}")

    live |> element(~s(#rail-followed_tags button[phx-value-name="#{name}"])) |> render_click()

    assert has_element?(live, "#followed-tag-#{tag.id}")
    assert [%{id: followed_id}] = Tags.followed_tags(user)
    assert followed_id == tag.id

    # And it stops being offered, because it is no longer something to add.
    refute has_element?(live, ~s(#rail-followed_tags button[phx-value-name="#{name}"]))
  end

  test "a typed name finds the tag however it was spelled", %{conn: conn} do
    %{conn: conn, user: user, tag: tag, name: name} = with_tagged_post(conn)

    {:ok, live, _html} = live(conn, ~p"/feed")

    live
    |> element(~s(#rail-followed_tags form))
    |> render_submit(%{"name" => String.upcase(name)})

    assert [%{id: followed_id}] = Tags.followed_tags(user)
    assert followed_id == tag.id
  end

  # Calibrated by minting the tag instead: the card then reports success and the
  # tag table grows a topic with one follower and nothing in it.
  test "an unknown name is answered rather than minted", %{conn: conn} do
    %{conn: conn, user: user} = with_tagged_post(conn)
    before = Vutuv.Repo.aggregate(Vutuv.Tags.Tag, :count)

    {:ok, live, _html} = live(conn, ~p"/feed")

    html =
      live
      |> element(~s(#rail-followed_tags form))
      |> render_submit(%{"name" => "gibtesnichtundgabesnie"})

    assert html =~ "gibtesnichtundgabesnie"
    assert Tags.followed_tags(user) == []
    assert Vutuv.Repo.aggregate(Vutuv.Tags.Tag, :count) == before
  end

  test "the chips do not wear a leading hash", %{conn: conn} do
    %{conn: conn, user: user, tag: tag, name: name} = with_tagged_post(conn)
    {:ok, _} = Tags.follow_tag(user, tag)

    {:ok, live, _html} = live(conn, ~p"/feed")

    # The card is named after tags and the two beside it dropped their hashes
    # too, so the chip carries the bare name.
    #
    # Scoped to the card: an unscoped refute forbids the string on the whole
    # page, and the "New here" card writes its members' profile tags with a
    # leading hash — a rule about this card would then be failed by a different
    # one, depending on who the random draw greets.
    assert has_element?(live, "#followed-tag-#{tag.id}", name)
    refute live |> element("#followed-tags") |> render() =~ "#" <> name
  end
end
