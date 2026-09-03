defmodule VutuvWeb.PostLive.FeedTagChipsTest do
  @moduledoc """
  How many tag chips a card wears, and how wide one of them may get.

  The long rows are the ones from over there: a member's post is capped at five
  tags by the composer, while a remote post closes with as many hashtags as its
  author felt like — 847 of the 2,641 cached posts that carry a closing line
  carry more than five, the longest 32 — so a single card could spend four lines
  of pills and bury the post under it (Stefan, 2026-09-03). A timeline card
  shows five and folds the rest behind a native `<details>`; the post's own
  page, which IS this one post, still shows every one of them.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.MastodonHelpers, only: [remote_account: 1, cached_post: 2]

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Posts

  # A followed account's post whose last line is nothing but hashtags — the
  # shape `Markdown.split_trailing_hashtags/1` lifts into the chip row.
  defp remote_post_with_hashtags(conn, count) do
    {conn, user} = create_and_login_user(conn)
    account = remote_account([])

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/#{account.id}"
    })

    names = for i <- 1..count, do: "Thema#{i}"

    post =
      cached_post(account,
        content_text: "Ein Gedanke von drüben.\n\n" <> Enum.map_join(names, " ", &"##{&1}")
      )

    %{conn: conn, post: post, names: names}
  end

  # Every chip in the remote card's row, and the subset the disclosure folds.
  defp tag_rows(html) do
    {elements(html, "[data-remote-tags] [data-remote-tag]"),
     elements(html, "[data-remote-tags] [data-folded-tags] [data-remote-tag]")}
  end

  defp tag_names(chips), do: Enum.flat_map(chips, &LazyHTML.attribute(&1, "data-remote-tag"))

  test "the feed shows five tags and folds the rest behind a pill", %{conn: conn} do
    %{conn: conn, names: names} = remote_post_with_hashtags(conn, 12)

    {:ok, _live, html} = live(conn, ~p"/feed")
    {all, folded} = tag_rows(html)

    # Folded is hidden, not dropped: every tag is in the markup in the author's
    # own order, so opening the disclosure needs no round trip and a crawler
    # reads the whole set.
    assert tag_names(all) == names
    assert length(folded) == 7
    assert html =~ "+7"
  end

  test "six tags need no control, since the pill costs what the chip costs", %{conn: conn} do
    %{conn: conn} = remote_post_with_hashtags(conn, 6)

    {:ok, _live, html} = live(conn, ~p"/feed")
    {all, _folded} = tag_rows(html)

    assert length(all) == 6
    refute html =~ "data-folded-tags"
  end

  test "the post's own page shows every tag, folded behind nothing", %{conn: conn} do
    %{conn: conn, post: post} = remote_post_with_hashtags(conn, 12)

    {:ok, _live, html} = live(conn, ~p"/system/fediverse/post/#{post.id}")
    {all, folded} = tag_rows(html)

    assert length(all) == 12
    assert folded == []
  end

  test "a long tag name is cut, and the whole of it stays in the title", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    friend = insert(:activated_user)
    insert(:follow, follower: user, followee: friend)

    # Long, but inside the tag slug's own 60-character limit.
    name = unique_tag_name(String.duplicate("sehrlangesthema", 3))
    {:ok, _post} = Posts.create_post(friend, %{body: "moin", tags: name})

    {:ok, _live, html} = live(conn, ~p"/feed")

    assert [chip] = elements(html, ~s([data-post-tags] a[href^="/tags/"]))
    assert LazyHTML.attribute(chip, "title") == [name]
    assert [label] = Enum.to_list(LazyHTML.query(chip, "span"))
    assert LazyHTML.attribute(label, "class") == ["truncate"]
  end
end
