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
  server half: both folds wear the marker and an id of their own, and still
  wear them in the markup the tick re-sends. The stamp moving to "Yesterday" is
  what proves that re-send happened, since an identical re-insert leaves
  nothing to see. A tick that is not the reader's midnight re-sends nothing,
  which only the render's telemetry can show.

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

  @servers_fold "[data-external-servers] > details[id^='external-servers-fold-'][data-keep-open]"
  @reactions_fold "[data-fediverse-details] > details[id$='-fediverse'][data-keep-open]"

  setup %{conn: conn} do
    put_config(:fetch_external_tag_posts, true)
    list_fixture_relays()
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

    # The marker copies `open` onto whatever node morphdom pairs, so every
    # marked disclosure on a card names itself, and no two share a name.
    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#feed-posts details[data-keep-open]")
      |> Enum.map(&LazyHTML.attribute(&1, "id"))

    assert ids != []
    refute [] in ids
    assert ids == Enum.uniq(ids)
  end

  test "a tick on another hour of the same day re-sends no card", %{conn: conn} do
    today = ViewerClock.today()
    travel_to(today, ~T[12:00:00])
    {:ok, view, _html} = live(conn, ~p"/feed")
    _ = render(view)
    watch_reinserts(view)

    travel_to(today, ~T[13:00:00])
    send(view.pid, :day_changed)
    _ = :sys.get_state(view.pid)

    refute_received {:posts_reinserted, _count}
  end

  test "the midnight re-insert re-sends both folds with the marker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/feed")
    refute has_element?(view, "time", "Yesterday")
    watch_reinserts(view)

    # Noon of the reader's tomorrow, not now + 24 h: on the night the clocks go
    # back, 24 hours after 00:30 is still the same calendar day.
    ViewerClock.today() |> Date.add(1) |> travel_to(~T[12:00:00])

    send(view.pid, :day_changed)
    _ = render(view)

    assert_received {:posts_reinserted, count} when count > 0
    assert has_element?(view, "time", "Yesterday")
    assert has_element?(view, @servers_fold)
    assert has_element?(view, @reactions_fold)
  end

  # A time on one of the reader's days, as the instant every calendar day in
  # the app is read off.
  defp travel_to(date, time) do
    at = date |> DateTime.new!(time, ViewerClock.zone()) |> DateTime.shift_zone!("Etc/UTC")
    put_config(:viewer_clock_now, at)
  end

  # Reports every render of `view` that carries feed cards to re-send. A render
  # happens only when something changed, and the stream's pending inserts are
  # still on the socket when it starts.
  defp watch_reinserts(view) do
    handler = "posts-reinserted-#{inspect(view.pid)}"

    :ok =
      :telemetry.attach(
        handler,
        [:phoenix, :live_view, :render, :start],
        &__MODULE__.report_reinserts/4,
        %{test: self(), view: view.pid}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def report_reinserts(_event, _measurements, %{socket: socket}, %{test: test, view: view}) do
    with true <- self() == view,
         %{posts: %{inserts: [_ | _] = inserts}} <- socket.assigns[:streams] do
      send(test, {:posts_reinserted, length(inserts)})
    end
  end
end
