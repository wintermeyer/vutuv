defmodule VutuvWeb.RemoteLidKeepOpenTest do
  @moduledoc """
  A content warning or a covered picture the reader opened stays open when the
  hour turns, and never comes up open on another post (issue #2200).

  Both lids are `<details>` on cards the feed re-inserts every hour, so they
  wear `data-keep-open` like the card fold. The marker copies the open state
  onto whatever node morphdom pairs the lid with, and morphdom pairs an id-less
  element by position, so each lid carries an id built from its own post (and
  picture): a lid that would share one with another post's is the bug this
  file exists to catch.
  """
  use VutuvWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Vutuv.MastodonHelpers

  alias Vutuv.Fediverse.Follow
  alias Vutuv.Fediverse.RemoteImage
  alias VutuvWeb.PostComponents

  @lid ~r/<details\b[^>]*\bdata-remote-(?:warning|image-sensitive)\b[^>]*>/

  defp warned_post_with_covered_picture(account) do
    post =
      account
      |> cached_post(sensitive: true)
      |> Ecto.Changeset.change(summary: "Politik")
      |> Repo.update!()

    image =
      Repo.insert!(%RemoteImage{
        remote_post_id: post.id,
        source_uri: "https://social.example/media/#{post.id}.png",
        file: "img-abc.avif",
        moderation: "approved",
        sensitive: true
      })

    {post, image}
  end

  defp lid_ids(html) do
    for [tag] <- Regex.scan(@lid, html) do
      assert tag =~ "data-keep-open", "a lid without the marker: #{tag}"
      [_, id] = Regex.run(~r/\bid="([^"]+)"/, tag)
      id
    end
  end

  test "each post's lids carry the marker and ids of their own", %{conn: conn} do
    {conn, user} = create_and_login_user(conn)
    account = remote_account()

    Repo.insert!(%Follow{
      user_id: user.id,
      remote_account_id: account.id,
      state: "accepted",
      follow_activity_id: "https://vutuv.test/#{user.id}/actor#follows/1"
    })

    {first, first_image} = warned_post_with_covered_picture(account)
    {second, second_image} = warned_post_with_covered_picture(account)

    {:ok, view, _html} = live(conn, ~p"/feed")

    for {post, image} <- [{first, first_image}, {second, second_image}] do
      assert has_element?(
               view,
               ~s(details#remote-post-body-#{post.id}-warning[data-keep-open][data-remote-warning])
             )

      assert has_element?(
               view,
               ~s(details#remote-post-#{post.id}-picture-#{image.id}[data-keep-open][data-remote-image-sensitive])
             )
    end

    # Four lids on the page, four ids: two posts never share one.
    ids = view |> render() |> lid_ids()
    assert length(ids) == 4
    assert ids == Enum.uniq(ids)
  end

  test "a picture that belongs to no stored post gets neither id nor marker" do
    unsaved = %RemoteImage{file: "img-abc.avif", moderation: "approved", sensitive: true}

    html = render_component(&PostComponents.remote_post_images/1, images: [unsaved])

    assert html =~ "data-remote-image-sensitive"
    refute html =~ "data-keep-open"
  end
end
