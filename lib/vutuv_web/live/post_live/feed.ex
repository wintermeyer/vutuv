defmodule VutuvWeb.PostLive.Feed do
  @moduledoc """
  The newsfeed: the composer on top, then the viewer's timeline — own posts
  plus posts *and reposts* of followed authors (visibility-filtered pull
  model, `Vutuv.Posts.feed_page/2`), cursor "Load more" at the bottom — the
  same pagination style as notifications. Entries are
  `%{id:, post:, reposted_by:, at:}` maps; repost entries render the
  "Reposted by X" line on the card.

  The source tabs — All / vutuv / Fediverse — are gone. They made the source
  question a *place*: choosing one hid the other, and the dot on the tab you
  had left kept saying what you were missing, so readers hopped back and
  forth. Their successor is the rail's **filter band**
  (`VutuvWeb.PostLive.FilterBand`): one timeline that shows everything by
  default, with a switch per account, per fediverse server and per source.

  The split itself did not change — it still lives in `Vutuv.Posts.feed_page/2`
  and is still remembered on the member (`users.feed_source`,
  `Vutuv.Posts.remember_feed_filter/3`, issue #1499). What used to be a tab
  press is now the band's two source checkboxes writing that same column, which
  is why the tabs could be removed without their state going with them.
  Deliberately **not** broadcast to the member's other devices — a live switch
  would reload a timeline somebody else is reading from the top and take its
  pending batch, its loaded pages and its scroll position with it.

  Real-time: `Vutuv.Posts.create_post/2` broadcasts `{:new_post, …}` and
  `Vutuv.Posts.repost_post/2` `{:new_repost, …}` to the author/reposter and
  every follower over `Vutuv.Activity`. The viewer's own posts and reposts
  prepend immediately; everyone else's accumulate behind a *"Show N new
  posts"* pill (auto-inserting posts under a reading user is hostile), each
  checked against `visible_to?/2` server-side before it is even counted —
  the pill must not leak denied posts.
  """

  use VutuvWeb, :live_view

  import VutuvWeb.PostComponents
  import VutuvWeb.PostLive.FeedCalendar

  alias Phoenix.LiveView.JS
  alias Vutuv.Activity
  alias Vutuv.ContentFilters
  alias Vutuv.Fediverse
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Social
  alias Vutuv.Tags.UserTag
  alias Vutuv.ViewerClock
  alias VutuvWeb.Live.DayClockRestream
  alias VutuvWeb.Live.FeedTimeTravel
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.MountHandoff
  alias VutuvWeb.Live.PostTranslations
  alias VutuvWeb.Live.RemoteImages
  alias VutuvWeb.Live.RemotePostActions
  alias VutuvWeb.Live.RemoteReplyActions
  alias VutuvWeb.PostLive.FeedCalendar
  alias VutuvWeb.PostTeaser
  alias VutuvWeb.UserHelpers

  # The origin's like/repost figures on a card from another network tick
  # while this page is open (issue #1283). One line, no handler.
  on_mount(VutuvWeb.Live.RemoteCounts)

  # A picture on such a card appears the moment the AI gate releases it (issue
  # #1801). The timeline mode: the cards are in a stream, so this listens and
  # `handle_info({:remote_images_settled, …}, …)` below does the redraw.
  on_mount(VutuvWeb.Live.RemoteImages)

  # What a mount loads, and what every older page after it adds. The arrival
  # page is deliberately double the rest: it is the one page nobody asked for,
  # so it has to carry the reader past the first few scrolls without a round
  # trip, while an older page is fetched while they are still reading and can
  # afford to be half the size.
  @first_page_size 40
  # …and how many of them the **HTML document** carries. The rest arrive over
  # the socket the moment it connects, appended below the fold, so an arrival
  # still holds forty cards by the time anybody has scrolled to the tenth.
  #
  # This is the split between what the reader waits for and what they merely
  # get. Rendering a card is ~10 ms of server time on production (measured
  # 2026-08-31 two ways: a twelve-day regression over `?day=` volumes and a
  # paired A/B against an empty day, agreeing on 10.2 and 10.0), so the forty
  # were about 400 ms of the ~660 ms the browser sat waiting for the first
  # byte, to draw thirty-seven cards below a fold that shows two or three.
  # Ten costs ~100 ms of that and fills the screen three times over.
  #
  # It is deliberately the same number as `@filter_page_size`, for the reason
  # written there: ten is what a screen holding three or four cards needs to
  # not run out. What is new is only that an *arrival* is now judged by the
  # same standard as a switch — both are a wait with nothing on screen.
  #
  # Not a lazy rail (#1229, reverted the same day): nothing here pops in where
  # the reader is looking. The fill lands below the tenth card, off-screen, and
  # a reader who never scrolls never learns it happened.
  @first_render_size 10
  @page_size 20
  # What a source switch loads (see `load_source_filter/2`) — deliberately
  # smaller than either, because that press is a wait with nothing on screen to
  # read while it lasts.
  @filter_page_size 10
  # What opening a *busy* calendar day loads (see `load_day/2`). Sized like a
  # source switch and for the same reason: the reader is waiting on an empty
  # column.
  @travel_page_size 10
  # A day with fewer entries than this is loaded whole on the first press, so
  # the ordinary case has no "Load more" under it at all. A day is a bounded
  # thing the reader asked to see, not an endless timeline, and paging through
  # a Tuesday ten posts at a time is busywork the feed can just do for them.
  #
  # The number is an upper bound handed to `feed_page/2`, not a fetch of a
  # hundred rows: a day holding three costs three. What decides which branch a
  # day takes is the heatmap's own count for it, which is already on the socket
  # (`@cal_counts`) — so knowing the day's size costs no query of its own.
  @day_full_limit 100
  # …and the ceiling on "load the whole day" for the days above that. Somebody
  # opening a day with four thousand entries wants to read it, not to render it,
  # so the button stops here and leaves "Load more" for the rest.
  @day_all_limit 1_000
  # "New here" rail: how many newcomers to greet, the size of the newest-members
  # pool they are drawn out of, how many of each one's tags the card shows, and
  # how often an open feed redraws. Defined here (not beside
  # `assign_newcomers`) so `mount_feed/2` above reads a real value — a module
  # attribute is `nil` until the line that sets it.
  @newcomers 5
  @newcomer_pool 30
  @tags_per_newcomer 3
  @suggestions_refresh :timer.minutes(5)
  # How many waiting posts the "not read yet" card names before it stops at a
  # count.
  @unread_shown 10
  # …and how many the timeline holds drawn-but-hidden before the pre-render gives
  # up. It is the overflow valve for the tab nobody closed: every arrival costs a
  # rendered card in the document and a decorated entry in this process (~9 KB
  # measured), and a feed left open over a weekend delivers those by the
  # thousand. Past this many the newest are kept and the oldest is dropped again,
  # so the card keeps describing what actually just happened; the rest are only
  # counted, and the press falls back to loading a fresh page — which after a
  # weekend is what the reader wants anyway, not four hundred stale rows.
  @pending_cap 25

  # The rail's cards, in the order a member who never touched them gets. The
  # list is what `Vutuv.Posts.feed_rail/2` measures a stored arrangement
  # against, so a card added here turns up at the end for everybody who already
  # arranged theirs, and a card removed here leaves no orphan behind. The
  # machine-format footer is deliberately not one of them: it is the page's
  # colophon, not a card anybody curates.
  # The order and the folded set are a product decision, not an alphabet, and
  # both were arrived at by arranging the real thing rather than on paper
  # (Stefan, 2026-08-28 — this is his own rail, taken as the default). Your own
  # topics lead, then what arrived while you were reading, then the two hide
  # lists, then the newcomers to greet, and the switch panel comes last: it is
  # where you go when something is wrong, not something you read.
  #
  # Two of them ship folded to their heading. A card that is mostly a control
  # you rarely touch still has to be *findable*, and a heading is what makes it
  # findable — where the open card would only be a wall of checkboxes between
  # you and the next thing you actually read.
  @rail_blocks ~w(followed_tags unread hidden_tags words newcomers sources)
  @rail_collapsed ~w(hidden_tags sources)

  @doc """
  How many entries a `/feed` arrival carries.

  Public because the agent-format siblings serve the same page
  (`VutuvWeb.NewsfeedController`) and a number mirrored by hand across two
  modules is a number that drifts.
  """
  def first_page_size, do: @first_page_size

  @impl true
  # Rendered by VutuvWeb.NewsfeedController via `live_render` (off-router, so it
  # can negotiate the agent-format siblings), exactly like UserProfileLive. An
  # off-router LiveView can't use `InitAssigns` as an `on_mount` — that hook
  # attaches a `:handle_params` hook, which it rejects — so mount mirrors it:
  # load the viewer + locale from the session the controller passes, and gate on
  # login here instead of the `:require_login` stage.
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)

    if user = socket.assigns.current_user do
      {:ok, mount_feed(socket, user, calendar_from_url(session))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You must be logged in to access that page"))
       |> redirect(to: ~p"/login")}
    end
  end

  defp mount_feed(socket, user, {day, open?}) do
    # The sources they left on (issue #1499). It opens the page *and* keys the
    # handoff below: the stash holds one entry per member, so two devices
    # opening /feed within its 15s TTL would otherwise let one take a page the
    # other computed for a different tab. Keyed by the filter, a mismatch is
    # simply a miss and that mount loads its own page.
    remembered = Posts.remembered_feed_filter(user)

    if connected?(socket) do
      Vutuv.Activity.subscribe(user.id)
      # Refresh the Berlin-day-relative post stamps ("09:50 Uhr" -> "Gestern,
      # 09:50 Uhr") the moment the German day rolls over at midnight.
      Vutuv.DayClock.subscribe()
      # The "New here" card draws other newcomers while the feed stays open.
      Process.send_after(self(), :refresh_suggestions, @suggestions_refresh)

      # The dead render stashed its computed page seconds ago
      # (VutuvWeb.Live.MountHandoff); take it and skip re-running the same
      # queries. Any miss (expired, consumed, a reconnect) recomputes.
      case MountHandoff.take(user.id, {:feed, remembered, day}) do
        # The dead render's short page (`@first_render_size`), so this mount
        # owes the reader the rest of the arrival — see `:fill_arrival` below.
        {:ok, payload} ->
          apply_feed_payload(socket, payload, day, open?)

        # No stash to take (a reconnect, an expired one, a socket that arrived
        # without a dead render): nothing has been drawn yet, so there is no
        # short page to extend and this mount loads the whole arrival at once.
        :error ->
          payload = feed_payload(user, remembered, day, @first_page_size)
          apply_feed_payload(socket, payload, day, open?)
      end
    else
      payload = feed_payload(user, remembered, day, @first_render_size)
      MountHandoff.stash(user.id, {:feed, remembered, day}, payload)
      apply_feed_payload(socket, payload, day, open?)
    end
  end

  # Everything a feed mount computes, as data — what the dead render hands the
  # connected mount through the single-use stash.
  defp feed_payload(user, remembered, day, limit) do
    # The member's private content filters (issue #940): compiled once, applied
    # to every page, and the set of posts they chose to reveal anyway.
    compiled = ContentFilters.compile_for(user)

    # The gate before the page, because it decides which tab this mount opens
    # on: a remembered "Fediverse" whose content has gone away shows no tab bar
    # at all, and stranding them on the tab behind it would leave a timeline
    # they cannot get out of. The stored value stays untouched, so the tab
    # comes back with the content.
    # A member the fediverse does not reach has nothing to narrow, so a stored
    # "vutuv only" would be a filter they cannot see and could not lift — the
    # same fold `fediverse_feed_available?/1` did for the tab bar.
    filter = if Posts.fediverse_feed_available?(user), do: remembered, else: :all

    # A day-link arrival (`/feed?day=…`) fetches THAT day's page here rather
    # than fetching the present and re-fetching a moment later: mounting at now
    # and then re-streaming the day leaves both pages on the client, because a
    # stream reset in the same mount that populated it does not take.
    #
    # A named day asks for the whole-day limit outright. That is an upper bound,
    # so a quiet day still costs its own size; what it buys is not having to run
    # the nine-source counter here purely to choose between two page sizes,
    # which is the most expensive query on the page and was being run twice per
    # arrival for one number.
    page =
      Posts.feed_page(user,
        limit: if(day, do: @day_full_limit, else: limit),
        cursor: FeedTimeTravel.day_cursor(day),
        filter: filter
      )

    entries = page.entries |> with_engagement(user) |> mark_filtered(compiled, user.id)

    # Read the stored draft once and hand it to the composer below, which then
    # skips its own identical query on init.
    draft = Posts.get_draft(user)

    %{
      content_filters: compiled,
      more?: page.more?,
      cursor: page.next_cursor,
      draft: draft,
      entries: entries,
      # Which sources these entries were pulled for — what the band's two
      # source checkboxes show, and what a switch there changes.
      filter: filter,
      # Whether this page is the dead render's short one and the arrival still
      # owes the reader cards. Carried rather than inferred from the entry
      # count: a genuinely short feed (a quiet day, a new member) also has
      # fewer than `@first_render_size` entries and owes nothing.
      partial?: limit < @first_page_size and page.more?,
      # The desktop rail renders WITH the page: it was lazy-loaded for one
      # release (v7.200.3) and the pop-in read as slowness, so it is eager
      # again — computed here once, riding the handoff to the connected mount.
      # Phones keep it hidden by CSS; that they pay its queries on the dead
      # render is the accepted cost of the immediate desktop paint.
      rails: rail_data(user)
    }
  end

  # Everything the three rail cards render, as data. Shared by the payload
  # (mount) and the socket-side redraw helpers below, so mount and refresh
  # cannot drift.
  defp rail_data(user) do
    Map.merge(
      %{followed_tags: Vutuv.Tags.followed_tags(user)},
      newcomer_rail(user)
    )
  end

  # The stream is rebuilt here rather than riding the payload: a
  # %Phoenix.LiveView.LiveStream{} carries per-socket insert state that the
  # dead render already consumed, so handing the struct itself to the
  # connected socket would replay as an empty feed.
  defp apply_feed_payload(socket, payload, day, open?) do
    socket
    # On-demand translations (issue #1462): the per-card view state. A map
    # means this viewer gets the controls, nil means they do not — the cards
    # read that straight off the one assign.
    |> assign(:post_translations, PostTranslations.initial_map(socket.assigns.current_user))
    |> assign(:content_filters, payload.content_filters)
    |> assign(:revealed_filters, MapSet.new())
    |> assign(:page_title, gettext("Feed"))
    # Which sources this mount opened on (issue #1499) — from here on the
    # assign is the truth, and the stored column is not read again while the
    # page lives.
    |> assign(:feed_filter, payload.filter)
    |> assign(:more?, payload.more?)
    |> assign(:cursor, payload.cursor)
    |> assign(:empty?, payload.entries == [])
    |> assign(:pending_posts, [])
    # How many arrivals the cap turned away. Nonzero means the timeline no longer
    # holds a row for every waiting post, so the press has to load a page.
    |> assign(:pending_overflow, 0)
    # The calendar's own state: whether it is unfolded, which month is on
    # screen, which reading its heatmap shades, and which day (if any) the
    # reader opened. `cal_day` is a Date rather than a moment because it names a
    # WINDOW — a whole day, first minute to last.
    #
    # Folded and on today by default. The calendar is a way *out* of the
    # present, and most visits to a feed are not that: unfolded by default it
    # would put six rows of month between the composer and the first post for
    # every reader who never travels. `restore_calendar/2` unfolds it again for
    # an arrival that names a day in the URL.
    |> assign(:cal_open?, open?)
    |> assign(:cal_month, FeedTimeTravel.month_of(day))
    |> assign(:cal_metric, "feed")
    |> assign(:cal_day, day)
    # The reader's own calendar day, held as state rather than read inside the
    # card: it decides the date the folded card shows, which cell wears the
    # today ring and which cells are refused as future, and a page left open
    # past midnight has to be told. `:day_changed` below moves it.
    |> assign(:cal_today, ViewerClock.today())
    |> defer_calendar_counts()
    |> assign(:draft, payload.draft)
    # The composer starts collapsed to a single "What's new?" button; posting
    # (own activity arriving below) collapses it again. A stored draft opens it
    # instead (issue #1148): the composer will restore that draft, and text
    # hidden behind a collapsed panel is indistinguishable from text that was
    # thrown away. Resolved here rather than announced by the composer so the
    # disconnected render already agrees and the panel never flickers open.
    |> assign(:composer_open?, payload.draft != nil)
    # The set of entries currently on screen, kept so the midnight :day_changed
    # tick can re-render each stamp in place (streams don't retain their data).
    # Order/dupes don't matter: the refresh uses stream_insert update_only, which
    # updates existing rows where they sit and ignores ones already gone.
    |> assign(:entries, payload.entries)
    |> rebase_seam(payload.entries)
    # The posts on screen we hold a photo-scan subscription for (below).
    |> assign(:photo_watch, MapSet.new())
    # How this member arranged the rail: the order of its cards, which are
    # folded to their heading and which they put away. Read from the member the
    # session already loaded, so the very first (dead) render draws the rail the
    # way they left it rather than the default order and then rearranging it
    # once the socket connects.
    |> assign(:rail, Posts.feed_rail(socket.assigns.current_user, @rail_blocks, @rail_collapsed))
    # The phone's filter sheet, closed at mount. Deliberately not remembered
    # across a reconnect: a sheet is a thing the reader opened a moment ago and
    # a rejoin that reopened it over their feed would be a patch nobody asked
    # for. Everything it changes is written through and survives anyway.
    |> assign(:band_sheet?, false)
    # Bumped whenever follow/mute state changes OUTSIDE the filter band (the
    # remote card menu's mute and unfollow), so the band's gated sources card
    # re-reads its lists — its own writes force a reload themselves, and
    # nothing else on this page touches that state.
    |> assign(:band_refresh, 0)
    # The name the follow field could not resolve, so the card can say so.
    |> assign(:tag_missing, nil)
    |> assign(payload.rails)
    # The follow-a-tag suggestions ride the first paint like the rest of the
    # rail. Computed from what is already in hand rather than through
    # `assign_followed_tags/1`, which would re-run the query the payload just
    # answered.
    |> assign(
      :tag_suggestions,
      Vutuv.FeedBand.tags_on_page(payload.entries,
        except: Enum.map(payload.rails.followed_tags, &(&1.name || &1.slug)),
        limit: 5
      )
    )
    |> stream_configure(:posts, dom_id: &"feed-#{&1.id}")
    |> stream(:posts, payload.entries)
    |> watch_pending_photos(payload.entries)
    |> auto_translate_entries(payload.entries)
    |> fill_arrival(payload)
  end

  # The rest of the arrival, once the document the reader is looking at has
  # been drawn. The dead render carries `@first_render_size` cards so the page
  # arrives; this asks for the remainder as soon as the socket is up, and it
  # lands below the fold.
  #
  # A message to self rather than a load here: mount has to return before the
  # stream exists on the client, and appending to a stream in the same mount
  # that populated it does not take (the same trap the day-link arrival above
  # documents for `reset:`).
  defp fill_arrival(socket, %{partial?: true}) do
    if connected?(socket) do
      send(self(), :fill_arrival)
      # What the fill is owed *for*. The message sits in the mailbox behind
      # anything the reader does in the meantime, and by the time it is handled
      # they may be looking at a different timeline — an opened calendar day is
      # the one that matters, since appending an older page there would spill
      # cards from before that day into it. So the fill is claimed rather than
      # assumed, and every reset below drops the claim.
      assign(socket, :owes_fill?, true)
    else
      assign(socket, :owes_fill?, false)
    end
  end

  defp fill_arrival(socket, _whole_page), do: assign(socket, :owes_fill?, false)

  # Every post on the page whose photo is still with the AI image scan gets a
  # subscription to its own topic, so the placecard swaps itself for the picture
  # with no reload — the arrangement the permalink's conversation already uses.
  # Deliberately not one subscription per card (a feed carries dozens): the set
  # is keyed on posts that are actually waiting, which in steady state is none
  # of them, and a verdict lands within seconds. The viewer's OWN posts would
  # reach them over their activity topic anyway; this is what covers the posts
  # they are merely reading, which is the case that sent somebody looking for a
  # reply they had just been notified about.
  defp watch_pending_photos(socket, entries) do
    if connected?(socket) do
      watched = socket.assigns.photo_watch

      fresh =
        for %{post: %Post{} = post} <- entries,
            Posts.held_for_image_check?(post),
            not MapSet.member?(watched, post.id),
            into: MapSet.new(),
            do: post.id

      Enum.each(fresh, &Posts.subscribe_post/1)
      assign(socket, :photo_watch, MapSet.union(watched, fresh))
    else
      socket
    end
  end

  # Translate mode (issue #1461): fold the page's foreign-language subjects
  # into the translations map — cached rows show at once, the rest queue and
  # swap in live. Only on the connected socket: the dead render is replaced
  # moments later, and the jobs it would enqueue are the same deduped ones.
  defp auto_translate_entries(socket, entries) do
    viewer = socket.assigns.current_user

    if connected?(socket) and PostTranslations.auto_translate?(viewer) do
      subjects = Enum.flat_map(entries, &entry_subjects/1)
      map = PostTranslations.auto_translate(socket.assigns.post_translations, subjects, viewer)
      assign(socket, :post_translations, map)
    else
      socket
    end
  end

  # The record a feed entry is about: a remote reply, a cached remote post, or
  # the vutuv post itself. Spelled once, because every question this module asks
  # of an entry that is really a question about the post behind it — its id, the
  # line the ticker quotes, what could be translated — used to re-derive it, and
  # a fourth entry shape would have had to be remembered in each.
  defp entry_record(entry) do
    cond do
      Posts.remote_reply_entry?(entry) -> entry.note
      Posts.remote_feed_entry?(entry) -> entry.remote_post
      true -> entry.post
    end
  end

  # What a feed entry shows that could be translated: its own post (plus the
  # nested ancestors of a reply), a cached remote post, or a remote reply.
  defp entry_subjects(entry) do
    case entry_record(entry) do
      %Post{} = post -> [post | entry[:ancestors] || []]
      remote -> [remote]
    end
  end

  # The desktop "New here" rail: five of the newest members, drawn at random out
  # of the newest `@newcomer_pool` who show a face, minus the viewer, anyone
  # blocked either way and everyone they already follow.
  #
  # It replaces a most-followed / most-endorsed suggestion rail, and the swap is
  # the point rather than a change of source. A ranked rail shows the same
  # already-well-connected members to everybody, and the one member for whom
  # being seen actually decides whether they stay — the person who signed up
  # this morning — is exactly the one it can never reach. Drawing at random from
  # the newest instead gives every newcomer a real chance of being greeted, and
  # gives the reader a card that is never the same twice.
  #
  # The random draw is made **here**, not at render: it has to survive every
  # re-render of the page, and only a fresh draw (a reshuffle, the periodic
  # tick, a new mount) may change who is on it.
  defp newcomer_rail(user) do
    # Never suggest a member the viewer blocked (or who blocked them): the follow
    # would be refused as :blocked and the suggestion would just reappear.
    blocked = Social.blocked_user_ids(user.id)

    candidates =
      @newcomer_pool
      |> Social.newest_members_with_avatar()
      |> Enum.reject(&(&1.id == user.id or MapSet.member?(blocked, &1.id)))

    following = UserHelpers.following_map(user, candidates)

    users =
      candidates
      |> Enum.reject(&Map.has_key?(following, &1.id))
      |> Enum.take_random(@newcomers)

    %{
      newcomers: newcomer_rows(users),
      # Every newcomer on a fresh draw is by construction someone the viewer
      # does not follow, so every pill starts in its "Follow" state. The map
      # fills as they welcome people (`assign_following/1`), which is what keeps
      # a greeted row on the card instead of making the person vanish.
      following_by_id: %{}
    }
  end

  # The drawn members as finished rows: the member, the muted meta line under
  # their name, and their tag sample with a count of what it leaves out.
  # Assembled here rather than looked up out of three parallel maps in the
  # markup, so the template renders a row instead of joining tables and each
  # batched query is asked exactly once per draw.
  #
  # The tags are drawn at random rather than in the profile's
  # most-endorsed-first order on purpose: a member who signed up this week has
  # no endorsements at all, so that order collapses to alphabetical and the card
  # would show the same three tags of theirs forever. Three is a glance at what
  # somebody is about, which is all this card is for — the whole list is one
  # click away on their profile.
  defp newcomer_rows(users) do
    work_info = UserHelpers.work_information_map(users, 60)
    tags_by_user = Vutuv.Tags.user_tags_by_user(users)

    Enum.map(users, fn user ->
      tags = Map.get(tags_by_user, user.id, [])
      sample = Enum.take_random(tags, @tags_per_newcomer)

      %{
        user: user,
        work: Map.get(work_info, user.id, ""),
        tags: sample,
        more: length(tags) - length(sample)
      }
    end)
  end

  defp assign_newcomers(socket) do
    socket
    |> assign(newcomer_rail(socket.assigns.current_user))
    |> assign_following()
  end

  # Which members on the card the viewer follows right now, in one query — the
  # same `%{followee_id => follow_id}` map every other people listing renders
  # its follow pills from. Recomputed after a welcome (and after taking one
  # back) rather than patched by hand, so a pill cannot drift from the follow
  # table.
  defp assign_following(socket) do
    users = Enum.map(socket.assigns.newcomers, & &1.user)
    follows = UserHelpers.following_map(socket.assigns.current_user, users)
    assign(socket, :following_by_id, follows)
  end

  # The desktop "Tags you follow" rail (issue #872): the member's tag
  # subscriptions as chips, each with a reload-free ✕ unfollow. Refreshed
  # whenever the follow set changes (an unfollow here, or a follow/unfollow made
  # on a tag page while this feed is open — see the :tag_follows_changed handler).
  defp assign_followed_tags(socket) do
    followed = Vutuv.Tags.followed_tags(socket.assigns.current_user)

    socket
    |> assign(:followed_tags, followed)
    # What the card offers to follow: the tags on the page, minus the ones this
    # reader already follows. Computed here rather than in the card so both it
    # and the "Hide tags" card read one list (`FeedBand.tags_on_page/2`).
    |> assign(
      :tag_suggestions,
      Vutuv.FeedBand.tags_on_page(socket.assigns[:entries] || [],
        except: Enum.map(followed, &(&1.name || &1.slug)),
        limit: 5
      )
    )
  end

  # The ↻ both rail cards wear: one control, one glyph, one set of colours.
  # Rendered by "New here" and by "Suggested posts", which want the identical
  # affordance ("show me another draw") and differ only in what they say and
  # which event they push.
  attr(:id, :string, required: true)
  attr(:event, :string, required: true)
  attr(:label, :string, required: true)

  defp reshuffle_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      title={@label}
      aria-label={@label}
      class="text-slate-500 transition hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-200"
    >
      <svg
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.5"
        stroke="currentColor"
        class="h-4 w-4"
        aria-hidden="true"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182m0-4.991v4.99"
        />
      </svg>
    </button>
    """
  end

  # Pre-load the action-bar engagement AND the viewer's follow edge to each
  # author for the whole page in one query each, and hang them on each entry, so
  # the per-card Actions LiveViews don't each run their own query (was one query
  # per post) and the card's mute toggle knows its follow id + state without a
  # per-row lookup. A threaded reply nests the whole conversation it answers as
  # full cards, so every ancestor post id joins the same engagement batch and
  # each entry carries a `%{post_id => engagement}` submap for those cards' bars.
  # Live-arriving single posts carry `engagement: nil` (falls back to the bar's
  # own query) and get their follow edge in `insert_entry/3`.
  # The newest waiting post as the pair the pill quotes, or nil when there is
  # nothing to quote: a photo with no caption, an author we cannot name, or a
  # post this reader's own filters hide. The row below it folds to a placeholder
  # (`hidden_by_filter?/2`) while the pill above it read the muted words out —
  # and a teaser is the one place they cannot scroll past them (issue #940).
  # Both read the same `:filtered_by` stamp, so the two cannot disagree.
  defp newest_quote([%{filtered_by: pattern} | _rest]) when is_binary(pattern), do: nil

  defp newest_quote([newest | _rest]) do
    case {PostTeaser.who(newest), PostTeaser.text(newest)} do
      {nil, _text} -> nil
      {_who, nil} -> nil
      {who, text} -> %{who: who, text: text}
    end
  end

  # Write an arrangement change through and keep the socket's copy in step. The
  # column is the truth here and the assign is a copy of it, so both move
  # together or a second change would be computed from a stale rail.
  defp save_rail(socket, fun) do
    rail = fun.(socket.assigns.rail)
    {:ok, _stored} = Posts.save_feed_rail(socket.assigns.current_user, rail)

    assign(socket, :rail, rail)
  end

  defp toggle_rail_member(rail, field, key) do
    current = Map.fetch!(rail, field)
    next = if key in current, do: current -- [key], else: [key | current]

    Map.put(rail, field, next)
  end

  # Whether a card has anything to say right now. A card that is empty is not
  # rendered at all rather than rendered empty, which is what the `:if`s on the
  # old rail did — but it stays in the stored order, so it returns to its own
  # place rather than to the end of the rail when it fills up again.
  defp rail_showing?(key, assigns) do
    key not in assigns.rail.removed and rail_filled?(key, assigns)
  end

  defp rail_filled?("unread", assigns), do: assigns.pending_posts != []
  # Always: the card is where a tag is followed, so hiding it until one already
  # is would put the first follow behind a tag page — the long way round this
  # card exists to remove.
  defp rail_filled?("followed_tags", _assigns), do: true
  defp rail_filled?("newcomers", assigns), do: assigns.newcomers != []
  defp rail_filled?(_key, _assigns), do: true

  # What a card is called, for the chip that offers it back. It is the same
  # string the card's own heading uses — one list, so a renamed card cannot be
  # offered back under its old name.
  defp rail_title("unread"), do: gettext("Not read yet")
  # Named for what the card holds, not for what switching things off achieves:
  # "What gets through" described an effect and left a reader guessing whether
  # the card was a list, a rule or a report (Stefan, 2026-08-28). It lists the
  # sources of the timeline at three levels — the two halves, the servers, the
  # accounts — so that is what it is called.
  defp rail_title("sources"), do: gettext("Sources")
  defp rail_title("words"), do: gettext("Hide words")
  defp rail_title("hidden_tags"), do: gettext("Hide tags")
  defp rail_title("followed_tags"), do: gettext("Tags you follow")
  defp rail_title("newcomers"), do: gettext("New here")

  # The chrome every rail card wears, and the only place the three arranging
  # controls live: the grip that drags it, the caret that folds it to its
  # heading, and the ✕ that takes it out of the rail altogether (it comes back
  # from the chips below the rail). One component rather than a copy per card,
  # so the arrangement cannot work on four of them and quietly not on the fifth.
  #
  # `count` is the figure that keeps a folded card worth folding: collapsed, the
  # heading and that number are all there is, so "Not read yet · 3" still
  # answers the question the card exists for.
  attr(:key, :string, required: true)
  attr(:title, :string, required: true)
  attr(:rail, :map, required: true)
  attr(:count, :string, default: nil)
  attr(:dot, :boolean, default: false)
  slot(:action)
  slot(:inner_block, required: true)

  defp rail_block(assigns) do
    assigns = assign(assigns, :collapsed?, assigns.key in assigns.rail.collapsed)

    ~H"""
    <section
      id={"rail-#{@key}"}
      data-rail-block={@key}
      data-id={@key}
      class="rounded-2xl bg-white p-6 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
    >
      <div class={["flex items-center gap-2", not @collapsed? && "mb-3"]}>
        <%!-- The grip is a real button, not a decorative span: dragging is a
        pointer gesture and the rail has to be arrangeable without one, so it
        takes ↑/↓ from the keyboard as well (the Reorder hook). --%>
        <button
          type="button"
          data-reorder-handle
          aria-label={gettext("Move %{card}", card: @title)}
          title={gettext("Drag, or use the arrow keys")}
          class="rail-handle -ml-1 flex h-6 w-4 shrink-0 items-center justify-center rounded text-slate-300 hover:text-slate-500 focus-visible:outline-2 focus-visible:outline-brand-500 dark:text-slate-600 dark:hover:text-slate-400"
        >
          <span aria-hidden="true">⠿</span>
        </button>
        <span
          :if={@dot}
          class="h-2 w-2 shrink-0 rounded-full bg-emerald-500"
          aria-hidden="true"
        >
        </span>
        <.section_title class="min-w-0 flex-1 truncate">{@title}</.section_title>
        <span :if={@count} class="shrink-0 text-xs tabular-nums text-slate-500 dark:text-slate-400">
          {@count}
        </span>
        {render_slot(@action)}
        <button
          type="button"
          phx-click="rail-collapse"
          phx-value-key={@key}
          aria-expanded={to_string(not @collapsed?)}
          aria-label={
            if @collapsed?,
              do: gettext("Unfold %{card}", card: @title),
              else: gettext("Fold %{card}", card: @title)
          }
          class="flex h-6 w-6 shrink-0 items-center justify-center rounded text-slate-400 hover:bg-slate-100 hover:text-slate-700 dark:hover:bg-slate-800 dark:hover:text-slate-200"
        >
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
            class={["h-4 w-4 transition-transform", @collapsed? && "-rotate-90"]}
          >
            <path d="M6 9l6 6 6-6" />
          </svg>
        </button>
        <button
          type="button"
          phx-click="rail-remove"
          phx-value-key={@key}
          aria-label={gettext("Remove %{card}", card: @title)}
          title={gettext("Remove %{card}", card: @title)}
          class="flex h-6 w-6 shrink-0 items-center justify-center rounded leading-none text-slate-400 hover:bg-slate-100 hover:text-slate-700 dark:hover:bg-slate-800 dark:hover:text-slate-200"
        >
          <span aria-hidden="true">×</span>
        </button>
      </div>
      <div :if={not @collapsed?}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  # The rail's "not read yet" card: one line per waiting post — who wrote it and
  # how it opens — plus the one button that brings them all down. The teaser is
  # `VutuvWeb.PostTeaser`, the same pair of strings the browser-tab title uses,
  # so a post reads the same wherever it is quoted.
  #
  # Ten rows, newest first. It was four, which on a quiet morning meant the card
  # named a fraction of what was waiting and the rest arrived unannounced; ten is
  # what a rail card holds without becoming a second timeline (Stefan,
  # 2026-08-29). The rest are still counted in the heading and still arrive with
  # the button.
  attr(:entries, :list, required: true)
  attr(:total, :integer, required: true)
  attr(:click, :any, required: true)

  defp unread_body(assigns) do
    assigns = assign(assigns, :shown, Enum.take(assigns.entries, @unread_shown))

    ~H"""
    <div id="unread-posts">
      <button
        :for={entry <- @shown}
        type="button"
        phx-click={@click}
        class="flex w-full items-start gap-2 border-t border-slate-100 py-2 text-left first:border-t-0 first:pt-0 hover:bg-slate-50 dark:border-slate-800 dark:hover:bg-slate-800/50"
      >
        <span class="min-w-0 flex-1">
          <span class="block truncate text-xs text-slate-500 dark:text-slate-400">
            {PostTeaser.who(entry)}
          </span>
          <span class="block truncate text-sm text-slate-800 dark:text-slate-200">
            {PostTeaser.text(entry) || gettext("A photo")}
          </span>
        </span>
      </button>

      <%!-- It says where the posts go, not what happens to them: "Add" named the
      mechanism (they are inserted into the stream) and left the reader to guess
      where, which on a card that is itself a list of posts reads as if it would
      add them here (Stefan, 2026-08-29). --%>
      <.button id="unread-insert" variant="secondary" class="mt-3 w-full" phx-click={@click}>
        {ngettext(
          "Show %{formatted} post in the feed",
          "Show %{formatted} posts in the feed",
          @total,
          formatted: compact_count(@total)
        )}
      </.button>
    </div>
    """
  end

  # The tag chips the viewer subscribed to, each with a reload-free ✕, plus the
  # field that adds one.
  #
  # Following a tag used to mean finding its page first, which is a long way
  # round for something the reader is looking straight at: the suggestions come
  # from the posts on the page (`FeedBand.tags_on_page/2`, the same list the
  # "Hide tags" card offers to mute).
  attr(:tags, :list, required: true)
  attr(:suggestions, :list, required: true)
  attr(:missing, :string, default: nil)

  defp followed_tags_body(assigns) do
    ~H"""
    <div>
      <div id="followed-tags" class="flex flex-wrap items-start gap-2">
      <span
        :for={tag <- @tags}
        id={"followed-tag-#{tag.id}"}
        class="inline-flex max-w-full items-center gap-1 rounded-lg bg-brand-50 py-1 pl-3 pr-1.5 text-sm font-medium text-brand-700 dark:bg-brand-900/40 dark:text-brand-100"
      >
        <%!-- No leading "#", on the chip or in the ✕'s accessible name. The chip
        is already inside a card named after tags, and the two cards beside it
        dropped theirs for the same reason (Stefan, on the fourth demo and again
        2026-08-28); a label that kept the hash would leave the sighted and the
        screen-reader vocabulary saying different things. --%>
        <.link navigate={~p"/tags/#{tag}"} class="min-w-0 truncate hover:underline">
          {tag.name || tag.slug}
        </.link>
        <button
          type="button"
          phx-click="unfollow_tag"
          phx-value-id={tag.id}
          title={gettext("Unfollow")}
          aria-label={gettext("Unfollow the tag %{tag}", tag: tag.name || tag.slug)}
          class="flex h-4 w-4 flex-shrink-0 items-center justify-center rounded-full leading-none text-brand-500 transition hover:bg-brand-100 hover:text-brand-800 dark:text-brand-300 dark:hover:bg-brand-800 dark:hover:text-brand-100"
        >
          <span aria-hidden="true">×</span>
        </button>
      </span>

        <%!-- The "+" rides the chip row, so adding a tag costs no height of
        its own at all; open, the field takes the row's full width. --%>
        <.rail_add_field
          label={gettext("Follow a tag …")}
          placeholder={gettext("Follow a tag …")}
          submit="follow_tag"
          name="name"
          maxlength="60"
        />
      </div>

      <%!-- A tag is only followed if it exists. Minting one because somebody
      typed a word into a follow box would put an empty topic into a namespace
      every member shares, and the reader would be its only inhabitant — so an
      unknown name says so and points at the directory instead. --%>
      <p :if={@missing} class="pt-1 text-xs text-slate-500 dark:text-slate-400">
        {gettext("No tag called %{name} yet.", name: @missing)}
        <.link
          navigate={~p"/tags"}
          class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Browse the tags")}
        </.link>
      </p>

      <div :if={@suggestions != []} class="pt-2">
        <p class="pb-1 text-xs text-slate-500 dark:text-slate-400">
          {gettext("In your feed right now:")}
        </p>
        <div class="flex flex-wrap gap-2">
          <button
            :for={name <- @suggestions}
            type="button"
            phx-click="follow_tag"
            phx-value-name={name}
            class="rounded-lg bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-600 hover:bg-slate-200 hover:text-slate-900 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-slate-700 dark:hover:text-slate-100"
          >
            {name}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:newcomers, :list, required: true)
  attr(:current_user, :map, required: true)
  attr(:following_by_id, :map, required: true)

  defp newcomers_body(assigns) do
    ~H"""
    <div id="newcomers">
      <%!-- "A few of" carries the whole draw: these are not *the* newest members
      in order, they are a random handful out of them, and a sentence that says
      "the most recently joined" promises a ranking the ↻ visibly contradicts. It
      also stays true on a quiet installation (an intranet vutuv with forty
      members), where the newest member may have been here for months. --%>
      <p class="mb-4 text-sm text-slate-600 dark:text-slate-400">
        {gettext("A few of the newest members. Following them is a warm welcome.")}
      </p>
      <ul class="space-y-4">
        <li :for={row <- @newcomers} id={"newcomer-#{row.user.id}"} class="flex items-start gap-3">
          <.link href={~p"/#{row.user}"} class="shrink-0">
            <.avatar
              user={row.user}
              size="sm"
              alt={gettext("Profile picture of %{name}", name: UserHelpers.full_name(row.user))}
            />
          </.link>
          <div class="min-w-0 flex-1">
            <%!-- Only the name shares a line with the Follow pill. The meta line
            below it runs the full column width instead, which is what makes it
            readable at all: the pill is 5.5rem wide in a rail a third of the
            page across, so beside it "seit 9 Tagen dabei · Privatier @ JL" was
            cut mid-word. --%>
            <div class="flex items-start gap-2">
              <.link
                href={~p"/#{row.user}"}
                class="min-w-0 flex-1 truncate text-sm font-medium text-slate-800 hover:text-brand-700 dark:hover:text-brand-300 dark:text-slate-100"
              >
                {UserHelpers.full_name(row.user)}
              </.link>
              <.follow_button
                variant="text"
                follower_id={@current_user.id}
                followee_id={row.user.id}
                follow_id={Map.get(@following_by_id, row.user.id)}
                live?
              />
            </div>
            <%!-- The job title, when there is one. It used to lead with how long
            the member had been here ("seit 3 Tagen dabei · …"), which was
            interesting and cost a third of the row for a fact the card's own
            heading already makes — five rows deep, that bought nothing (Stefan,
            2026-08-24). A member with no job filled in, which most have not on
            their first days, simply gets no line rather than an empty one. --%>
            <p
              :if={row.work != ""}
              class="mb-0 mt-0.5 truncate text-xs text-slate-600 dark:text-slate-400"
            >
              {row.work}
            </p>
            <%!-- Three tags, at rail scale, each a link to that topic: enough to
            be curious about somebody, never their whole profile. The +N is what
            the sample leaves out and leads to the rest of them; it is the
            tag-specific plural the member directory already uses, not a bare
            "+3". --%>
            <div
              :if={row.tags != []}
              data-newcomer-tags={row.user.id}
              class="mt-1.5 flex flex-wrap items-center gap-1"
            >
              <.chip :for={user_tag <- row.tags} size="sm" navigate={~p"/tags/#{UserTag.tag(user_tag)}"}>
                <span aria-hidden="true">#</span>{UserTag.truncated_name(user_tag)}
              </.chip>
              <.link
                :if={row.more > 0}
                navigate={~p"/#{row.user}/tags"}
                class="text-xs font-medium text-slate-600 hover:text-brand-700 dark:text-slate-400 dark:hover:text-brand-300"
              >
                {ngettext("+1 more tag", "+%{formatted} more tags", row.more,
                  formatted: compact_count(row.more)
                )}
              </.link>
            </div>
          </div>
        </li>
      </ul>
      <.card_footer_link href={~p"/system/members"}>
        {gettext("All members")}
      </.card_footer_link>
    </div>
    """
  end

  # The one-line stand-in for a content-filtered post (issue #940): says which
  # filter hid it and offers to show it anyway, in place.
  attr(:pattern, :string, required: true)

  attr(:key, :string,
    required: true,
    doc: "what the reveal set remembers this entry by (`filter_key/1`), not always a post id"
  )

  attr(:record, :any,
    default: nil,
    doc: "the post that matched — regularly an ancestor, not the post the row is keyed on"
  )

  defp filtered_placeholder(assigns) do
    assigns = assign(assigns, :author, assigns.record && PostTeaser.author_of(assigns.record))

    ~H"""
    <%!-- Two lines, and **exactly** two: this is a fold, so every line it takes
    is a line it fails to save. It used to wrap to three whenever a phrase
    filter was longer than a few words — the pattern set the row's height, and a
    member who wrote a whole sentence into /settings/filters got a taller
    placeholder than the post would have been (Stefan, 2026-08-29). Now the
    pattern truncates and nothing here can grow. --%>
    <div
      data-filtered-post={@pattern}
      class="rounded-2xl bg-slate-50 px-4 py-3 text-sm text-slate-600 ring-1 ring-slate-200 dark:bg-slate-900/50 dark:text-slate-400 dark:ring-slate-800"
    >
      <%!-- Whose post this was, and when. A row that says only "hidden" makes
      the reader open it to find out whether it is worth opening, which is the
      one thing a fold is supposed to save them (Stefan, 2026-08-28). The name
      is the matching post's own — in a conversation that is regularly an
      ancestor rather than the post the row is keyed on, and naming the row
      would name the wrong person.

      "Show anyway" rides at the far end of this same line rather than on one of
      its own. It is the row's only control, and a line holding one link is a
      line spent on nothing else. --%>
      <div class="flex items-baseline gap-x-2">
        <span :if={@author && (@author.name || @author.handle)} class="min-w-0 truncate">
          <span class="font-medium text-slate-700 dark:text-slate-300">
            {@author.name || @author.handle}
          </span>
          <span :if={@author.name && @author.handle}>{@author.handle}</span>
          <span :if={Posts.written_at(@record)}>
            · <.post_time at={Posts.written_at(@record)} />
          </span>
        </span>
        <button
          type="button"
          phx-click="reveal_filter"
          phx-value-id={@key}
          class="ml-auto shrink-0 font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
        >
          {gettext("Show anyway")}
        </button>
      </div>
      <%!-- Which rule hid it, in one line whatever its length. `min-w-0` is what
      lets the chip shrink at all: a flex item's `min-width` is `auto`, so
      without it the pattern pushes the row wider than the card instead of
      truncating inside it. --%>
      <div class="flex items-baseline gap-1.5">
        <span class="shrink-0">{pgettext("filtered post", "Hidden:")}</span>
        <code class="min-w-0 truncate rounded bg-slate-200 px-1.5 py-0.5 font-mono text-xs text-slate-800 dark:bg-slate-800 dark:text-slate-200">{@pattern}</code>
      </div>
    </div>
    """
  end

  defp with_engagement(entries, user) do
    ancestor_ids = fn entry -> Enum.map(entry[:ancestors] || [], & &1.id) end

    # A cached post from another network (issue #1161) has no author here, so
    # there is nothing to like, nothing to mute and nobody to follow: it is kept
    # out of both batch reads, and then passed through untouched. Decorating in
    # place rather than splitting the list keeps the order the page arrived in,
    # so nothing has to be sorted back together afterwards.
    local = local_entries(entries)

    engagement =
      local
      |> Enum.flat_map(fn entry -> [entry.post.id | ancestor_ids.(entry)] end)
      |> Enum.uniq()
      |> Posts.post_engagement_map(user)

    follows =
      local
      |> Enum.map(& &1.post.user_id)
      |> Enum.uniq()
      |> then(&Social.follow_edges(user.id, &1))

    Enum.map(entries, fn entry ->
      if Posts.remote_feed_entry?(entry) do
        entry
      else
        entry
        |> Map.put(:engagement, engagement[entry.post.id])
        |> Map.put(:ancestor_engagement, Map.take(engagement, ancestor_ids.(entry)))
        |> Map.put(:viewer_follow, follows[entry.post.user_id])
      end
    end)
  end

  # A card's Translate tap (issue #1462): authorize + queue (or serve the
  # cache), then re-render the one streamed card the state concerns.
  @impl true
  def handle_event("translate", %{"kind" => kind, "id" => id}, socket) do
    case PostTranslations.request(socket.assigns.current_user, kind, id) do
      {:ok, key, state} ->
        {:noreply,
         socket
         |> update(:post_translations, &Map.put(&1, key, state))
         |> restream_translated(key)}

      :denied ->
        {:noreply, socket}
    end
  end

  def handle_event("show-original", %{"kind" => kind, "id" => id}, socket) do
    case PostTranslations.show_original(socket.assigns.post_translations, kind, id) do
      :ignore ->
        {:noreply, socket}

      {key, map} ->
        {:noreply, socket |> assign(:post_translations, map) |> restream_translated(key)}
    end
  end

  @impl true
  def handle_event("load-more", _params, socket) do
    {:noreply, append_older_page(socket, @page_size)}
  end

  # Time travel (`VutuvWeb.Live.FeedTimeTravel`), all of it driven by the feed
  # calendar: closing the open day is the only way back to the live present.
  def handle_event("travel-now", _params, socket),
    do: {:noreply, socket |> load_day(nil) |> sync_url()}

  # Paging the calendar does not move the reader: it changes which month they
  # are looking at. Only a day-click travels, which is what lets somebody hunt
  # for a busy week without their timeline lurching about under them.
  def handle_event("cal-month", %{"n" => n}, socket) do
    case Integer.parse(to_string(n)) do
      # Backwards is refused once the feed no longer reaches past this month —
      # the same rule that greys the arrow out, applied where it is enforceable.
      # A disabled button is a hint; this is the answer.
      {value, _rest} when value < 0 and not socket.assigns.cal_earlier? ->
        {:noreply, socket}

      {value, _rest} ->
        {:noreply,
         socket
         |> assign(:cal_month, FeedTimeTravel.shift_month(socket.assigns.cal_month, value))
         |> defer_calendar_counts()}

      :error ->
        {:noreply, socket}
    end
  end

  # The reading is not just a shading: "My posts" narrows the **timeline** to
  # what this member wrote, so switching it reloads the page under the calendar
  # as well as the numbers in it. Shading a month by one rule while the feed
  # below showed another would be two answers to one question.
  def handle_event("cal-metric", %{"metric" => metric}, socket) do
    known = Enum.map(FeedCalendar.metrics(), & &1.key)
    metric = if metric in known, do: metric, else: "feed"

    # Pressing the reading already showed is a no-op, and has to say so here:
    # the two buttons are `aria-pressed`, never disabled, so the press arrives
    # like any other and would otherwise re-run the month union, the floor check
    # and a full page load with a stream reset for nothing.
    if metric == socket.assigns.cal_metric do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:cal_metric, metric)
       # Counted here and not deferred, unlike every other way into the
       # heatmap: `load_day/2` on the next line sizes its page from these
       # counts (`day_limit/2`), and handing it an empty map would fetch and
       # decorate the whole-day limit for a day it is about to learn is busy.
       # Nothing is lost by waiting — this press reloads the timeline under the
       # calendar anyway, so it is not a press the reader watches do nothing.
       |> assign_calendar_counts()
       |> load_day(socket.assigns.cal_day)}
    end
  end

  # "Load the whole day" — the button beside "Load more" on a busy day.
  #
  # Re-fetches the day in one page rather than chaining "Load more" until it
  # runs out: the reader has said they want all of it, and walking there ten at
  # a time is the same rows over more round trips. Capped at `@day_all_limit`,
  # so a day with thousands still ends with a "Load more" under it instead of
  # trying to render the lot.
  def handle_event("load-day-all", _params, socket) do
    case socket.assigns.cal_day do
      nil -> {:noreply, socket}
      day -> {:noreply, load_day(socket, day, @day_all_limit)}
    end
  end

  # Folding the calendar away does not send the reader home: somebody who
  # opened last Tuesday and wants the month grid out of the way is still
  # reading Tuesday, and yanking them back to now would be a second thing they
  # did not ask for. Closing the DAY is what returns to the present.
  def handle_event("cal-toggle", _params, socket) do
    # The press unfolds and answers; the heatmap follows a moment later (see
    # `defer_calendar_counts/1`). Folded, the counts are not asked for at all.
    {:noreply, socket |> update(:cal_open?, &(!&1)) |> defer_calendar_counts() |> sync_url()}
  end

  # A day is a window, not a moment (`FeedTimeTravel.day_cursor/1`). Pressing
  # the day already open closes it and returns to now, so the same control both
  # opens and closes a day rather than stranding the reader in one.
  def handle_event("cal-day", %{"date" => date}, socket) do
    with {:ok, day} <- FeedTimeTravel.parse_date(date),
         true <- FeedTimeTravel.reachable?(day) do
      day = if socket.assigns.cal_day == day, do: nil, else: day

      {:noreply, socket |> load_day(day) |> sync_url()}
    else
      _unreachable -> {:noreply, socket}
    end
  end

  def handle_event("open-composer", _params, socket) do
    # Both triggers open the same composer — there are no modes. The camera
    # button additionally clicks the composer's "Add photos" control
    # client-side (a JS.dispatch chained onto its phx-click), so the photo
    # picker opens in the same gesture.
    {:noreply, assign(socket, :composer_open?, true)}
  end

  # The composer's corner ✕ (feed compose only) bubbles up here to collapse it.
  def handle_event("close-composer", _params, socket) do
    {:noreply, assign(socket, :composer_open?, false)}
  end

  # "Show anyway" on a content-filtered post (issue #940): reveal it in place,
  # no reload. The reveal set survives a midnight restream, so the post stays
  # open. Re-stream just this one entry so its placeholder swaps to the card.
  def handle_event("reveal_filter", %{"id" => key}, socket) do
    case Enum.find(socket.assigns.entries, &(filter_key(&1) == key)) do
      nil ->
        {:noreply, socket}

      entry ->
        {:noreply,
         socket
         |> update(:revealed_filters, &MapSet.put(&1, key))
         |> stream_insert(:posts, entry, update_only: true)}
    end
  end

  # A member reports a cached post from another network. It is deleted at once
  # (`Vutuv.Fediverse.report_remote_post/2`) — this is a cache of something that
  # still exists at its origin, so there is no case and no freezer — and the
  # row leaves the feed in the same round trip.
  def handle_event("report-remote-post", %{"id" => id}, socket) do
    RemotePostActions.report(socket, id, &drop_remote_entry(&1, id))
  end

  # "Not this account today": the private, reversible lever beside Report. The
  # follow survives; its posts leave this feed, so every row from that account
  # goes in the same round trip rather than lingering until the next reload.
  def handle_event("mute-remote-account", %{"id" => account_id}, socket) do
    socket
    |> bump_band_refresh()
    |> RemotePostActions.mute(account_id, &drop_remote_entries_of(&1, account_id))
  end

  # And the same menu's way out that lasts. The rows leave for the same reason —
  # they were here because of that follow — and the cached posts themselves go
  # with it once nobody here follows the account any more.
  def handle_event("unfollow-remote-account", %{"id" => account_id}, socket) do
    socket
    |> bump_band_refresh()
    |> RemotePostActions.unfollow(account_id, &drop_remote_entries_of(&1, account_id))
  end

  # The same two acts on a reply from another network, which the feed now draws
  # both as a row of its own (a reshare, issue #1275) and inside a thread. Its
  # menu is rendered here, so its events are owed here — see
  # `VutuvWeb.Live.RemoteReplyActions`.
  def handle_event("remove-remote-reply", %{"id" => id}, socket) do
    take_down_note(socket, id, &RemoteReplyActions.remove/2)
  end

  def handle_event("report-remote-reply", %{"id" => id}, socket) do
    take_down_note(socket, id, &RemoteReplyActions.report/2)
  end

  # The "New here" card's Follow button: welcome the newcomer with no reload.
  #
  # The row deliberately **stays** afterwards, flipped to its "Following" state,
  # instead of being dropped and replaced by the next candidate the way the
  # ranked rail this replaced did. Greeting somebody and watching them vanish
  # reads as if the click undid something; on a card whose whole subject is
  # saying hello, the visible ✓ is the answer. A fresh draw (reshuffle, the
  # periodic tick, the next visit) leaves them out again, since by then the
  # viewer follows them.
  def handle_event("follow", %{"followee" => followee_id}, socket) do
    # Every refusal — a tampered id, a block, following yourself, an edge that
    # already exists — comes back as an error tuple rather than a raise, so
    # re-reading the follow table afterwards simply leaves the pill where it was.
    Social.follow(socket.assigns.current_user, followee_id)

    {:noreply, assign_following(socket)}
  end

  # The other half of the same pill: a welcome taken back before the page is
  # left. Scoped to the viewer by `unfollow!/2`, so a tampered id can only ever
  # drop an edge they own.
  def handle_event("unfollow", %{"id" => follow_id}, socket) do
    Social.unfollow!(socket.assigns.current_user.id, follow_id)
    {:noreply, assign_following(socket)}
  end

  # The "Tags you follow" rail's ✕: unfollow the tag with no reload, then redraw
  # the rail so the chip drops. The already-shown posts stay put — like
  # unfollowing a person, the change only shapes the next feed load.
  def handle_event("unfollow_tag", %{"id" => tag_id}, socket) do
    Vutuv.Tags.unfollow_tag(socket.assigns.current_user, tag_id)
    {:noreply, socket |> assign(:tag_missing, nil) |> assign_followed_tags()}
  end

  # Following a tag from the rail, by name — typed into the field or taken from
  # the suggestions, which is the same event because it is the same act.
  #
  # Resolved by slug and never minted: an unknown name is answered rather than
  # turned into an empty topic in a namespace every member shares. The slug is
  # what `Vutuv.SlugHelpers.tagify/1` makes of the name, so "Free Software" and
  # "free-software" find the same tag, and `resolve_tag_by_slug/1` follows an
  # alias to the topic it was merged into (#1338) instead of dead-ending on the
  # old spelling.
  def handle_event("follow_tag", %{"name" => name}, socket) do
    case name |> to_string() |> String.trim() do
      "" ->
        {:noreply, socket}

      typed ->
        case Vutuv.Tags.resolve_tag_by_slug(Vutuv.SlugHelpers.tagify(typed)) do
          nil ->
            {:noreply, assign(socket, :tag_missing, typed)}

          tag ->
            Vutuv.Tags.follow_tag(socket.assigns.current_user, tag)
            {:noreply, socket |> assign(:tag_missing, nil) |> assign_followed_tags()}
        end
    end
  end

  # The "New here" card's reload button: greet five other newcomers, with
  # another three tags each.
  def handle_event("reshuffle-newcomers", _params, socket) do
    {:noreply, assign_newcomers(socket)}
  end

  # The "Suggested posts" card's reload button: draw 5 fresh random ones.
  # The three arranging controls. Each writes the whole arrangement back, so a
  # reader who folds a card on their laptop finds it folded on their phone —
  # the same promise the band's switches make, and the reason the rail is a
  # column on the member rather than something in this socket.
  def handle_event("rail-reorder", %{"order" => order}, socket) when is_list(order) do
    {:noreply, save_rail(socket, &Posts.rearrange_feed_rail(&1, order))}
  end

  def handle_event("rail-collapse", %{"key" => key}, socket) do
    {:noreply, save_rail(socket, &toggle_rail_member(&1, :collapsed, key))}
  end

  # Removing also unfolds: the card comes back the way it went away otherwise,
  # and a reader who put a folded card away and fetched it again would get a
  # heading with nothing under it and no memory of having folded it.
  def handle_event("rail-remove", %{"key" => key}, socket) do
    {:noreply,
     save_rail(socket, fn rail ->
       %{rail | removed: Enum.uniq([key | rail.removed]), collapsed: rail.collapsed -- [key]}
     end)}
  end

  def handle_event("rail-restore", %{"key" => key}, socket) do
    {:noreply, save_rail(socket, &%{&1 | removed: &1.removed -- [key]})}
  end

  def handle_event("open-band", _params, socket) do
    {:noreply, assign(socket, :band_sheet?, true)}
  end

  def handle_event("close-band", _params, socket) do
    {:noreply, assign(socket, :band_sheet?, false)}
  end

  def handle_event("show-new", _params, socket) do
    pending = socket.assigns.pending_posts

    # Revealing the batch is the member choosing to look at exactly these
    # posts, so a notification whose subject is one of them (the answer to
    # their post, an answer elsewhere in their thread, the post naming them)
    # is old news the moment the pill unfolds: the bell recounts over the
    # :notifications_changed broadcast. Harmless for posts nobody notified
    # about (the mark is a row no tally consults), and the pattern skips any
    # future pending entry without a local post to mark.
    Activity.mark_posts_seen(
      socket.assigns.current_user.id,
      for(%{post: %{id: post_id}} <- pending, do: post_id)
    )

    # Two ways to finish, and which one it is was decided when the posts arrived.
    #
    # Under the cap the rows are already on the page and the browser has already
    # shown them (`reveal_pending/0`), so all that is left is the state behind
    # them: the card and the pill go, and every later re-render of those rows
    # renders them visible, because that is decided by this list.
    #
    # Over it the timeline is missing a row for every post the valve turned away,
    # so there is nothing to reveal and the honest answer is a fresh page. The
    # control knows this too and does not run the browser-side reveal in that
    # mode, or the kept rows would flash into view a moment before the reload
    # replaced the whole list.
    # A third way in, and it is the one the calendar adds: with a day open there
    # are no rows either, because the waiting posts belong to today and the
    # timeline is showing some other day. Pressing the pill is then the reader
    # saying "take me to those posts", so it closes the day and comes home —
    # which is exactly the reload the overflow case already wanted.
    if socket.assigns.pending_overflow > 0 or not at_now?(socket.assigns) do
      # Both of these load a fresh timeline, which re-bases the seam: the reader
      # is arriving at a new list, so "what I did not have when I got here" is
      # about to mean something else.
      {:noreply, socket |> load_day(nil) |> sync_url()}
    else
      {:noreply,
       socket
       |> assign(:pending_posts, [])
       |> assign(:empty?, false)
       |> show_seam()}
    end
  end

  # Load the timeline for one source tab, replacing whatever is on screen
  # (`reset: true`). The pending batch is dropped with it rather than
  # re-filtered: the fresh page is newest-first from the top, so it already
  # carries everything that was waiting behind the pill.
  #
  # **The smallest of the three pages** (`@filter_page_size`, a quarter of an
  # arrival): a mount is a page load and pays for its page once, but a switch
  # happens mid-visit and its rendered cards are the bulk of the second the
  # member waits on a slow line — for a screen that holds three or four.
  # `more?` comes from the same query, so the "Load more" button below picks the
  # rest up at the full page size.
  # One older page, appended below what is on screen. Shared by the "Load more"
  # button and by the arrival's own fill (`:fill_arrival`), which is the same
  # act — fetch from the cursor, drop what is already shown, append — and would
  # otherwise be two copies of the dedup rule.
  defp append_older_page(socket, limit) do
    user = socket.assigns.current_user

    page =
      Posts.feed_page(user,
        limit: limit,
        cursor: socket.assigns.cursor,
        filter: effective_filter(socket)
      )

    # A post shown higher up (as a newer repost, or nested in a shown thread)
    # must not reappear on an older page: `feed_page/2` dedups within a page but
    # can't see the ones already on screen. The higher card already carries the
    # complete follow-scoped roster, so dropping the older duplicate loses
    # nothing. Filter before the engagement batch so it queries only survivors.
    shown = shown_post_ids(socket.assigns.entries)

    fresh =
      Enum.reject(page.entries, fn entry ->
        not Posts.remote_feed_entry?(entry) and MapSet.member?(shown, entry.post.id)
      end)

    entries =
      fresh
      |> with_engagement(user)
      |> mark_filtered(socket.assigns.content_filters, user.id)

    socket
    |> assign(:more?, page.more?)
    |> assign(:cursor, page.next_cursor)
    |> update(:entries, &(&1 ++ entries))
    |> stream(:posts, entries, at: -1)
    |> watch_pending_photos(entries)
    |> auto_translate_entries(entries)
  end

  defp load_source_filter(socket, filter) do
    user = socket.assigns.current_user
    page = Posts.feed_page(user, limit: @filter_page_size, filter: filter)

    entries =
      page.entries
      |> with_engagement(user)
      |> mark_filtered(socket.assigns.content_filters, user.id)

    socket
    |> assign(:feed_filter, filter)
    |> assign(:more?, page.more?)
    |> assign(:cursor, page.next_cursor)
    |> assign(:empty?, entries == [])
    |> assign(:pending_posts, [])
    |> assign(:pending_overflow, 0)
    # This timeline replaces the arrival, so a fill still on its way is owed to
    # a page that is no longer on screen (see `fill_arrival/2`).
    |> assign(:owes_fill?, false)
    |> assign(:entries, entries)
    |> rebase_seam(entries)
    |> stream(:posts, entries, reset: true)
    |> watch_pending_photos(entries)
  end

  # Whether the reader is looking at the live present. One way to leave it, the
  # calendar's open day, and every gate that cares asks the same question: the
  # arrival guard, the three empty states and the amber paint.
  defp at_now?(assigns), do: is_nil(assigns.cal_day)

  # What the URL asked the calendar to show (`/feed?day=2026-08-21`,
  # `/feed?cal=1`), as `{day_or_nil, unfolded?}`.
  #
  # The controller reads the query string and passes the two values through the
  # `live_render` session, because this LiveView is embedded rather than routed
  # and so has no `handle_params/3` of its own. An unreadable or future date is
  # simply ignored: a link somebody mangled should land on the feed, not on an
  # error, and a day that has not happened has nothing to show.
  #
  # A named day implies an unfolded calendar — arriving at a day with the grid
  # folded away would hide the only control that explains where the reader is.
  defp calendar_from_url(session) do
    with {:ok, day} <- FeedTimeTravel.parse_date(session["cal_day"] || ""),
         true <- FeedTimeTravel.reachable?(day) do
      {day, true}
    else
      _no_day -> {nil, session["cal_open"] in ~w(1 open true)}
    end
  end

  # Keeps the address bar in step with the calendar, so the day on screen is
  # always the day a copied link reopens.
  #
  # `replaceState` from a hook rather than `push_patch/2`: patching needs a
  # routed LiveView, and this one is `live_render`ed by the controller that
  # owns the agent-format siblings. It is deliberately *replace* and not
  # *push* — a reader stepping through a fortnight would otherwise have to
  # press Back fourteen times to leave the feed.
  defp sync_url(socket) do
    query =
      %{}
      |> put_param("day", socket.assigns.cal_day && Date.to_iso8601(socket.assigns.cal_day))
      |> put_param("cal", if(socket.assigns.cal_open? && !socket.assigns.cal_day, do: "1"))

    push_event(socket, "feed:url", %{query: URI.encode_query(query)})
  end

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: Map.put(params, key, value)

  # The heatmap's numbers for the month on screen. Recomputed whenever the
  # month or the reading changes, and never on an ordinary timeline patch:
  # the feed reading is a nine-source union over a month and is by far the most
  # expensive thing this page asks for.
  # What the timeline is currently narrowed to.
  #
  # Two axes meet here and only one of them is remembered. `feed_filter` is the
  # source band's stored setting (`users.feed_source`, which network); the
  # calendar's "My posts" reading is a view the reader is in right now and is
  # never written down. So this composes them for the query without the second
  # one ever reaching the member's saved preference.
  defp effective_filter(%{assigns: assigns}), do: effective_filter(assigns)
  defp effective_filter(%{cal_metric: "own"}), do: :own
  defp effective_filter(assigns), do: assigns.feed_filter

  # Whether a live arrival belongs in the timeline as it is currently narrowed.
  #
  # Under "My posts" that is a question about the AUTHOR, which the entry alone
  # cannot answer — so it is asked here, where the viewer is known, rather than
  # in `Posts.feed_filter_accepts?/2`.
  defp view_accepts?(socket, entry, actor_id) do
    case effective_filter(socket) do
      :own -> actor_id == socket.assigns.current_user.id
      filter -> Posts.feed_filter_accepts?(filter, entry)
    end
  end

  # Nothing at all while the calendar is folded away, which is how it opens and
  # how most readers leave it.
  #
  # The heatmap is a nine-source union over a month and the floor check is a
  # tenth query, and both were being paid on **every** feed mount for a grid
  # nobody had asked to see — enough to push a connected mount from 18 queries
  # to 28 and cost the mount handoff its whole point. Folded, the card shows a
  # date and needs no numbers; unfolding is what buys them.
  #
  # And unfolding does not WAIT for them. The cheap `:marks` shape got the month
  # down to well under half of what it cost (the figures are in
  # `docs/architecture/posts-and-feed.md`), but it is still ~26 queries, and a
  # press the reader watches do nothing is a slow press whatever the query
  # count says. So the grid goes out first with everything that does not need
  # the month in it — the dates, today's ring, the open day, both controls —
  # and the shading follows in a second render, fading in over
  # `transition-colors` rather than snapping. While it is on its way the empty
  # cells breathe (`.heatmap--waiting` in `components.css`): an unshaded grid
  # and a genuinely quiet month are the same picture, so a card that says
  # nothing has already given the wrong answer. On a disconnected render there
  # is no second render, so nothing is asked at all, nothing breathes, and the
  # connected mount fills the grid in.
  #
  # A revisited month is asked for again rather than remembered. A memo keyed
  # on the month would make a fold and unfold free, and would also hand the
  # reader an hour-old shading of the day they are still in: the numbers are
  # cheap to re-ask now and nobody sees the asking.
  defp defer_calendar_counts(socket) do
    pending? = socket.assigns.cal_open? and connected?(socket)

    if pending?, do: send(self(), {:cal_counts, calendar_key(socket)})

    socket
    |> assign(:cal_counts, %{})
    |> assign(:cal_capped?, false)
    # Whether an answer is on its way, which is not the same question as
    # "are all the counts zero" and is the only one the card can say out loud.
    # An unshaded grid and a genuinely quiet month look identical, so without
    # this the second between the press and the shading reads as the answer.
    # False on a disconnected render, where no second render is coming and the
    # grid is as finished as it will get.
    |> assign(:cal_counts_pending?, pending?)
    # The one answer worth keeping while the next is in flight: whether the feed
    # reaches back past this month barely changes from one month to its
    # neighbour, and the last answer is a better guess than "there is always
    # more" — which would let the back-step guard (`cal-month`) wave through a
    # press it is there to refuse. Seeded true on the very first render, where
    # there is no previous answer to keep.
    |> assign_new(:cal_earlier?, fn -> true end)
  end

  # Which question a pending heatmap answers. An answer whose question has moved
  # on is dropped rather than assigned — it would only recompute the month now
  # on screen, so this saves work rather than preventing a wrong shading, and
  # only for a reader who out-paces the sweep.
  defp calendar_key(socket), do: {socket.assigns.cal_month, effective_filter(socket)}

  defp assign_calendar_counts(socket) do
    user = socket.assigns.current_user
    month = socket.assigns.cal_month
    # The same narrowing the timeline is under, so the shading and the feed
    # below it can never answer one question two ways. Under "My posts" that is
    # `:own`, whose source list is the single query counting them used to be.
    filter = effective_filter(socket)

    %{counts: counts, capped?: capped?} =
      Posts.feed_activity_by_day(
        user,
        Date.beginning_of_month(month),
        Date.end_of_month(month),
        filter: filter
      )

    socket
    |> assign(:cal_counts, counts)
    |> assign(:cal_capped?, capped?)
    |> assign(:cal_counts_pending?, false)
    # Where the back arrows stop. Asked per month rather than resolved once,
    # because "is there anything before this month" is one row and a member's
    # true earliest entry is a nine-source minimum nobody needs.
    |> assign(:cal_earlier?, Posts.feed_reaches_before_month?(user, month, filter: filter))
  end

  # Moves the timeline to a point in time — where both controls land. `nil` is
  # now, and the reload is the *same* `feed_page/2` a mount calls, just handed a
  # synthetic first cursor: no second query path, so no visibility, block,
  # language or content filter can be true of one and not the other.
  #
  # `day:` is the calendar's shape and carries a lower bound as well, so the
  # page is one whole day rather than everything up to the end of it. It rides
  # the cursor, so "Load more" inside a day stops at the day's own edge.
  #
  # The pending queue is emptied rather than carried. What was waiting behind
  # the pill is "new since you got here", which is a claim about **now** and
  # says nothing on a timeline showing last Tuesday; and the return trip
  # reloads from the top anyway, so nothing is actually lost by dropping it.
  # How big a page opening this day should ask for.
  #
  # A day the heatmap already knows to be small is fetched **whole**, so the
  # ordinary case has no "Load more" under it at all — a day is a bounded thing
  # the reader asked to see, not an endless timeline. Only the busy ones page.
  # The limit is an upper bound, so a day holding three entries costs three
  # however generous the number here is.
  defp day_limit(_socket, nil), do: @travel_page_size

  defp day_limit(socket, day),
    do: day_page_limit(day_total(socket.assigns.cal_counts, day))

  # The rule itself, in one place: a day the feed knows to be small arrives
  # whole, a busy one pages.
  #
  # It answers for a day the heatmap has not counted yet, too: while the shading
  # is still in flight (`defer_calendar_counts/1`) every day reads as 0 and
  # therefore arrives whole. That is the same choice a `/feed?day=…` arrival
  # makes outright (`feed_payload/3`) and for the same reason — running the
  # month counter purely to pick between two page sizes costs more than the
  # larger page does. A quiet day still costs its own size; a busy one opened
  # inside that window pays a full page instead of a tenth of one.
  defp day_page_limit(total) when total < @day_full_limit, do: @day_full_limit
  defp day_page_limit(_total), do: @travel_page_size

  # The day's size, read straight off the heatmap counts, so knowing it costs no
  # query of its own.
  #
  # Derived on every read rather than stored: it is a `Map.get` on two assigns
  # that both move on their own (a month step replaces the counts, a day click
  # replaces the day), and a copy would have had to be refreshed on each of
  # those paths or quietly disagree with the grid it was read from.
  # `Map.get` answers 0 for a nil day as readily as for a day nothing happened
  # on, so this needs no clause of its own for "no day open".
  defp day_total(counts, day), do: Map.get(counts, day, 0)

  defp load_day(socket, day, limit \\ nil) do
    user = socket.assigns.current_user

    page =
      Posts.feed_page(user,
        limit: limit || day_limit(socket, day),
        cursor: FeedTimeTravel.day_cursor(day),
        filter: effective_filter(socket)
      )

    entries =
      page.entries
      |> with_engagement(user)
      |> mark_filtered(socket.assigns.content_filters, user.id)

    socket
    |> assign(:cal_day, day)
    # Opening a day from another month moves the calendar to it, or the reader
    # is looking at a highlighted day that is not on the grid in front of them.
    |> assign(
      :cal_month,
      if(day, do: FeedTimeTravel.month_of(day), else: socket.assigns.cal_month)
    )
    |> assign(:more?, page.more?)
    |> assign(:cursor, page.next_cursor)
    |> assign(:empty?, entries == [])
    |> assign(:pending_posts, [])
    |> assign(:pending_overflow, 0)
    # This timeline replaces the arrival, so a fill still on its way is owed to
    # a page that is no longer on screen (see `fill_arrival/2`).
    |> assign(:owes_fill?, false)
    |> assign(:entries, entries)
    |> rebase_seam(entries)
    |> stream(:posts, entries, reset: true)
    |> watch_pending_photos(entries)
    |> auto_translate_entries(entries)
  end

  # The rest of the arrival, once the reader has the page (see `fill_arrival/2`).
  # It is the same act as pressing "Load more", so it is the same code — the
  # cards land at the end of the stream, below the fold, and the cursor and the
  # "Load more" button move on exactly as if the reader had pressed it.
  @impl true
  def handle_info(:fill_arrival, %{assigns: %{owes_fill?: true}} = socket) do
    socket = assign(socket, :owes_fill?, false)
    {:noreply, append_older_page(socket, @first_page_size - @first_render_size)}
  end

  # The reader moved on (a source switch, an opened day) before the fill was
  # handled; that page is not the one this was owed for.
  def handle_info(:fill_arrival, socket), do: {:noreply, socket}

  def handle_info({:new_post, %{post_id: post_id, author_id: author_id}}, socket) do
    post = Posts.get_post(post_id)

    entry =
      post &&
        %{
          id: "post-#{post.id}",
          post: post,
          reposted_by: nil,
          reposters: [],
          at: post.inserted_at,
          engagement: nil
        }

    insert_entry(socket, entry, author_id)
  end

  # A repost arrived over the viewer's activity topic. The fan-out only reaches
  # a reposter's *followers* (or the reposter), so the reposter always belongs
  # in this viewer's roster. Where the post already sits decides what happens:
  # fold the new face into an on-screen card's stack (in place, no reshuffle —
  # the card only climbs on the next reload), or into a card still behind the
  # pill; skip it silently when the post is already visible nested inside a
  # shown thread; otherwise it is new and takes the usual own/pill path.
  def handle_info(
        {:new_repost, %{repost_id: repost_id, post_id: post_id, reposter_id: reposter_id}},
        socket
      ) do
    reposter = Vutuv.Repo.get(Vutuv.Accounts.User, reposter_id)

    cond do
      is_nil(reposter) ->
        {:noreply, socket}

      shown = find_by_post_id(socket.assigns.entries, post_id) ->
        {:noreply, restack_shown(socket, shown, reposter)}

      MapSet.member?(shown_post_ids(socket.assigns.entries), post_id) ->
        {:noreply, socket}

      pending = Enum.find(socket.assigns.pending_posts, &(&1.post.id == post_id)) ->
        {:noreply, restack_pending(socket, pending, reposter)}

      true ->
        post = Posts.get_post(post_id)

        entry =
          post &&
            %{
              id: "repost-#{repost_id}",
              post: post,
              reposted_by: reposter,
              reposters: [reposter],
              at: NaiveDateTime.utc_now(:second),
              engagement: nil
            }

        insert_entry(socket, entry, reposter_id)
    end
  end

  # A post was deleted: drop its entry from the stream and from any pending
  # batch behind the pill. Reposts of it are keyed by repost id, so their card
  # shell survives until reload, but its action bar empties via the post topic.
  def handle_info({:post_deleted, %{post_id: post_id}}, socket) do
    {:noreply,
     socket
     |> stream_delete_by_dom_id(:posts, "feed-post-#{post_id}")
     |> update(:pending_posts, &Enum.reject(&1, fn entry -> entry.post.id == post_id end))}
  end

  # Periodic reshuffle of the "New here" and "Suggested posts" rails: draw a
  # fresh random slate of not-yet-followed newcomers and posts and reschedule
  # the next tick. Cheap (an id-ordered pool scan, a follow-edge query, the tag
  # batch and the pooled posts draw, all small), so a 5-minute cadence on an
  # open feed is fine. It is also what keeps the cards' relative wording honest
  # on a page left open across midnight: the next tick redraws
  # "joined today" as "joined yesterday" without a reload.
  def handle_info(:refresh_suggestions, socket) do
    Process.send_after(self(), :refresh_suggestions, @suggestions_refresh)
    {:noreply, assign_newcomers(socket)}
  end

  # The filter band switched something off (or back on). It has already written
  # the change through the contexts this page reads, and hands back the member
  # it wrote it to — so the timeline is re-run against that struct rather than
  # the one this socket loaded at mount, which is exactly the stale copy the
  # source list would otherwise consult.
  def handle_info({:filter_band, :changed, user}, socket) do
    {:noreply,
     socket
     |> assign(:current_user, user)
     # A word or tag rule changed too, and the compiled set is what every row
     # is measured against — recompiled here rather than at each call site, so
     # a rule added in the band cannot keep showing the post it hides.
     |> assign(:content_filters, ContentFilters.compile_for(user))
     |> load_source_filter(Posts.remembered_feed_filter(user))}
  end

  # Something landed through the fediverse (issue #1503) — a followed account
  # posted or boosted, or somebody here passed a remote post or reply on. Unlike
  # `{:new_post, …}` this carries no entry, because whether that write reaches
  # THIS reader depends on their mutes, their follow states, the audience and
  # their language filter; so the nudge only says "look", and the feed asks its
  # own sources (`Posts.newest_source_entry/3`).
  #
  # It used to put a dot on the tab the reader was not standing on. With the
  # tabs gone it joins the same queue everything else waits in, so the rail's
  # "not read yet" card and the pill above the timeline count it like any other
  # arrival — otherwise a fediverse-heavy feed would go completely quiet while
  # the page is open, which is the opposite of what the band is for.
  def handle_info({:remote_feed_arrival, %{at: at}}, socket) do
    {:noreply, queue_remote_arrival(socket, at)}
  end

  # The viewer followed / unfollowed a tag elsewhere (a tag page in another tab,
  # issue #872): redraw the "Tags you follow" rail so an open feed reflects it
  # live. Posts already streamed stay; the new tag's posts arrive on the next
  # load, like a fresh person-follow.
  def handle_info({:tag_follows_changed, _}, socket) do
    {:noreply, assign_followed_tags(socket)}
  end

  # The Berlin day rolled over (Vutuv.DayClock at midnight): re-render every
  # shown post's stamp so "today" wording becomes "Gestern" and yesterday's
  # falls back to a full date. Shared with notifications + the saved hub; see
  # VutuvWeb.Live.DayClockRestream.
  # `Vutuv.DayClock` ticks on every whole UTC hour, which is when some reader's
  # midnight falls. Two things on this page are written in calendar days and
  # both have to move: every post stamp ("09:50 Uhr" becomes "Gestern, 09:50
  # Uhr"), and the calendar, whose today ring, folded date and future-day gate
  # would otherwise hold yesterday until the next reload — with the new day's
  # own cell greyed out, so the reader could not even click their way back to
  # it.
  def handle_info(:day_changed, socket) do
    {:noreply,
     socket
     |> assign(:cal_today, ViewerClock.today())
     |> DayClockRestream.restream(:entries, :posts)}
  end

  # A post's link screenshot finished capturing (fan-out reaches the viewer over
  # their activity topic, like :new_post): if the post is on the page, refresh
  # its card in place so the screenshot appears with no reload.
  def handle_info({:post_screenshot_ready, %{post_id: post_id}}, socket) do
    {:noreply, refresh_shown_post(socket, post_id)}
  end

  # The author removed a bad link screenshot: refresh the card so it drops.
  def handle_info({:post_screenshot_removed, %{post_id: post_id}}, socket) do
    {:noreply, refresh_shown_post(socket, post_id)}
  end

  # A photo of the author's post cleared the AI image scan (issue #1104):
  # refresh the card so the picture appears and the "checking your photos…"
  # line counts down and finally disappears — the author watches it finish
  # instead of reloading to find out.
  def handle_info({:post_images_settled, %{post_id: post_id}}, socket) do
    {:noreply, refresh_shown_post(socket, post_id)}
  end

  # The same for a picture on a cached post from another network (issue #1801).
  # It matters more here than for a member's own photo: a delivery draws the
  # card in the second between recording the picture and its bytes landing, so
  # the reader's FIRST sight of a boosted photo post is the waiting tile.
  def handle_info({:remote_images_settled, %{remote_post_id: id}}, socket) do
    {:noreply, refresh_remote_images(socket, id)}
  end

  # The worker finished a translation this reader asked for (issue #1462):
  # swap it into the one card, or clear the pending line on a failure.
  def handle_info({:translation_ready, translation}, socket) do
    viewer = socket.assigns.current_user

    case PostTranslations.apply_ready(socket.assigns.post_translations, translation, viewer) do
      :ignore ->
        {:noreply, socket}

      {key, map} ->
        {:noreply, socket |> assign(:post_translations, map) |> restream_translated(key)}
    end
  end

  def handle_info({:translation_failed, key, target}, socket) do
    viewer = socket.assigns.current_user

    case PostTranslations.apply_failed(socket.assigns.post_translations, key, target, viewer) do
      :ignore ->
        {:noreply, socket}

      {key, map} ->
        {:noreply, socket |> assign(:post_translations, map) |> restream_translated(key)}
    end
  end

  # The composer says it holds a draft, so show it (issue #1130). Two moments
  # send this: the first characters of a normal compose (the panel is already
  # open, so the assign is a no-op), and the `validate` LiveView's form recovery
  # replays after a reconnect — which is the one that matters. A reconnect
  # re-mounts this LiveView, and `composer_open?` is plain socket state, so the
  # panel collapses while the text stays in it: the author comes back to their
  # tab, finds the form gone and has no reason to believe the draft survived.
  def handle_info({:composer_drafting, _id}, socket) do
    {:noreply, assign(socket, :composer_open?, true)}
  end

  # Photo mode's ✕ discarded the draft inside the component; the panel
  # collapses with it (the component cannot reach this assign itself).
  def handle_info({:composer_discarded, _id}, socket) do
    {:noreply, assign(socket, :composer_open?, false)}
  end

  # The month's shading, arriving after the grid it belongs to
  # (`defer_calendar_counts/1`). Both guards drop work rather than prevent a
  # wrong answer — the count is taken from the assigns, not from `key`, so a
  # superseded message would merely recompute the month now on screen.
  def handle_info({:cal_counts, key}, socket) do
    if socket.assigns.cal_open? and calendar_key(socket) == key do
      {:noreply, assign_calendar_counts(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The queue half of `{:remote_feed_arrival, …}` above: ask this reader's own
  # sources what actually arrived and put it behind the pill.
  #
  # A member who switched the fediverse half off is told nothing, and neither is
  # one whose page already holds that entry — the announcement carries no id, so
  # a burst of deliveries would otherwise queue the same newest post several
  # times over.
  defp queue_remote_arrival(%{assigns: %{feed_filter: :vutuv}} = socket, _at), do: socket

  defp queue_remote_arrival(socket, at) do
    case Posts.newest_source_entry(socket.assigns.current_user, :fediverse, at) do
      nil -> socket
      entry -> if known_entry?(socket, entry), do: socket, else: queue(socket, entry)
    end
  end

  # A waiting post goes into the timeline **now**, hidden, and not when the
  # reader asks for it.
  #
  # The reveal used to be a round trip that carried the cards: the server held
  # the decorated entries, `stream_insert`ed them on the press and shipped ten
  # posts' worth of rendered HTML back before anything moved. Everything needed
  # to draw them already exists at this moment, so the row is drawn at this
  # moment and only the `hidden` attribute that keeps it out of sight waits for
  # the press — which is then two attribute ops in the browser, with the server
  # hearing about it afterwards.
  #
  # It rides the same three steps the author's own arrival takes, in the same
  # order, because from the DOM's point of view this *is* that arrival: the row
  # on top, the parent it nests dropped, and the photo scan watched.
  defp queue(socket, entry) do
    socket
    |> update(:pending_posts, &[entry | &1])
    |> update(:entries, &[entry | &1])
    |> stream_insert(:posts, entry, at: 0)
    |> prune_threaded_parent(entry)
    |> watch_pending_photos([entry])
    |> assign(:empty?, false)
    |> trim_pending()
  end

  # The valve. Past `@pending_cap` the OLDEST drawn row goes — the newest are
  # what the card quotes and what the reader is about to be shown, so a window
  # that kept the first twenty-five would freeze the card on this morning while
  # the count climbed into the thousands.
  #
  # One arrival can only push the list one over, so this drops one row and never
  # loops. The dropped post is not lost to the reader: it is in the feed, and the
  # press now loads a page that has it.
  defp trim_pending(socket) do
    pending = socket.assigns.pending_posts

    if length(pending) > @pending_cap do
      dropped = List.last(pending)

      socket
      |> assign(:pending_posts, Enum.take(pending, @pending_cap))
      |> update(:entries, &Enum.reject(&1, fn e -> e.id == dropped.id end))
      |> stream_delete(:posts, dropped)
      |> update(:pending_overflow, &(&1 + 1))
    else
      socket
    end
  end

  # How many posts are waiting, drawn or not — what the card and the pill count.
  defp pending_count(assigns), do: length(assigns.pending_posts) + assigns.pending_overflow

  attr(:pending_posts, :list, required: true)
  attr(:pending_overflow, :integer, required: true)

  attr(:cal_day, :any,
    required: true,
    doc: "the travelled-to day, or nil — decides whether the press can be a browser-side reveal"
  )

  # Fades in as the calendar folds out of the way, so the two read as one
  # movement rather than as a pop over a jump. An insert plays a keyframe on its
  # own; a later count tick only patches this node's text, so it does not replay.
  #
  # `h-10` and not vertical padding: it stands beside the filter button, which is
  # `h-10`, and a pill sized by its own line height came out four pixels short of
  # it.
  #
  # A component and not markup in `render/1` so that the quote is flattened once
  # per arrival rather than once per render: everything below reads `@quote`, and
  # the whole subtree leaves the diff on any render that did not touch the three
  # attributes above (a translation landing, the five-minute suggestions
  # refresh). Computing it into `render/1`'s own assigns would do the opposite —
  # a key that is not in the incoming assigns is force-assigned, so it would be
  # dirty on every render, for a pipeline run of about 150 µs each time.
  defp new_posts_pill(assigns) do
    assigns = assign(assigns, :quote, newest_quote(assigns.pending_posts))

    ~H"""
    <div class="feed-teaser-in min-w-0 flex-1 text-center">
      <button
        id="show-new-posts"
        type="button"
        phx-click={show_pending(assigns)}
        class="mx-auto flex h-10 w-full max-w-full items-center gap-2 rounded-full bg-brand-50 px-4 text-sm font-semibold text-brand-700 shadow-sm hover:bg-brand-100 sm:w-auto dark:bg-brand-900/40 dark:text-brand-100 dark:hover:bg-brand-900/70"
      >
        <span class="shrink-0 tabular-nums">
          <%!-- An sr-only span and not an `aria-label` on the button: the label
          would become the whole accessible name and swallow the quote, while
          this leaves it "Show 3 new posts, @ada, breaking news". --%>
          <span :if={@quote} class="sr-only">{pending_sentence(assigns)}</span>
          <span aria-hidden={@quote && "true"}>{pending_label(assigns)}</span>
        </span>
        <span
          :if={@quote}
          class="flex min-w-0 flex-1 items-baseline gap-1 font-normal text-brand-600 dark:text-brand-200"
        >
          <span class="min-w-0 max-w-[45%] shrink truncate">{@quote.who}</span>
          <span class="min-w-0 flex-1 truncate">{@quote.text}</span>
        </span>
      </button>
    </div>
    """
  end

  # What the pill shows. Beside a quote the label is only what introduces it,
  # "Neu:" or "Neu (3):", because on a phone the whole sentence took the line and
  # left the quote three letters (Stefan, on a screenshot). The sentence is not
  # lost: it stays as the button's screen-reader name, where it costs no width.
  # With nothing to quote there is no colon to hang, so it is said in full.
  #
  # A desktop has the room, and takes the short label anyway: the rail's "Not
  # read yet" card (`unread_body/1`) already lists what is waiting there, so the
  # pill is not the only teller, and a `md:`-swapped label would put two copies
  # in the DOM and change the button's accessible name with the viewport.
  defp pending_label(%{quote: nil} = assigns), do: pending_sentence(assigns)

  defp pending_label(assigns) do
    count = pending_count(assigns)

    ngettext("New:", "New (%{formatted}):", count, formatted: compact_count(count))
  end

  defp pending_sentence(assigns) do
    count = pending_count(assigns)

    ngettext(
      "Show %{formatted} new post",
      "Show %{formatted} new posts",
      count,
      formatted: compact_count(count)
    )
  end

  attr(:alone?, :boolean,
    required: true,
    doc: "true while nothing is waiting, when the button owns the whole line"
  )

  # The feed's compose control. A BUTTON, not the input-shaped tile it replaced:
  # that one wore a placeholder and a text cursor and took neither, which read as
  # a field you could type in (Stefan, 2026-08-31).
  #
  # `h-10` puts it on the app's control line, level with the folded rail calendar
  # beside it. Alone it takes the line (`flex-1`); beside a waiting-posts quote it
  # keeps only what it needs (`flex-none`) and hands the rest over, because the
  # quote is the half that carries information and a 50:50 split left it three
  # words. Below `sm` it goes further and drops its own word, the same trade the
  # filter button on the phone's control line makes.
  defp compose_button(assigns) do
    ~H"""
    <%!-- The id is spelled here and nowhere else: `keyboard_shortcuts.js`
    (`revealAndFocusComposer`) and the `#compose` arrival both click it by name,
    and it only works while the button is visible. --%>
    <button
      type="button"
      id="open-composer"
      data-composer-trigger
      phx-click="open-composer"
      class={[
        "inline-flex h-10 items-center justify-center gap-2 rounded-full bg-brand-600 px-4",
        "text-sm font-semibold text-white shadow-sm hover:bg-brand-700",
        if(@alone?, do: "flex-1", else: "flex-none")
      ]}
    >
      <svg
        class="h-4 w-4 shrink-0"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.5"
        stroke="currentColor"
        aria-hidden="true"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125"
        />
      </svg>
      <%!-- The label is the accessible name when it is showing; when the quote
      has taken the line it is still read, just not drawn. --%>
      <span class={!@alone? && "sr-only sm:not-sr-only"}>
        {gettext("Write a post")}
      </span>
    </button>
    """
  end

  # Showing the waiting posts, in the browser, before the server hears about it.
  #
  # The rows are already drawn (`queue/2`); this drops the marker that hid them
  # and stamps the class that fades them in, so the reader sees the posts in the
  # same frame as their click instead of after a round trip carrying ten cards.
  # `JS.push` then tells the server, which empties the waiting list and takes the
  # card and the pill away — chrome, arriving a moment later, with nothing the
  # reader is waiting on hanging off it.
  #
  # Two attributes and not a class: `data-pending-shown` is what the animation
  # hangs off, and it is set BEFORE `hidden` is removed, since removing it makes
  # the selector stop matching and the second op would reach nothing.
  #
  # Neither attribute is ever cleaned up, and neither has to be. The animation is
  # a fire-once description of the arrival rather than a state, and the server
  # renders neither — so the first re-render of the row (a photo scan, a
  # translation, the midnight restream) leaves a plain visible row behind.
  # What a "show me" control fires. Past the cap it is the plain event and the
  # server loads a page; under it, the browser does the work first.
  defp show_pending(%{pending_overflow: overflow}) when overflow > 0, do: "show-new"
  defp show_pending(%{cal_day: %Date{}}), do: "show-new"
  defp show_pending(_assigns), do: reveal_pending()

  defp reveal_pending do
    JS.set_attribute({"data-pending-shown", "1"}, to: "#feed-posts > [hidden]")
    # The unread dot, stamped in the same breath and on the same rows, because
    # `[hidden]` stops matching one line below. It is deliberately never taken
    # off here: the mark means "you have not looked at this one", and a reader
    # who ignored six posts has still not read them once three more arrive. The
    # only thing that clears it is the reader's own eyes, which is the browser's
    # business (`FeedUrl` in app.js) and not this list's.
    |> JS.set_attribute({"data-new-mark", "1"}, to: "#feed-posts > [hidden]")
    |> JS.remove_attribute("hidden", to: "#feed-posts > [hidden]")
    |> JS.push("show-new")
  end

  # Where the timeline ended when the reader got here. The seam is drawn above
  # that post and does not move again for the rest of the visit, so every later
  # batch lands above it and the line keeps answering one question: what did I
  # not have yet when I arrived? A line that follows the newest batch answers
  # the same question the dot already answers, and answers it worse, because it
  # is gone the moment the next batch pushes it up.
  #
  # Re-based wherever the whole list is replaced (a source tab, a travelled-to
  # day, the reload the overflow path takes), since the reader is then looking
  # at a different timeline and the old boundary post is not in it.
  # Two ids and no flag: the anchor is the row the line WOULD hang under, and
  # `:seam_entry_id` is nil until it actually hangs there. An entry id is never
  # nil, so the row's own comparison is the whole condition.
  defp rebase_seam(socket, entries) do
    socket
    |> assign(:seam_anchor_id, seam_anchor(entries))
    |> assign(:seam_entry_id, nil)
  end

  defp seam_anchor([first | _rest]), do: first.id
  defp seam_anchor([]), do: nil

  # Drawing it for the first time. The boundary row is already on the client and
  # streams do not re-render what they have handed over, so it takes one
  # `update_only` re-insert — which updates the row where it sits and is a no-op
  # for a boundary that has since scrolled out of the stream.
  defp show_seam(%{assigns: %{seam_entry_id: id}} = socket) when is_binary(id), do: socket

  defp show_seam(socket) do
    case Enum.find(socket.assigns.entries, &(&1.id == socket.assigns.seam_anchor_id)) do
      nil ->
        socket

      entry ->
        socket
        |> assign(:seam_entry_id, entry.id)
        |> stream_insert(:posts, entry, update_only: true)
    end
  end

  # The line itself, and it needs no deploy gate: **every class here already
  # ships bare in the previous release's bundle**, so it arrives styled even
  # when patched into an hours-old document — which is the only reason the
  # v7.347.0 ticker incident does not repeat here. That is why the hairline is
  # `bg-brand-100` and not the `bg-brand-200` this first read better in: the
  # tree has that one only as `hover:bg-brand-200`, which Tailwind compiles to
  # a different selector, so a bare `bg-brand-200` would have been the single
  # class an open tab could not draw. Check any class added here the same way
  # (grep the tree for it *unprefixed*) rather than reaching for
  # `static_changed?/1`, which suppresses the line after every future deploy
  # too.
  defp visit_seam(assigns) do
    ~H"""
    <div
      data-feed-seam
      class="mb-4 flex items-center gap-3 text-xs font-semibold text-brand-700 dark:text-brand-300"
    >
      <span class="h-px flex-1 bg-brand-100 dark:bg-brand-800"></span>
      <span>{gettext("Up to here is new")}</span>
      <span class="h-px flex-1 bg-brand-100 dark:bg-brand-800"></span>
    </div>
    """
  end

  # Whether this row is one of the waiting ones, and so starts hidden. Read from
  # `@pending_posts` at render time rather than stamped on the entry: the press
  # empties that list, so every later re-render of the row (a photo scan
  # finishing, a translation, the midnight restream) agrees with the browser
  # that it is visible, and nothing has to remember to unstamp it.
  #
  # It becomes the plain `hidden` **attribute** and not a class or a data-* the
  # stylesheet has to know, because the browser's own stylesheet hides it. A
  # deploy reloads nothing: a tab open across one reconnects to the new release
  # and gets this markup patched into an hours-old document, so anything that
  # needed our CSS to hide would arrive visible there — a post shoving itself
  # into the timeline unasked. The row carries no `display` utility of its own,
  # which is the one thing `hidden` loses to (issue #880).
  defp pending_row?(entry, pending), do: Enum.any?(pending, &(&1.id == entry.id))

  defp known_entry?(socket, entry) do
    ids = Enum.map(socket.assigns.entries ++ socket.assigns.pending_posts, & &1.id)
    entry.id in ids
  end

  # Swap in the post's now-screenshot-carrying copy and re-stream the entry in
  # place (update_only, so an off-page id is a harmless no-op). The entry's other
  # fields — engagement, follow edge, repost roster — are preserved.
  defp refresh_shown_post(socket, post_id) do
    with entry when not is_nil(entry) <- find_by_post_id(socket.assigns.entries, post_id),
         post when not is_nil(post) <- Posts.get_post(post_id) do
      updated = %{entry | post: post}

      socket
      |> update(:entries, &replace_entry(&1, updated))
      |> stream_insert(:posts, updated, update_only: true)
    else
      _ -> socket
    end
  end

  # Re-read one cached post's pictures into every card on the page that draws it
  # (issue #1801). Every card, not the first: the same post can be on the page
  # twice, once as itself and once as the parent another card nests, and both
  # show the same waiting tile. One pass in the shape `drop_note/2` uses, so the
  # retained list and the stream are written once each rather than per hit.
  defp refresh_remote_images(socket, remote_post_id) do
    if Enum.any?(socket.assigns.entries, &RemoteImages.draws?(&1, remote_post_id)),
      do: restream_remote_images(socket, remote_post_id),
      else: socket
  end

  defp restream_remote_images(socket, remote_post_id) do
    images = Fediverse.remote_images(remote_post_id)

    {entries, changed} =
      Enum.map_reduce(socket.assigns.entries, [], fn entry, changed ->
        case RemoteImages.restate_entry(entry, remote_post_id, images) do
          ^entry -> {entry, changed}
          updated -> {updated, [updated | changed]}
        end
      end)

    socket = assign(socket, :entries, entries)
    Enum.reduce(changed, socket, &stream_insert(&2, :posts, &1, update_only: true))
  end

  # Swap the refreshed entry into the retained list by its stable entry id.
  defp replace_entry(entries, updated), do: replace_entry(entries, updated.id, updated)

  # Own activity (this or another session) appears immediately; other
  # people's waits behind the pill — and only when the post is visible.
  defp insert_entry(socket, nil, _actor_id), do: {:noreply, socket}

  defp insert_entry(socket, entry, actor_id) do
    if at_now?(socket.assigns) do
      insert_at_now(socket, entry, actor_id)
    else
      insert_while_travelling(socket, entry, actor_id)
    end
  end

  # An arrival that reaches a reader with a calendar day open. Its own function
  # rather than more branches in the `cond` below, because the two situations
  # take a different action on the same facts.
  #
  # It is still **counted**: a reader who went to look at last Tuesday wants to
  # know the present is filling up behind them, and the pill is how the feed
  # has always said so. What it must not do is draw the row — that post is not
  # part of the day on screen, and a hidden card belonging to another day sitting
  # in this day's stream is a card that appears in the wrong place the moment
  # anything reveals it. So the entry joins the waiting list without a row, and
  # `show_pending/1` knows there is nothing to reveal and asks the server
  # instead (which brings the reader home; see the "show-new" handler).
  #
  # The viewer's own post is the exception, as everywhere else: text that
  # disappears on submit reads as a post that was lost, so writing one is itself
  # the trip home and that reload carries it.
  defp insert_while_travelling(socket, entry, actor_id) do
    user = socket.assigns.current_user

    cond do
      actor_id == user.id ->
        {:noreply, socket |> assign(:composer_open?, false) |> load_day(nil) |> sync_url()}

      # The same two gates a queued arrival passes at now: can this post reach
      # this reader at all, and did they switch its source off.
      not Posts.reaches_feed?(entry.post, user) ->
        {:noreply, socket}

      not view_accepts?(socket, entry, actor_id) ->
        {:noreply, socket}

      true ->
        # `mark_one/3` and not `decorate/3`: nothing here is streamed, and the
        # pill only reads the author and the opening line. Decorating would buy
        # a follow edge and an engagement count per arrival, two queries, for a
        # card that is never drawn — including the ones the cap throws away.
        {:noreply, count_away(socket, mark_one(entry, socket.assigns.content_filters, user.id))}
    end
  end

  # Waiting posts with no row on the page, because the page is showing another
  # day. The cap is `trim_pending/1`'s, so the valve has one owner: its
  # `stream_delete/2` and `Enum.reject/2` are no-ops for an entry that was never
  # streamed and never added to `@entries`, which is exactly this case.
  defp count_away(socket, entry) do
    socket |> update(:pending_posts, &[entry | &1]) |> trim_pending()
  end

  defp insert_at_now(socket, entry, actor_id) do
    user = socket.assigns.current_user

    cond do
      # The author must see what they just wrote. Every live arrival carries a
      # vutuv post, so on the Fediverse tab there is no row to put it in — the
      # feed switches back to All and reloads rather than swallowing the post,
      # which from the composer reads as the post having been lost.
      actor_id == user.id and
          not view_accepts?(socket, entry, actor_id) ->
        {:noreply,
         socket
         |> assign(:composer_open?, false)
         |> load_source_filter(:all)}

      actor_id == user.id ->
        decorated = decorate(entry, user, socket)

        {:noreply,
         socket
         |> assign(:empty?, false)
         # The viewer just posted (this or another session): collapse the composer.
         |> assign(:composer_open?, false)
         |> update(:entries, &[decorated | &1])
         |> stream_insert(:posts, decorated, at: 0)
         |> prune_threaded_parent(entry)}

      # Does this post reach the reader at all — blocks, audience, mute and
      # their language filter, the in-memory twin of what the query decides
      # (`Posts.reaches_feed?/2`).
      #
      # It is asked FIRST, and the order is the whole correctness of the dot
      # below (issue #1503): the tab check used to come first and drop the
      # arrival, which cost nothing while the answer was "do nothing" and would
      # now light a tab for a post this reader is not allowed to read.
      not Posts.reaches_feed?(entry.post, user) ->
        {:noreply, socket}

      # A post nobody on this tab asked for must not be counted by the pill
      # either: the pill's whole promise is that clicking it shows those posts
      # right here.
      view_accepts?(socket, entry, actor_id) ->
        {:noreply, queue(socket, decorate(entry, user, socket))}

      # It belongs to a source this reader has switched off in the band, so it
      # is not news for them at all: the switch is the answer, and queueing it
      # would put a post they asked not to see behind a pill that promises to
      # show exactly what it counts.
      true ->
        {:noreply, socket}
    end
  end

  # A newly streamed reply renders the post it answers inline (the threaded
  # card), so drop the parent's standalone row — from the stream and from any
  # pending batch behind the pill — to avoid showing it twice. The pull path
  # (`Posts.feed_page/2`) dedups the same way on reload. A no-op for a
  # non-reply, and harmless when the parent isn't on the page
  # (`stream_delete_by_dom_id` ignores an absent id). Targets the parent's
  # own-post row (`feed-post-<id>`); a repost of the parent self-corrects on
  # the next reload.
  defp prune_threaded_parent(socket, entry) do
    case Posts.reply_ref_state(entry.post) do
      {:parent, parent} ->
        socket
        |> stream_delete_by_dom_id(:posts, "feed-post-#{parent.id}")
        |> update(:pending_posts, &Enum.reject(&1, fn e -> e.post.id == parent.id end))

      _ ->
        socket
    end
  end

  # Attach the viewer's follow edge (so the card's mute toggle works on a
  # live-arrived post too — nil for an own post, no self-follow) and the
  # action-bar engagement, both queried in this process. The bar component
  # renders straight from the entry's engagement, so a live-arrived card never
  # queries during render (which would race the sandbox in tests). Only the
  # two branches that keep the entry pay for it — a blocked or denied post is
  # dropped before either query runs. A live-arrived reply nests only its direct
  # parent (one level, whose bar self-loads); the full visible chain reassembles
  # on the next reload / "Load more" (which run through `collapse_threads/1`).
  defp decorate(entry, user, socket) do
    entry
    |> Map.put(:viewer_follow, Social.follow_edge(user.id, entry.post.user_id))
    |> Map.put(:engagement, Posts.post_engagement(entry.post.id, user.id))
    |> mark_one(socket.assigns.content_filters, user.id)
  end

  # Content filters (issue #940): stamp each entry with the pattern that hides it
  # (`:filtered_by`), or leave it clear. Never the viewer's own posts. A no-op
  # for the vast majority who mute nothing, so the feed pays for it only when a
  # filter exists.
  defp mark_filtered(entries, compiled, viewer_id) do
    if ContentFilters.any?(compiled),
      do: Enum.map(entries, &mark_one(&1, compiled, viewer_id)),
      else: entries
  end

  defp mark_one(entry, compiled, viewer_id) do
    case PostTeaser.filtered_hit(entry, compiled, viewer_id) do
      nil -> Map.merge(entry, %{filtered_by: nil, filtered_post: nil})
      hit -> Map.merge(entry, %{filtered_by: hit.pattern, filtered_post: hit.record})
    end
  end

  # What the reveal set remembers. A vutuv post is keyed by its own id (so the
  # same post stays revealed when it is restreamed), a cached post from another
  # network (issue #1161) by its row id — it is not a `%Post{}` and has no post
  # id to key on.
  defp filter_key(entry), do: entry_record(entry).id

  # Whether the reader's filters currently hide this entry: it matched one, and
  # they have not opened it. The single expression the row's three renderings
  # branch on, so the placeholder and the card it stands in for cannot both show
  # (or both vanish).
  defp hidden_by_filter?(entry, revealed),
    do: entry[:filtered_by] != nil and filter_key(entry) not in revealed

  # A reported or muted cached post leaves the feed in the same round trip, so
  # the reader never looks at a row that is no longer theirs to see.
  #
  # `empty?` is recomputed because it gates the whole timeline container: a
  # reader whose feed held nothing but the account they just muted would
  # otherwise be left looking at an empty white card instead of the "nothing
  # here yet" message. Caught in a browser, not by the tests — none of them
  # emptied a feed this way.
  # Every card by one remote account, off the page in this round trip — what
  # both Mute and Unfollow leave behind. A reshared **reply** carries no
  # `remote_post`, so it is asked about through `remote_reply_entry?/1` first
  # rather than reached for and found nil.
  defp drop_remote_entries_of(socket, account_id) do
    socket.assigns.entries
    |> Enum.filter(fn entry ->
      Posts.remote_feed_entry?(entry) and not Posts.remote_reply_entry?(entry) and
        entry.remote_post.remote_account_id == account_id
    end)
    |> Enum.reduce(socket, &drop_remote_entry(&2, &1.remote_post.id))
  end

  # The band's sources card skips reloads the page does not owe it (the gate in
  # `VutuvWeb.PostLive.FilterBand.load/1`); this is how the page says it owes
  # one. Bumped BEFORE the act, so the assign rides whatever the act assigns.
  defp bump_band_refresh(socket), do: update(socket, :band_refresh, &(&1 + 1))

  defp drop_remote_entry(socket, remote_post_id) do
    # By each entry's own id, not by a rebuilt one. The same cached post can be
    # on the page twice — once because the reader follows its author (issue
    # #1161, `remote-<post id>`) and once because somebody here reshared it
    # (issue #1166, `remote-repost-<repost id>`) — and a report deletes the row
    # for everybody, so every row showing it has to go. Guessing the dom id
    # left the reshared copy on screen until the next reload.
    going = Enum.filter(socket.assigns.entries, &remote_entry?(&1, remote_post_id))

    socket
    |> update(:entries, &(&1 -- going))
    |> then(fn socket ->
      Enum.reduce(going, socket, &stream_delete_by_dom_id(&2, :posts, "feed-#{&1.id}"))
    end)
    |> then(&assign(&1, :empty?, &1.assigns.entries == [] and &1.assigns.pending_posts == []))
  end

  # A reply that is gone leaves the page in the same round trip, wherever it was
  # showing: its own row goes, and a thread that nested it re-renders without
  # it. Both, not either — the same reply can be on the page as a reshared row
  # while a *different* entry's thread holds another one under the post it
  # answers.
  defp take_down_note(socket, note_id, fun) do
    case fun.(note_id, socket.assigns.current_user) do
      {:ok, done} -> {:noreply, socket |> put_flash(:info, done) |> drop_note(note_id)}
      {:error, nil} -> {:noreply, socket}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp drop_note(socket, note_id) do
    {going, rest} = Enum.split_with(socket.assigns.entries, &note_entry?(&1, note_id))
    kept = Enum.map(rest, &without_note(&1, note_id))
    changed = for {before, now} <- Enum.zip(rest, kept), before != now, do: now

    socket
    |> assign(:entries, kept)
    |> then(fn socket ->
      Enum.reduce(going, socket, &stream_delete_by_dom_id(&2, :posts, "feed-#{&1.id}"))
    end)
    |> then(fn socket ->
      Enum.reduce(changed, socket, &stream_insert(&2, :posts, &1, update_only: true))
    end)
    |> then(&assign(&1, :empty?, &1.assigns.entries == [] and &1.assigns.pending_posts == []))
  end

  defp note_entry?(entry, note_id),
    do: Posts.remote_reply_entry?(entry) and entry.note.id == note_id

  defp without_note(%{remote_replies: replies} = entry, note_id) do
    kept =
      replies
      |> Map.new(fn {post_id, notes} -> {post_id, Enum.reject(notes, &(&1.id == note_id))} end)
      |> Map.reject(fn {_post_id, notes} -> notes == [] end)

    # An entry with none left goes back to being a plain card, so the key goes
    # rather than holding an empty map: `post_thread_entry/1` reads its presence.
    if kept == %{}, do: Map.delete(entry, :remote_replies), else: %{entry | remote_replies: kept}
  end

  defp without_note(entry, _note_id), do: entry

  # Both toggles on a remote card, one shape: the heart (issue #1164) and the
  # reshare (issue #1166). The entry is re-inserted into the stream rather than
  # an assign being flipped: a stream item redraws only when its own entry is
  # handed back, which is also why the state rides the entry. `:flash` is an
  # `{outcome, message}` the act announces itself with when it really happened.
  # "This row is the cached post with that id" — the one predicate the three
  # scans over `:entries` that single a remote post out all read from.
  defp remote_entry?(entry, remote_post_id),
    do:
      Posts.remote_feed_entry?(entry) and not Posts.remote_reply_entry?(entry) and
        entry.remote_post.id == remote_post_id

  # The entries carrying a vutuv post. A cached post from another network has
  # `post: nil`, so every batch read and every scan that reaches for
  # `entry.post` goes through this (or `find_by_post_id/2`) first.
  defp local_entries(entries), do: Enum.reject(entries, &Posts.remote_feed_entry?/1)

  # Re-render the one streamed card a translation state change concerns; a
  # subject not on screen is a harmless no-op (update_only). A local post may
  # sit in an entry as the leaf OR as a nested ancestor — either way the
  # entry re-renders with the current translations map.
  defp restream_translated(socket, key) do
    case find_by_translation_key(socket.assigns.entries, key) do
      nil -> socket
      entry -> stream_insert(socket, :posts, entry, update_only: true)
    end
  end

  defp find_by_translation_key(entries, key) do
    # Reuses entry_subjects/1, so "what can this entry translate" is spelled
    # once — the reverse lookup cannot drift from the auto-translate sweep.
    Enum.find(entries, fn entry ->
      Enum.any?(entry_subjects(entry), &(PostTranslations.subject_key(&1) == key))
    end)
  end

  defp find_by_post_id(entries, post_id) do
    Enum.find(entries, fn entry ->
      not Posts.remote_feed_entry?(entry) and entry.post.id == post_id
    end)
  end

  # Every post id currently represented on screen — each streamed entry's own
  # post plus every ancestor it nests — so a live or paged repost of an
  # already-shown post updates that card (or drops) instead of duplicating it.
  defp shown_post_ids(entries) do
    for entry <- local_entries(entries),
        post <- [entry.post | entry[:ancestors] || []],
        into: MapSet.new(),
        do: post.id
  end

  # Fold a new reposter into an on-screen card's avatar stack, in place: keep
  # the entry's stream id (so the row updates where it sits, no jump) and just
  # grow the roster + rename the newest reposter. A repost we already counted
  # (idempotent re-broadcast) is a no-op.
  defp restack_shown(socket, entry, reposter) do
    case restacked_entry(entry, reposter) do
      nil ->
        socket

      updated ->
        socket
        |> update(:entries, &replace_entry(&1, entry.id, updated))
        |> stream_insert(:posts, updated, update_only: true)
    end
  end

  # Same fold for a card still waiting behind the "show new" pill: it has no
  # stream row yet, so only its pending map grows (it reveals with the full
  # stack when the pill is clicked).
  defp restack_pending(socket, pending, reposter) do
    case restacked_entry(pending, reposter) do
      nil -> socket
      updated -> update(socket, :pending_posts, &replace_entry(&1, pending.id, updated))
    end
  end

  # nil when this reposter is already counted (idempotent re-broadcast), else the
  # entry with the reposter folded into its roster and named as the newest.
  #
  # The **total** grows with it and the list stays capped
  # (`Posts.reposter_roster_cap/0`): the banner reads the total for its "and N
  # others" and the list only for the faces, so letting the list grow while the
  # total stood still made the tail count backwards — a post with no roster yet
  # answered `-1` and took the page down on `ngettext`.
  defp restacked_entry(entry, reposter) do
    unless Enum.any?(entry.reposters, &(&1.id == reposter.id)) do
      roster = Enum.take([reposter | entry.reposters], Posts.reposter_roster_cap())

      %{entry | reposters: roster, reposted_by: reposter}
      |> Map.put(:reposters_total, (entry[:reposters_total] || length(entry.reposters)) + 1)
    end
  end

  defp replace_entry(entries, id, updated) do
    Enum.map(entries, fn entry -> if entry.id == id, do: updated, else: entry end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- `FeedUrl` writes the calendar's day into the address bar (see
    `sync_url/1`). It hangs off the page root rather than off the calendar
    because there are two calendars, one per breakpoint, and the URL has one
    owner. --%>
    <div id="feed" phx-hook="FeedUrl" class="py-6">
      <%!-- Two columns on desktop: the feed, plus the rail that uses the
      otherwise-empty side space. The rail is desktop-only (the grid collapses
      to one column under md, and the rail is hidden anyway). --%>
      <%!-- `data-filter-scope` pairs the controls that reload the timeline with
      the timeline itself: while such a press is in flight the stylesheet dims
      everything marked `data-filter-list` inside this container, so the press
      is answered on the spot instead of a round trip later. It sits on the
      grid rather than on the timeline column because the controls moved to the
      rail — the band's source rows are the successor to the tab presses this
      paint was built for, and both markers have to stay under one element. --%>
      <div data-filter-scope class="grid gap-6 md:grid-cols-3">
        <%!-- min-w-0: below md the grid is a single implicit `auto` track that
        respects this column's min-content, so a long `truncate` descendant (a
        threaded reply's parent-excerpt) would otherwise force the column — and
        the whole page — wider than a phone viewport. --%>
        <%!-- `space-y-6`, the same scale the rail uses, and that is the whole
        reason it is 6 and not 4: both columns open with a 40px control (this
        column's compose line, the rail's folded calendar) sitting on one line,
        so an equal gap under each is what puts the timeline and the first rail
        card on one line too. They were 8px apart while this column was tighter.

        It has to be the LOOSER of the two. A gap under the control that is
        tighter than the rhythm between the cards below reads as the control
        belonging to the first card — the calendar looked like part of "Tags,
        denen Sie folgen" when it was tried the other way round. --%>
        <div class="min-w-0 space-y-6 md:col-span-2">
          <%!-- No visible headline: the top nav already marks Feed as active,
          so the page opens with the compose tile (like the profile's Beiträge
          card) and the h1 stays for screen readers only. The Likes/Bookmarks
          links that used to balance the headline were redundant — both live
          in the avatar menu and as tabs on the saved hub. --%>
          <h1 class="sr-only">{gettext("Feed")}</h1>

          <%!-- ONE control line, `h-10`, always present and never taller: the
          height the folded rail calendar and the filter button already take, so
          the two columns start level and the timeline's top edge is fixed. What
          it replaced was a 72px card whose input-shaped tile invited typing it
          could not take, plus a waiting-posts row that only existed on a desktop
          once a post had arrived — which shoved the timeline down 56px and
          sprang back on the press.

          Compose is a BUTTON now, and it owns the whole line while nothing is
          waiting. When something is, it gives up everything it does not need
          (`flex-none`) and the quote takes the rest; below `sm` it drops its
          word and keeps the glyph, the way the filter button beside the
          calendar already does, or the teaser is left with three letters on a
          phone. Only the widths move, never the height.

          It stays in the DOM while the composer is open, merely hidden, and the
          display class is picked by ONE condition so the two can never both land
          on it (the #880 trap: `hidden` loses the cascade to a `flex` beside
          it). A conditional element ABOVE the editor is the caret-killer of
          #1200 — morphdom relocates the following siblings to restore their
          order and re-parenting a `contenteditable` blurs it — which is why the
          line itself is unconditional and only its contents change. --%>
          <div
            id="composer-trigger"
            class={[
              if(@composer_open?, do: "hidden", else: "flex"),
              "items-center gap-2"
            ]}
          >
            <.compose_button alone?={@pending_posts == []} />

            <.new_posts_pill
              :if={@pending_posts != []}
              pending_posts={@pending_posts}
              pending_overflow={@pending_overflow}
              cal_day={@cal_day}
            />
          </div>

          <%!-- The panel is just the composer component; its corner ✕ bubbles a
          `close-composer` up to this LiveView, and it also collapses on its own
          after the viewer posts (see the {:new_post, …} handler). --%>
          <div id="composer-panel" class={[!@composer_open? && "hidden"]}>
            <.live_component
              module={VutuvWeb.PostLive.Composer}
              id="composer"
              host={:feed}
              current_user={@current_user}
              acting_as={@acting_as}
              post={nil}
              preloaded_draft={{:loaded, @draft}}
            />
          </div>

          <%!-- Two controls, and on a phone this is the only way to either. The
          calendar is the phone's copy of the rail's — there is no filter column
          under `md`, and the way back from an opened day is not optional the way
          the rest of the rail is; the filter button opens the band as a sheet
          for the same reason.

          Folded, the calendar takes what the filter button leaves; unfolded it
          claims the whole line and the button wraps under it, because a month
          grid squeezed beside a button draws day cells too small to hit.

          The row is phone-only, full stop: the waiting-posts quote moved up to
          the compose line, which exists at every width, so there is nothing left
          here for a desktop to show. That also gave the calendar its line back —
          it no longer slides aside to make room (`.feed-cal-slot--away`), and
          the filter button keeps its word. --%>
          <div id="feed-mobile-controls" class="flex flex-wrap items-center gap-2 md:hidden">
            <%!-- The wrapper collapses, not the card: a card cannot shrink past
            its own padding and ring (border-box floors its width there), and
            clipping it from outside costs nothing. --%>
            <div
              id="feed-calendar-mobile-slot"
              class={["feed-cal-slot", @cal_open? && "basis-full"]}
            >
              <.feed_calendar
                id="feed-calendar-mobile"
                open?={@cal_open?}
                earlier?={@cal_earlier?}
                month={@cal_month}
                day={@cal_day}
                metric={@cal_metric}
                counts={@cal_counts}
                counts_pending?={@cal_counts_pending?}
                capped?={@cal_capped?}
                today={@cal_today}
              />
            </div>

            <button
              type="button"
              id="open-filter-sheet"
              phx-click="open-band"
              aria-label={pgettext("feed filter sheet", "Filter")}
              class="inline-flex h-10 shrink-0 items-center gap-2 rounded-full bg-white px-3 text-sm font-semibold text-slate-700 shadow-sm ring-1 ring-slate-200 hover:bg-slate-50 dark:bg-slate-900 dark:text-slate-200 dark:ring-slate-800 dark:hover:bg-slate-800"
            >
              <svg
                class="h-5 w-5 shrink-0"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
                aria-hidden="true"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M12 3c2.755 0 5.455.232 8.083.678.533.09.917.556.917 1.096v1.044a2.25 2.25 0 0 1-.659 1.591l-5.432 5.432a2.25 2.25 0 0 0-.659 1.591v2.927a2.25 2.25 0 0 1-1.244 2.013L9.75 21v-6.568a2.25 2.25 0 0 0-.659-1.591L3.659 7.409A2.25 2.25 0 0 1 3 5.818V4.774c0-.54.384-1.006.917-1.096A48.32 48.32 0 0 1 12 3Z"
                />
              </svg>
              <span>{pgettext("feed filter sheet", "Filter")}</span>
            </button>
          </div>

          <%!-- The timeline is one card of flat divide-y rows — the same
          container and shared <.post_thread_entry> the profile Posts section
          uses, so the feed and a profile read as one UX (a reply nests the post
          it answers inline instead of the old flat "Replying to @handle"
          banner). Gated on @empty? so an empty feed shows the message below
          rather than a blank card; every live insert flips @empty? in the same
          diff, so the container is present whenever there is (or just became)
          content. --%>
          <%!-- `NewMarks` (app.js) watches this container's own children for
          the unread dots the pill's command stamps on them, and takes each one
          off once the reader has looked at that card. --%>
          <.post_list
            :if={!@empty?}
            id="feed-posts"
            phx-update="stream"
            phx-hook="NewMarks"
            data-filter-list
          >
            <%!-- Three ways a row can render, in precedence order: hidden by a
            filter, a cached post from another network, or a vutuv post. Named
            once each in one branch, so no pair of conditions has to be kept
            complementary by hand. --%>
            <div
              :for={{dom_id, entry} <- @streams.posts}
              id={dom_id}
              class={post_row_class()}
              hidden={pending_row?(entry, @pending_posts)}
            >
              <%!-- The line saying where the list ended when the reader got
              here. It is rendered by the boundary row rather than streamed as a
              row of its own, so it cannot end up in the wrong place and costs
              one `update_only` re-insert to appear (`show_seam/1`). --%>
              <.visit_seam :if={entry.id == @seam_entry_id} />
              <%= cond do %>
                <% hidden_by_filter?(entry, @revealed_filters) -> %>
                  <%!-- A content-filtered post (issue #940) collapses to a line
                  the reader can still open, instead of vanishing (a silently
                  shorter feed confuses and breaks reply threads). --%>
                  <.filtered_placeholder
                    pattern={entry.filtered_by}
                    record={entry[:filtered_post]}
                    key={filter_key(entry)}
                  />
                <% Posts.remote_reply_entry?(entry) -> %>
                  <%!-- A reply from another network that somebody here passed
                  on (issue #1275). The same card the conversation draws, with
                  the reshare line above it — what is new is the sharing. --%>
                  <.remote_reply_card
                    note={entry.note}
                    viewer={@current_user}
                    marks={entry[:marks]}
                    reposted_by={entry.reposted_by}
                    translations={@post_translations}
                    live?
                  />
                <% Posts.remote_feed_entry?(entry) -> %>
                  <%!-- A post by an account the reader follows out there: the
                  same remote skin the reply cards wear, one federating heart
                  (issue #1164; replies and boosts are #1165/#1166), and its own
                  report control. --%>
                  <.remote_post_card
                    live?
                    remote_post={entry.remote_post}
                    images={entry[:images] || []}
                    marks={entry[:marks]}
                    reposted_by={entry[:reposted_by]}
                    boosted_by={entry[:boosted_by]}
                    following?={entry[:following?] == true}
                    viewer={@current_user}
                    translations={@post_translations}
                  />
                <% true -> %>
                  <%!-- A vutuv member's post that a followed account out there
                  re-shared (issue #1167). The local card, with the line that
                  says who passed it on above it — this is how members get
                  discovered through the outside network. --%>
                  <.boosted_banner :if={entry[:boosted_by]} account={entry.boosted_by} />
                  <.post_thread_entry
                    post={entry.post}
                    viewer={@current_user}
                    acting_as={@acting_as}
                    viewer_follow={entry[:viewer_follow]}
                    ancestors={entry[:ancestors]}
                    ancestor_engagement={entry[:ancestor_engagement] || %{}}
                    remote_replies={entry[:remote_replies] || %{}}
                    note_marks={entry[:note_marks]}
                    remote_parents={entry[:remote_parents] || %{}}
                    reposted_by={entry.reposted_by}
                    reposters={entry[:reposters]}
                    reposters_total={entry[:reposters_total]}
                    entry_id={entry.id}
                    conn_or_socket={@socket}
                    engagement={entry.engagement}
                    translations={@post_translations}
                    surface={:flat}
                  />
              <% end %>
            </div>
          </.post_list>

          <%!-- With one source switched off in the band, say which half is
          missing — otherwise a reader who muted the other one is looking at an
          empty page with no hint that they emptied it themselves. A feed that
          is empty with both halves on keeps the general invitation, which is
          the one that helps a new member. --%>
          <%!-- Travelled back past the beginning of this member's feed. Neither
          sentence below fits that: one blames a source switch and the other
          tells somebody with a full timeline to go find people to follow. What
          is actually true is that nothing had reached them yet by then, and the
          only useful control is the way back. --%>
          <.card :if={@empty? && !at_now?(assigns)} class="text-center">
            <p class="text-slate-600 dark:text-slate-400">
              {gettext("Nothing reached your feed on %{day}.",
                day: ViewerClock.format(@cal_day, :date)
              )}
            </p>
            <.button phx-click="travel-now" class="mt-3">{gettext("Back to now")}</.button>
          </.card>

          <p
            :if={
              @empty? && @pending_posts == [] && @feed_filter != :all &&
                at_now?(assigns)
            }
            class="text-slate-600 dark:text-slate-400"
          >
            {feed_filter_empty_text(to_string(@feed_filter))}
          </p>

          <p
            :if={
              @empty? && @pending_posts == [] && @feed_filter == :all &&
                at_now?(assigns)
            }
            class="text-slate-600 dark:text-slate-400"
          >
            {gettext("Nothing here yet. Follow people to fill your feed, or write your first post.")}
            <.link
              navigate={~p"/listings/most_followed_users"}
              class="font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >
              {gettext("Discover people to follow")}
            </.link>
          </p>

          <.load_more :if={@more?} />

          <%!-- On a busy day, the second way out: the reader opened a bounded
          thing and "Load more" walks it ten at a time. Only shown when there is
          actually more of the day left, and only for a day — at now there is no
          "all", the feed goes back forever. --%>
          <%!-- `day_total > 0` as well: the count comes from the heatmap, which
          is only computed while the calendar is unfolded, and a button offering
          "the whole day (0 posts)" would be worse than no button. --%>
          <div :if={@more? && @cal_day && day_total(@cal_counts, @cal_day) > 0} class="text-center">
            <button
              type="button"
              id="load-day-all"
              phx-click="load-day-all"
              phx-disable-with={gettext("Loading…")}
              class="text-sm font-semibold text-brand-600 hover:text-brand-700 dark:text-brand-400 dark:hover:text-brand-300"
            >
              {ngettext(
                "Load the whole day (%{formatted} post)",
                "Load the whole day (%{formatted} posts)",
                day_total(@cal_counts, @cal_day),
                formatted: delimited_count(day_total(@cal_counts, @cal_day))
              )}
            </button>
          </div>

          <%!-- On mobile (where the desktop rail is hidden) the "Other formats"
          card drops to the bottom of the page; the rail itself stays
          desktop-only. The links are the feed's own agent siblings (/feed.md
          etc.) — the viewer's timeline in another format, not their profile. --%>
          <.other_formats_card
            base_path="/feed"
            locale={@locale}
            id="feed-other-formats-mobile"
            class="md:hidden"
          />
        </div>

        <%!-- Desktop-only rail (hidden under md, where the grid is one column):
        the cards the reader arranged, in the order they arranged them. Rendered
        WITH the page on purpose: a lazily loaded rail popped in after the paint
        and read as slowness (the v7.200.3 laziness was undone). --%>
        <aside id="feed-rail" class="hidden space-y-6 md:block">
          <%!-- The calendar variant lives here, at the top of the filter
          column, because that is where a month grid belongs: beside the
          timeline it describes rather than on top of it. Deliberately ABOVE
          the arrangeable cards and not one of them — it is a navigation
          control, not a card the reader curates away, and putting it in the
          rail's stored order would let somebody hide the only way back. --%>
          <.feed_calendar
            id="feed-calendar-rail"
            open?={@cal_open?}
            earlier?={@cal_earlier?}
            month={@cal_month}
            day={@cal_day}
            metric={@cal_metric}
            counts={@cal_counts}
            counts_pending?={@cal_counts_pending?}
            capped?={@cal_capped?}
            today={@cal_today}
          />

          <%!-- Every card is dragged by its own grip and the hook pushes the
          sequence they were dropped into. That sequence lists only what is on
          screen — half these cards are conditional — which is why
          `Posts.rearrange_feed_rail/2` merges it into the stored order rather
          than replacing it. --%>
          <div
            id="rail-blocks"
            phx-hook="Reorder"
            data-reorder-item="[data-rail-block]"
            data-reorder-event="rail-reorder"
            class="space-y-6"
          >
            <%= for key <- @rail.order, rail_showing?(key, assigns) do %>
              <%= case key do %>
                <% "unread" -> %>
                  <%!-- What arrived while the reader was reading. The timeline
                  itself never moves under them — new posts wait here and come
                  down only when they say so — so this card is the answer to "is
                  anything happening", asked without giving up your place. It is
                  the same queue the pill above the timeline counts
                  (`@pending_posts`) and the same event, so the two can never
                  disagree.

                  What it holds is what came in while this page was open: the
                  feed has no read marker, so "since your last visit" is not a
                  set it can compute yet. --%>
                  <.rail_block
                    key="unread"
                    title={rail_title("unread")}
                    rail={@rail}
                    dot
                    count={compact_count(pending_count(assigns))}
                  >
                    <.unread_body
                      entries={@pending_posts}
                      total={pending_count(assigns)}
                      click={show_pending(assigns)}
                    />
                  </.rail_block>
                <% "sources" -> %>
                  <%!-- The filter band (the source tabs' successor): one
                  timeline plus a switch per account, per fediverse server and
                  per source. It writes through the same contexts the feed reads
                  — `follows.muted`, `fediverse_follows.muted`,
                  `users.feed_muted_hosts` and, for the two source rows, the very
                  `users.feed_source` column the tabs used — and then hands the
                  fresh member back here so the page is re-run against it.

                  `entries` is passed for the word block's preview and the tag
                  suggestions: both answer "what would this do to the feed in
                  front of me", and that question can only be asked of the page
                  actually on screen. --%>
                  <.rail_block key="sources" title={rail_title("sources")} rail={@rail}>
                    <.live_component
                      module={VutuvWeb.PostLive.FilterBand}
                      id="filter-band"
                      block={:sources}
                      current_user={@current_user}
                      filter={@feed_filter}
                      refresh={@band_refresh}
                      entries={@entries}
                    />
                  </.rail_block>
                <% "words" -> %>
                  <.rail_block key="words" title={rail_title("words")} rail={@rail}>
                    <.live_component
                      module={VutuvWeb.PostLive.FilterBand}
                      id="filter-band-words"
                      block={:words}
                      current_user={@current_user}
                      filter={@feed_filter}
                      entries={@entries}
                    />
                  </.rail_block>
                <% "hidden_tags" -> %>
                  <.rail_block key="hidden_tags" title={rail_title("hidden_tags")} rail={@rail}>
                    <.live_component
                      module={VutuvWeb.PostLive.FilterBand}
                      id="filter-band-tags"
                      block={:tags}
                      current_user={@current_user}
                      filter={@feed_filter}
                      entries={@entries}
                    />
                  </.rail_block>
                <% "followed_tags" -> %>
                  <%!-- "Tags you follow" (issue #872): the viewer's tag
                  subscriptions, each a chip linking to the tag page with a
                  reload-free ✕ unfollow. Shown only once at least one tag is
                  followed. --%>
                  <.rail_block key="followed_tags" title={rail_title("followed_tags")} rail={@rail}>
                    <.followed_tags_body
                      tags={@followed_tags}
                      suggestions={@tag_suggestions}
                      missing={@tag_missing}
                    />
                  </.rail_block>
                <% "newcomers" -> %>
                  <%!-- "New here": five of the newest members, drawn at random
                  and shown with their face, what they do and three of their
                  tags. It replaces a most-followed suggestion rail, whose
                  problem was not its data but its arithmetic: a ranking shows
                  the same well-connected members to everybody, and the one
                  person for whom being seen decides whether they come back at
                  all — the one who signed up this morning — is precisely the one
                  it can never surface. The card asks for a greeting rather than
                  a recommendation, which is a thing a reader can give away for
                  free and a newcomer can feel. --%>
                  <.rail_block key="newcomers" title={rail_title("newcomers")} rail={@rail}>
                    <:action>
                      <.reshuffle_button
                        id="newcomers-reshuffle"
                        event="reshuffle-newcomers"
                        label={gettext("Greet other members")}
                      />
                    </:action>
                    <.newcomers_body
                      newcomers={@newcomers}
                      current_user={@current_user}
                      following_by_id={@following_by_id}
                    />
                  </.rail_block>
                <% _ -> %>
              <% end %>
            <% end %>
          </div>

          <%!-- What the reader took out, offered back. A removed card leaves no
          trace in the rail itself — that is the point of removing it — so this
          is the only way back, and it has to be somewhere they will look for it:
          at the foot of the very column the card came out of. It renders only
          when something is actually put away, so a reader who never removed a
          card never sees it. --%>
          <div
            :if={@rail.removed != []}
            id="rail-removed"
            class="rounded-2xl border border-dashed border-slate-300 p-4 dark:border-slate-700"
          >
            <p class="mb-2 text-xs text-slate-500 dark:text-slate-400">
              {gettext("Put away:")}
            </p>
            <div class="flex flex-wrap gap-2">
              <button
                :for={key <- @rail.removed}
                type="button"
                id={"rail-restore-#{key}"}
                phx-click="rail-restore"
                phx-value-key={key}
                class="inline-flex items-center gap-1 rounded-lg bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-600 hover:bg-slate-200 hover:text-slate-900 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-slate-700 dark:hover:text-slate-100"
              >
                <span aria-hidden="true">+</span>{rail_title(key)}
              </button>
            </div>
          </div>

          <.other_formats_card base_path="/feed" locale={@locale} id="feed-other-formats" />
        </aside>
      </div>
      <%!-- The band on a phone. The rail is a desktop column and there is no
      room for one under `md`, so the same three cards arrive as a sheet over
      the feed — which is also the honest shape for them there: a reader opens
      it to change something and closes it again, rather than living beside it.

      Rendered only while it is open, so the three components (and their
      queries) cost nothing to a reader who never opens it. They carry their own
      ids for that reason: the desktop rail is still in the DOM behind the sheet,
      merely hidden by CSS, and two live components may not share one id.

      No arranging controls here. The order, the folding and the putting away
      are about a column that only exists on a desktop; on a phone the three
      cards are simply the filter. --%>
      <div
        :if={@band_sheet?}
        id="band-sheet"
        class="fixed inset-0 z-50 md:hidden"
        phx-window-keydown="close-band"
        phx-key="escape"
      >
        <div
          class="absolute inset-0 bg-slate-900/40"
          phx-click="close-band"
          aria-hidden="true"
        >
        </div>
        <div
          role="dialog"
          aria-modal="true"
          aria-label={pgettext("feed filter sheet", "Filter")}
          class="absolute inset-x-0 bottom-0 top-12 overflow-y-auto rounded-t-2xl bg-slate-50 p-4 pb-[calc(1rem+env(safe-area-inset-bottom))] dark:bg-slate-950"
        >
          <div class="mb-4 flex items-center gap-3">
            <h2 class="min-w-0 flex-1 truncate text-base font-semibold text-slate-900 dark:text-slate-100">
              {pgettext("feed filter sheet", "Filter")}
            </h2>
            <button
              type="button"
              id="close-band-sheet"
              phx-click="close-band"
              class="inline-flex h-10 items-center rounded-full bg-brand-600 px-4 text-sm font-semibold text-white hover:bg-brand-700"
            >
              {gettext("Done")}
            </button>
          </div>

          <div class="space-y-4">
            <.card>
              <.section_title class="mb-1">{rail_title("sources")}</.section_title>
              <.live_component
                module={VutuvWeb.PostLive.FilterBand}
                id="sheet-band"
                block={:sources}
                current_user={@current_user}
                filter={@feed_filter}
                refresh={@band_refresh}
                entries={@entries}
              />
            </.card>
            <.card>
              <.section_title class="mb-1">{rail_title("words")}</.section_title>
              <.live_component
                module={VutuvWeb.PostLive.FilterBand}
                id="sheet-band-words"
                block={:words}
                current_user={@current_user}
                filter={@feed_filter}
                entries={@entries}
              />
            </.card>
            <.card>
              <.section_title class="mb-1">{rail_title("hidden_tags")}</.section_title>
              <.live_component
                module={VutuvWeb.PostLive.FilterBand}
                id="sheet-band-tags"
                block={:tags}
                current_user={@current_user}
                filter={@feed_filter}
                entries={@entries}
              />
            </.card>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
