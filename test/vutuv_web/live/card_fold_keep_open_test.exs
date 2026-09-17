defmodule VutuvWeb.CardFoldKeepOpenTest do
  @moduledoc """
  A panel a reader opened on a feed card stays open when the hour turns (issue
  #2200).

  `Vutuv.DayClock` ticks on every whole UTC hour and the feed answers by
  re-inserting every card it holds, so morphdom walks each `<details>` on the
  page and drops the `open` the server never rendered. `app.js` carries a
  disclosure's own state across a patch only when it wears `data-keep-open`,
  and the fold two cards share — the servers that carried a find, and what other
  networks did with a post of ours — did not.

  A LiveView test cannot see a browser's `open` state, so this asserts the
  server half: both folds wear the marker, and still wear it in the markup the
  tick re-sends. The stamp moving to "Yesterday" is what proves that re-send
  happened, since an identical re-insert leaves nothing to see.

  `async: false`: it holds `:fetch_external_tag_posts` down and moves
  `:viewer_clock_now`, both application env the sandbox does not roll back.
  """
  use VutuvWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Vutuv.ExternalTagHelpers

  alias Vutuv.Fediverse.Reaction
  alias Vutuv.PostsHelpers
  alias Vutuv.Social
  alias Vutuv.ViewerClock

  @servers_fold "details[data-external-servers][data-keep-open]"
  @reactions_fold "details[data-fediverse-details][data-keep-open]"

  setup %{conn: conn} do
    put_config(:fetch_external_tag_posts, true)
    {conn, viewer} = create_and_login_user(conn)

    # A find two servers carried, so the card folds the list of them away.
    tag = insert(:tag)
    follow_tag_through(viewer, tag, tag_source())
    follow_tag_through(viewer, tag, "social.example")

    for source <- [tag_source(), "social.example"] do
      external_post(tag,
        source: source,
        author_host: author_host(),
        url: "https://#{author_host()}/@ada/1"
      )
    end

    # A post of ours somebody over there liked, so its card folds that away.
    author = insert(:activated_user)
    Social.follow(viewer, author.id)
    post = PostsHelpers.create_post!(author, %{body: "liked far away"})

    Repo.insert!(%Reaction{
      post_id: post.id,
      actor_uri: "https://social.example/users/alice",
      handle: "alice",
      kind: "like",
      received_at: DateTime.utc_now(:second)
    })

    %{conn: conn}
  end

  test "both folds on a feed card keep the reader's open state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/feed")

    assert has_element?(view, @servers_fold)
    assert has_element?(view, @reactions_fold)
  end

  test "the hourly re-insert re-sends both folds with the marker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/feed")
    refute has_element?(view, "time", "Yesterday")

    # Noon of the reader's tomorrow, not now + 24 h: on the night the clocks go
    # back, 24 hours after 00:30 is still the same calendar day.
    ViewerClock.today()
    |> Date.add(1)
    |> DateTime.new!(~T[12:00:00], ViewerClock.zone())
    |> DateTime.shift_zone!("Etc/UTC")
    |> travel_to()

    send(view.pid, :day_changed)
    _ = render(view)

    assert has_element?(view, "time", "Yesterday")
    assert has_element?(view, @servers_fold)
    assert has_element?(view, @reactions_fold)
  end

  # `fetch_env/2`, not `get_env/2`: a restore must tell "absent" from "nil".
  defp travel_to(%DateTime{} = at) do
    original = Application.fetch_env(:vutuv, :viewer_clock_now)
    Application.put_env(:vutuv, :viewer_clock_now, at)

    on_exit(fn ->
      case original do
        {:ok, was} -> Application.put_env(:vutuv, :viewer_clock_now, was)
        :error -> Application.delete_env(:vutuv, :viewer_clock_now)
      end
    end)
  end
end
