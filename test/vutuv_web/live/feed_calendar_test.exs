defmodule VutuvWeb.FeedCalendarTest do
  @moduledoc """
  The feed calendar: the timeline really moves to the day you click, that day
  is a **window** rather than an upper bound, and the live present stops
  leaking into it while it is open.

  The window is the claim worth guarding hardest, and it only shows up when the
  reader presses "Load more" — without a lower bound the second page quietly
  slides into the day before and keeps going.

  The other half is the PubSub path, which never touches the query: it prepends
  the viewer's own posts and queues everybody else's behind the "N new posts"
  pill. Left alone it drops a post from thirty seconds ago into a timeline
  showing last week, with no query involved and nothing to notice it.
  """
  use VutuvWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Vutuv.Posts
  alias Vutuv.PostsHelpers
  alias Vutuv.Social
  alias Vutuv.ViewerClock
  alias VutuvWeb.Live.FeedTimeTravel, as: Travel
  alias VutuvWeb.PostLive.FeedCalendar

  @day 86_400

  # A followed author plus two posts placed by hand on either side of a
  # three-day boundary. Second precision everywhere, so nothing here may rely
  # on two events in the same second (see `Vutuv.PostsHelpers.backdate_post!`).
  defp feed_with_history(viewer) do
    author = insert(:activated_user)
    Social.follow(viewer, author.id)

    recent = PostsHelpers.create_post!(author, %{body: "from this morning"})
    PostsHelpers.backdate_post!(recent, 3_600)

    old = PostsHelpers.create_post!(author, %{body: "from a week ago"})
    PostsHelpers.backdate_post!(old, 7 * @day)

    author
  end

  defp timeline(view) do
    if has_element?(view, "#feed-posts"), do: render(element(view, "#feed-posts")), else: ""
  end

  defp iso(date), do: Date.to_iso8601(date)
  defp days_ago(n), do: Date.add(ViewerClock.today(), -n)

  # Every day cell in `html` the heatmap has put a shade on. Read out of the
  # parsed document rather than by matching a class anywhere on the page:
  # `bg-brand-*` is a colour half the feed's controls wear.
  defp shaded_days(html) do
    elements(
      html,
      ~s([phx-click="cal-day"][class*="bg-brand-1"], [phx-click="cal-day"][class*="bg-brand-3"], [phx-click="cal-day"][class*="bg-brand-5"], [phx-click="cal-day"][class*="bg-brand-7"])
    )
  end

  # The card on its own, which is the only place the waiting state is visible
  # at all: the message the feed sends itself is handled before `render_click`
  # returns, so a connected view is always past it by the time a test can look.
  defp calendar_markup(opts) do
    today = ViewerClock.today()

    render_component(
      &FeedCalendar.feed_calendar/1,
      Keyword.merge([id: "cal", open?: true, month: Travel.month_of(today), today: today], opts)
    )
  end

  # A day with enough on it to take the heatmap's top step.
  defp busy_day(author, days_back) do
    day = days_ago(days_back)

    for n <- 1..5 do
      post = PostsHelpers.create_post!(author, %{body: "busy day post #{n}"})
      PostsHelpers.place_post_on_day!(post, day, n)
    end

    day
  end

  describe "the calendar" do
    test "a day click shows that day and nothing newer", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      three = PostsHelpers.create_post!(author, %{body: "from three days ago"})
      PostsHelpers.backdate_post!(three, 3 * @day)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      assert timeline(view) =~ "from three days ago"
      refute timeline(view) =~ "from this morning"
    end

    test "and nothing OLDER either, which is what makes it a window",
         %{conn: conn} do
      # An upper bound alone would have shown the week-old post underneath; a
      # day must not. This is the lower bound riding in the cursor.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      three = PostsHelpers.create_post!(author, %{body: "from three days ago"})
      PostsHelpers.backdate_post!(three, 3 * @day)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      refute timeline(view) =~ "from a week ago"
    end

    test "'Load more' inside a day does not escape it", %{conn: conn} do
      # The lower bound has to survive pagination, or the second page walks
      # straight out of the day the reader opened.
      #
      # Past `@day_full_limit` posts, or the day would arrive whole and there
      # would be no second page to get wrong.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      for n <- 1..120 do
        post = PostsHelpers.create_post!(author, %{body: "day three post #{n}"})
        PostsHelpers.place_post_on_day!(post, days_ago(3), n)
      end

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      # More than one page of them exists, so there is a second page to get
      # wrong in the first place.
      assert has_element?(view, "#load-more, [phx-click='load-more']")
      render_click(view, "load-more")

      assert timeline(view) =~ "day three post 1"
      refute timeline(view) =~ "from a week ago"
      refute timeline(view) =~ "from this morning"
    end

    test "clicking the open day again closes it and returns to now",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})
      refute timeline(view) =~ "from this morning"

      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      assert timeline(view) =~ "from this morning"
    end

    test "a future day cannot be opened", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(Date.add(ViewerClock.today(), 5))})

      assert timeline(view) =~ "from this morning"
    end

    test "an unreadable date leaves the reader where they are", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      render_click(view, "cal-day", %{"date" => "../../etc/passwd"})

      refute timeline(view) =~ "from this morning"
    end

    test "paging months does not move the reader", %{conn: conn} do
      # Hunting for a busy week must not lurch the timeline about; only a day
      # click travels.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      render_click(view, "cal-month", %{"n" => "-1"})
      render_click(view, "cal-month", %{"n" => "-12"})

      assert timeline(view) =~ "from this morning"
      refute has_element?(view, "#feed-calendar-rail.ring-amber-400")
    end

    test "never pages into the future", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      # At this month the forward arrows are disabled rather than absent, so
      # the arrow beside them does not move under the reader's finger.
      assert has_element?(view, "#feed-calendar-rail button[phx-value-n='1'][disabled]")
      assert has_element?(view, "#feed-calendar-rail button[phx-value-n='12'][disabled]")
    end

    test "the heatmap shades the days something happened on", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      busy = busy_day(author, 2)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      # The busiest day of the month gets the top step; an empty day gets none.
      assert has_element?(view, ~s([phx-value-date="#{iso(busy)}"].bg-brand-700))
      assert has_element?(view, ~s([phx-value-date="#{iso(days_ago(20))}"].bg-slate-100))
    end

    test "the heatmap counts arrivals, which is never fewer than the cards",
         %{conn: conn} do
      # Validated against the real dev feed before it was written down: a day
      # counted at 306 drew 271 cards, the difference being a thread's posts
      # collapsing into one entry. The count is therefore an upper bound on
      # cards, never an undersell, and the invariant is what this pins — a
      # heatmap that shaded a day the timeline then showed as empty would be
      # worse than no heatmap.
      {_conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      day = days_ago(2)
      parent = PostsHelpers.create_post!(author, %{body: "thread root"})
      PostsHelpers.place_post_on_day!(parent, day, 300)

      reply = PostsHelpers.create_post!(author, %{body: "thread reply", parent_id: parent.id})
      PostsHelpers.place_post_on_day!(reply, day, 60)

      %{counts: counts} = Posts.feed_activity_by_day(user, day, day)
      counted = Map.get(counts, day, 0)

      page = Posts.feed_page(user, limit: 100, cursor: Travel.day_cursor(day))

      assert counted >= length(page.entries)
      assert counted > 0
      refute page.entries == []
    end

    test "the two readings are different questions, not a filter", %{conn: conn} do
      # "My posts" counts what the reader published; "Feed" counts what reached
      # them. A day where a followed author posted and the reader did not is the
      # case that tells the two apart.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      quiet = days_ago(2)
      theirs = PostsHelpers.create_post!(author, %{body: "their post"})
      PostsHelpers.backdate_post!(theirs, 2 * @day)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      assert has_element?(view, ~s([phx-value-date="#{iso(quiet)}"].bg-brand-700))

      render_click(view, "cal-metric", %{"metric" => "own"})

      assert has_element?(view, ~s([phx-value-date="#{iso(quiet)}"].bg-slate-100))
    end

    test "an unknown metric falls back rather than blanking the heatmap",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-metric", %{"metric" => "../../etc/passwd"})

      assert has_element?(
               view,
               "#feed-calendar-rail button[phx-value-metric='feed'][aria-pressed='true']"
             )
    end

    test "renders in the filter column and on a phone", %{conn: conn} do
      # The rail column is `hidden md:block`, so a calendar that lived only
      # there would not exist on a phone at all.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      assert has_element?(view, "#feed-rail #feed-calendar-rail")

      # Phone-only is decided once, by the row, not by each control in it: the
      # slot carried its own `md:hidden` while that row could still reach a
      # desktop with a waiting-posts pill in it, and the pill left in the
      # 2026-08-31 redesign.
      assert has_element?(view, "#feed-mobile-controls.md\\:hidden #feed-calendar-mobile")
    end
  end

  describe "the phone's one line" do
    # Under `md` the calendar, the filter sheet's button and the waiting-posts
    # pill share a single row, and that row is the only way to any of them.
    test "the calendar and the filter button share it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(view, "#feed-mobile-controls #feed-calendar-mobile")
      assert has_element?(view, "#feed-mobile-controls #open-filter-sheet")
    end

    test "and folded they are the same height", %{conn: conn} do
      # Side by side, one control was the app's 40px touch target and the
      # other as tall as its padding and its tallest child happened to make it
      # — 44px, and 48px once the amber "Now" button joined the row. Two
      # neighbours differing by four pixels read as one of them being wrong.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(view, "#open-filter-sheet.h-10")
      assert has_element?(view, "#feed-calendar-mobile.h-10")

      # The rail's copy is the same card and takes the same height — one
      # control height for both, not a per-call-site override.
      assert has_element?(view, "#feed-calendar-rail.h-10")

      # And the compose button, which is the control the column alignment
      # hangs on: it and the folded rail calendar are the first thing in their
      # respective columns, so the moment they stop being the same height the
      # timeline and the first rail card stop starting on one line.
      assert has_element?(view, "#open-composer.h-10")

      # Travelling: "Now" joins the folded row and must not push it taller.
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      assert has_element?(view, "#feed-calendar-mobile button[phx-click='travel-now']")
      assert has_element?(view, "#feed-calendar-mobile.h-10")
    end

    test "and so is the pill that takes the calendar's place", %{conn: conn} do
      # The pill is on the compose line rather than this one, but it is the
      # same control height as everything on both lines (it was 36px against
      # 40px), which is what lets it sit beside the compose button without
      # changing the line.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving while I read"})

      assert has_element?(view, "#show-new-posts.h-10")
      assert has_element?(view, "#open-filter-sheet.h-10")
    end

    test "unfolded the calendar is a card again, not a 40px line", %{conn: conn} do
      # The other half of the same class: a month grid does not fit in one
      # control's height, so an `h-10` somebody made unconditional would clip it.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      refute has_element?(view, "#feed-calendar-mobile.h-10")
    end

    test "a waiting post leaves the calendar's line alone", %{conn: conn} do
      # It used to fold sideways to give the pill the width, because the pill
      # was on this line. The pill lives on the compose line now, which exists
      # at every width, so the calendar has nothing to make room for and the
      # filter button keeps its word.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")

      refute has_element?(view, "#feed-calendar-mobile-slot.feed-cal-slot--away")

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving while I read"})

      # The class is gone from the stylesheet as well; this pins the markup so
      # a future arrival cannot start folding the calendar again.
      assert has_element?(view, "#show-new-posts")
      refute has_element?(view, "#feed-calendar-mobile-slot.feed-cal-slot--away")
    end

    test "the waiting-posts pill sits on the compose line, not this one", %{conn: conn} do
      # Which is what keeps the timeline still: that line is always there, so a
      # post arriving cannot push the column down (issue: Stefan, 2026-08-31).
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving while I read"})

      assert has_element?(view, "#composer-trigger #show-new-posts")
      refute has_element?(view, "#feed-mobile-controls #show-new-posts")

      # Which is also why that row has no desktop story left: the quote was the
      # only thing on it a wide screen ever showed.
      assert has_element?(view, "#feed-mobile-controls.md\\:hidden")
    end
  end

  describe "the live present while a day is open" do
    test "an arrival never lands in the day on screen", %{conn: conn} do
      # It belongs to today. A card from another day drawn into this day's
      # stream is a card that appears in the wrong place the moment anything
      # reveals it. (It is still COUNTED — see "the pill while a day is open".)
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving while I am in the past"})

      refute timeline(view) =~ "arriving while I am in the past"
    end

    test "a post the reader may not see is not counted either", %{conn: conn} do
      # The waiting count passes the same audience gate a drawn arrival does, or
      # the pill would promise posts that vanish the moment it is pressed.
      {conn, _user} = create_and_login_user(conn)
      stranger = insert(:activated_user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      {:ok, _fresh} = Posts.create_post(stranger, %{body: "from somebody I do not follow"})

      refute has_element?(view, "#show-new-posts")
    end

    test "the same arrival lands normally at now", %{conn: conn} do
      # Calibration: without this, the tests above pass just as well if
      # arrivals are broken outright.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving at now"})

      assert has_element?(view, "#show-new-posts")
    end

    test "writing a post takes the reader home to see it", %{conn: conn} do
      # Text that vanishes on submit reads as a post that was lost, so the
      # viewer's own post is the one arrival that ends the trip.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      {:ok, _mine} = Posts.create_post(user, %{body: "written from the past"})

      assert timeline(view) =~ "written from the past"
      assert timeline(view) =~ "from this morning"
    end
  end

  describe "how much of a day loads" do
    test "a small day arrives whole, with nothing left to load", %{conn: conn} do
      # A day is a bounded thing the reader asked to see, not an endless
      # timeline: paging through a quiet Tuesday ten posts at a time is
      # busywork the feed can just do for them.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      for n <- 1..12 do
        post = PostsHelpers.create_post!(author, %{body: "quiet day post #{n}"})
        PostsHelpers.place_post_on_day!(post, days_ago(3), n)
      end

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      assert timeline(view) =~ "quiet day post 1"
      assert timeline(view) =~ "quiet day post 12"
      refute has_element?(view, "#load-more")
      refute has_element?(view, "#load-day-all")
    end

    test "a busy day pages, and offers the whole day beside 'Load more'",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      for n <- 1..120 do
        post = PostsHelpers.create_post!(author, %{body: "busy day post #{n}"})
        PostsHelpers.place_post_on_day!(post, days_ago(3), n)
      end

      {:ok, view, _html} = live(conn, ~p"/feed")
      # Unfold first, as a reader must: the grid is what a day is clicked from,
      # and unfolding is what computes the counts the button names.
      render_click(view, "cal-toggle")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      assert has_element?(view, "#load-more")
      assert has_element?(view, "#load-day-all")
      # The button names the size of the day, taken from the heatmap's count.
      assert render(view) =~ "120"
    end

    test "'load the whole day' brings the rest in one go", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      for n <- 1..120 do
        post = PostsHelpers.create_post!(author, %{body: "busy day post #{n}"})
        PostsHelpers.place_post_on_day!(post, days_ago(3), n)
      end

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})
      refute timeline(view) =~ "busy day post 120"

      render_click(view, "load-day-all")

      assert timeline(view) =~ "busy day post 120"
      assert timeline(view) =~ "busy day post 1"
      # And still only that day.
      refute timeline(view) =~ "from this morning"
      refute timeline(view) =~ "from a week ago"
    end

    test "the whole-day button is a day thing, never offered at now",
         %{conn: conn} do
      # At now there is no "all": the feed goes back forever.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      for n <- 1..40 do
        post = PostsHelpers.create_post!(author, %{body: "recent post #{n}"})
        PostsHelpers.backdate_post!(post, n * 60)
      end

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(view, "#load-more")
      refute has_element?(view, "#load-day-all")
    end

    test "pressing it with no day open does nothing", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "load-day-all")

      assert timeline(view) =~ "from this morning"
    end
  end

  describe "'My posts' narrows the timeline, not just the shading" do
    test "the feed shows only what this member wrote", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)
      PostsHelpers.create_post!(user, %{body: "something I wrote"})
      PostsHelpers.create_post!(author, %{body: "something they wrote"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      assert timeline(view) =~ "something they wrote"

      render_click(view, "cal-metric", %{"metric" => "own"})

      assert timeline(view) =~ "something I wrote"
      refute timeline(view) =~ "something they wrote"
      refute timeline(view) =~ "from this morning"
    end

    test "switching back to Feed brings everybody else back", %{conn: conn} do
      # Calibration: without this, the test above passes just as well if the
      # timeline were simply emptied.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)
      PostsHelpers.create_post!(user, %{body: "something I wrote"})
      PostsHelpers.create_post!(author, %{body: "something they wrote"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-metric", %{"metric" => "own"})
      refute timeline(view) =~ "something they wrote"

      render_click(view, "cal-metric", %{"metric" => "feed"})

      assert timeline(view) =~ "something they wrote"
      assert timeline(view) =~ "something I wrote"
    end

    test "it narrows an open day too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      mine = PostsHelpers.create_post!(user, %{body: "mine on that day"})
      PostsHelpers.place_post_on_day!(mine, days_ago(3), 0)
      theirs = PostsHelpers.create_post!(author, %{body: "theirs on that day"})
      PostsHelpers.place_post_on_day!(theirs, days_ago(3), 60)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})
      assert timeline(view) =~ "theirs on that day"

      render_click(view, "cal-metric", %{"metric" => "own"})

      assert timeline(view) =~ "mine on that day"
      refute timeline(view) =~ "theirs on that day"
    end

    test "somebody else's arrival does not fill the pill under it",
         %{conn: conn} do
      # The pill promises that pressing it shows those posts here, and here is
      # "only mine".
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-metric", %{"metric" => "own"})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving from them"})

      refute has_element?(view, "#show-new-posts")
      refute timeline(view) =~ "arriving from them"
    end

    test "but my own post still lands straight on it", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-metric", %{"metric" => "own"})

      {:ok, _mine} = Posts.create_post(user, %{body: "written under my-posts"})

      assert timeline(view) =~ "written under my-posts"
    end

    test "it never becomes the member's remembered source setting",
         %{conn: conn} do
      # The band's stored `users.feed_source` is which NETWORK; this reading is
      # a view the reader is in right now. Writing it down would hand them a
      # feed of only their own posts on their next visit.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-metric", %{"metric" => "own"})

      assert Posts.remembered_feed_filter(Vutuv.Repo.reload!(user)) == :all
    end

    test "an unknown reading falls back rather than emptying the feed",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-metric", %{"metric" => "../../etc/passwd"})

      assert timeline(view) =~ "from this morning"
    end
  end

  describe "where the calendar stops going back" do
    test "the back arrows are dead once the feed reaches no further",
         %{conn: conn} do
      # Everything this member can see happens this month, so there is no
      # earlier month to page to.
      {conn, user} = create_and_login_user(conn)
      author = insert(:activated_user)
      Social.follow(user, author.id)
      PostsHelpers.create_post!(author, %{body: "the only post"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      assert has_element?(view, "#feed-calendar-rail button[phx-value-n='-1'][disabled]")
      assert has_element?(view, "#feed-calendar-rail button[phx-value-n='-12'][disabled]")
    end

    test "and alive again when there is something behind", %{conn: conn} do
      # Calibration: without this, the test above passes just as well if the
      # arrows were disabled outright.
      {conn, user} = create_and_login_user(conn)
      author = insert(:activated_user)
      Social.follow(user, author.id)

      old = PostsHelpers.create_post!(author, %{body: "from long ago"})
      PostsHelpers.backdate_post!(old, 200 * @day)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      refute has_element?(view, "#feed-calendar-rail button[phx-value-n='-1'][disabled]")
    end

    test "a backward press is refused at the floor, not just greyed out",
         %{conn: conn} do
      # A disabled button is a hint; the handler is the answer.
      {conn, user} = create_and_login_user(conn)
      author = insert(:activated_user)
      Social.follow(user, author.id)
      PostsHelpers.create_post!(author, %{body: "the only post"})

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      shown = render(view)

      render_click(view, "cal-month", %{"n" => "-1"})
      render_click(view, "cal-month", %{"n" => "-12"})

      this_month = Travel.month_of(nil)
      assert render(view) =~ "#{this_month.year}"
      assert shown =~ "#{this_month.year}"
    end

    test "a URL reaching past it shows an empty feed rather than an error",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed?day=1999-01-04")

      assert timeline(view) == ""
      assert render(view) =~ "Nothing reached your feed on"
      refute timeline(view) =~ "from this morning"
    end
  end

  describe "the grid does not wait for its shading" do
    test "the first render draws the days and shades none of them", %{conn: conn} do
      # A month of a fediverse-heavy feed is ~26 queries, and paying them inside
      # the press means the reader clicks the calendar and watches nothing
      # happen. So the grid goes out with everything that does not need the
      # month in it and the shading follows in a second render.
      #
      # The disconnected render is where that is observable at all: it is a
      # first render with no second one behind it, so a shaded one is proof the
      # counting ran on the blocking path.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)
      busy = busy_day(author, 2)

      html = conn |> get(~p"/feed?cal=1") |> html_response(200)

      assert html =~ ~s(phx-value-date="#{iso(busy)}")

      assert shaded_days(html) == [],
             "the disconnected render paid for a heatmap it has no second render to show"

      # And it does not claim one is coming, either: nothing was asked for here,
      # so a grid reading busy would promise a second render that never lands.
      assert elements(html, ~s([aria-busy="true"])) == []

      # And the socket, which does get a second render, ends up shaded.
      {:ok, view, _html} = live(conn, ~p"/feed?cal=1")
      assert has_element?(view, ~s([phx-value-date="#{iso(busy)}"].bg-brand-700))
    end

    test "the grid says the shading is on its way, and stops once it is there" do
      # An unshaded grid and a month nothing happened in are the same picture,
      # so between the press and the counts the card was answering the reader's
      # question wrongly. While they are out the grid reads busy, which is both
      # what a screen reader is told and what `components.css` hangs the
      # breathing cells off; once they land it says neither.
      waiting = calendar_markup(counts_pending?: true)

      assert waiting =~ ~s(aria-busy="true")

      settled = calendar_markup(counts_pending?: false, counts: %{ViewerClock.today() => 3})

      refute settled =~ "aria-busy"
    end
  end

  describe "folded by default" do
    test "opens folded, on today, with no month grid", %{conn: conn} do
      # The calendar is a way *out* of the present, and most visits are not
      # that: unfolded by default it would put six rows of month between the
      # composer and the first post for every reader who never travels.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")

      assert has_element?(
               view,
               "#feed-calendar-rail button[phx-click='cal-toggle'][aria-expanded='false']"
             )

      refute has_element?(view, "#feed-calendar-rail [phx-value-date]")
      assert render(view) =~ Vutuv.ViewerClock.format(ViewerClock.today(), :date)
    end

    test "the toggle unfolds the grid and folds it away again", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")

      render_click(view, "cal-toggle")
      assert has_element?(view, "#feed-calendar-rail [phx-value-date]")

      render_click(view, "cal-toggle")
      refute has_element?(view, "#feed-calendar-rail [phx-value-date]")
    end

    test "folding it away does not send the reader home", %{conn: conn} do
      # Somebody who opened last Tuesday and wants the grid out of the way is
      # still reading Tuesday; yanking them back to now would be a second thing
      # they did not ask for. Closing the DAY is what returns to the present.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})
      refute timeline(view) =~ "from this morning"

      render_click(view, "cal-toggle")

      refute timeline(view) =~ "from this morning"
      # And folded away it still says which day, since that is now the only
      # thing on screen that can.
      assert render(view) =~ Vutuv.ViewerClock.format(days_ago(3), :date)
    end
  end

  describe "the pill while a day is open" do
    test "arrivals still fill it", %{conn: conn} do
      # A reader who went to look at last Tuesday wants to know the present is
      # filling up behind them. This reverses the earlier behaviour, where an
      # arrival reaching a travelling reader was dropped entirely.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving while I read Tuesday"})

      assert has_element?(view, "#show-new-posts")
    end

    test "but the post is not drawn into the day on screen", %{conn: conn} do
      # It belongs to today. A hidden card from another day sitting in this
      # day's stream is a card that appears in the wrong place the moment
      # anything reveals it.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving while I read Tuesday"})

      refute timeline(view) =~ "arriving while I read Tuesday"
    end

    test "pressing it closes the day and comes home", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving while I read Tuesday"})
      render_click(view, "show-new")

      assert timeline(view) =~ "arriving while I read Tuesday"
      assert timeline(view) =~ "from this morning"
      # Back on today, so the grid no longer marks a day as open.
      refute has_element?(view, "#feed-calendar-rail [aria-current='date']")
    end

    test "the pill asks the server rather than revealing rows that do not exist",
         %{conn: conn} do
      # Under the cap and at now the control reveals the already-drawn rows in
      # the browser. With a day open there are no rows, so it has to be the
      # plain event or the press would do nothing at all.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})
      {:ok, _fresh} = Posts.create_post(author, %{body: "arriving while I read Tuesday"})

      assert has_element?(view, "#show-new-posts[phx-click='show-new']")
    end
  end

  describe "the URL" do
    test "a day link is sized by the same rule a day click is", %{conn: conn} do
      # A shared link and a press on the grid have to open the same thing. The
      # mount cannot read the calendar's counts (they do not exist yet), so it
      # pays for a single-day count rather than falling back to the arrival
      # page size — which left a `?day=` link showing part of a small day with
      # a "Load more" under it, where a click on the grid showed all of it.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      # Sized to sit BETWEEN the arrival page (40) and the whole-day limit
      # (100): fewer, and both rules would load the day whole and the test
      # would prove nothing.
      for n <- 1..60 do
        post = PostsHelpers.create_post!(author, %{body: "quiet day post #{n}"})
        PostsHelpers.place_post_on_day!(post, days_ago(3), n)
      end

      {:ok, view, _html} = live(conn, ~p"/feed?day=#{iso(days_ago(3))}")

      assert timeline(view) =~ "quiet day post 1"
      assert timeline(view) =~ "quiet day post 60"
      refute has_element?(view, "#load-more")
    end

    test "a day link opens that day with the calendar unfolded", %{conn: conn} do
      # The whole point: a specific URL for a specific day.
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      three = PostsHelpers.create_post!(author, %{body: "from three days ago"})
      PostsHelpers.backdate_post!(three, 3 * @day)

      {:ok, view, _html} = live(conn, ~p"/feed?day=#{iso(days_ago(3))}")

      assert timeline(view) =~ "from three days ago"
      refute timeline(view) =~ "from this morning"
      assert has_element?(view, "#feed-calendar-rail [phx-value-date]")
    end

    test "?cal=1 unfolds it without opening a day", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed?cal=1")

      assert has_element?(view, "#feed-calendar-rail [phx-value-date]")
      assert timeline(view) =~ "from this morning"
    end

    test "a mangled or future date lands on the feed, not on an error",
         %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      for bad <- ["not-a-date", "../../etc/passwd", iso(Date.add(ViewerClock.today(), 5))] do
        {:ok, view, _html} = live(conn, ~p"/feed?day=#{bad}")

        assert timeline(view) =~ "from this morning"
      end
    end

    test "the plain URL is untouched at the default state", %{conn: conn} do
      # `/feed` has to stay `/feed` for the reader who never travels.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, _view, html} = live(conn, ~p"/feed")

      assert html =~ ~s(phx-hook="FeedUrl")
    end
  end

  describe "the page around it" do
    test "an empty day says so instead of blaming a source switch", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      {:ok, view, _html} = live(conn, ~p"/feed")
      # A day far enough back that nothing had reached this member yet.
      render_click(view, "cal-day", %{"date" => iso(days_ago(300))})

      html = render(view)

      # Neither of the two "now" empty states: one blames a source switch, the
      # other tells somebody with a full timeline to go find people to follow.
      assert html =~ "Nothing reached your feed on"
      refute html =~ "Follow people to fill your feed"
    end

    test "the German labels are translated, short ones included", %{conn: conn} do
      # vutuv is a German site and `Phoenix.ConnTest` defaults to English, so a
      # feature checked only in the default locale is checked in the language
      # almost nobody here reads. The one-word labels are the point: likeliest
      # to have been fuzzy-filled, least likely to be noticed on screen.
      {conn, user} = create_and_login_user(conn)
      feed_with_history(user)

      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")
      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")

      html = render(view)

      for label <- [
            "Meine Beiträge",
            "Weniger",
            "Mehr",
            "Voriger Monat",
            "Nächstes Jahr",
            "Mo",
            "So"
          ] do
        assert html =~ label, ~s(the German label "#{label}" is missing from /feed)
      end

      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      assert render(view) =~ "Jetzt"
    end

    test "the whole-day button is German too", %{conn: conn} do
      {conn, user} = create_and_login_user(conn)
      author = feed_with_history(user)

      for n <- 1..120 do
        post = PostsHelpers.create_post!(author, %{body: "busy day post #{n}"})
        PostsHelpers.place_post_on_day!(post, days_ago(3), n)
      end

      conn = conn |> recycle() |> put_req_header("accept-language", "de-DE,de")
      {:ok, view, _html} = live(conn, ~p"/feed")
      render_click(view, "cal-toggle")
      render_click(view, "cal-day", %{"date" => iso(days_ago(3))})

      assert render(view) =~ "Ganzen Tag laden"
    end
  end
end
