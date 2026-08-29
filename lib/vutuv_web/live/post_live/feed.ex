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

  alias Phoenix.LiveView.JS
  alias Vutuv.Activity
  alias Vutuv.ContentFilters
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Social
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.Live.DayClockRestream
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.MountHandoff
  alias VutuvWeb.Live.PostTranslations
  alias VutuvWeb.Live.RemotePostActions
  alias VutuvWeb.Live.RemoteReplyActions
  alias VutuvWeb.PostTeaser
  alias VutuvWeb.UserHelpers

  # The origin's like/repost figures on a card from another network tick
  # while this page is open (issue #1283). One line, no handler.
  on_mount(VutuvWeb.Live.RemoteCounts)

  # What a mount loads, and what every older page after it adds. The arrival
  # page is deliberately double the rest: it is the one page nobody asked for,
  # so it has to carry the reader past the first few scrolls without a round
  # trip, while an older page is fetched while they are still reading and can
  # afford to be half the size.
  @first_page_size 40
  @page_size 20
  # What a source switch loads (see `load_source_filter/2`) — deliberately
  # smaller than either, because that press is a wait with nothing on screen to
  # read while it lasts.
  @filter_page_size 10
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
      {:ok, mount_feed(socket, user)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You must be logged in to access that page"))
       |> redirect(to: ~p"/login")}
    end
  end

  defp mount_feed(socket, user) do
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
      case MountHandoff.take(user.id, {:feed, remembered}) do
        {:ok, payload} -> apply_feed_payload(socket, payload)
        :error -> apply_feed_payload(socket, feed_payload(user, remembered))
      end
    else
      payload = feed_payload(user, remembered)
      MountHandoff.stash(user.id, {:feed, remembered}, payload)
      apply_feed_payload(socket, payload)
    end
  end

  # Everything a feed mount computes, as data — what the dead render hands the
  # connected mount through the single-use stash.
  defp feed_payload(user, remembered) do
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

    page = Posts.feed_page(user, limit: @first_page_size, filter: filter)
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
  defp apply_feed_payload(socket, payload) do
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
  end

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
  # The one-line stand-in for a content-filtered post (issue #940): says which
  # The newest waiting post as the pair the pill quotes, or nil when there is
  # nothing to quote (a photo with no caption, an author we cannot name).
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

  defp unread_body(assigns) do
    assigns = assign(assigns, :shown, Enum.take(assigns.entries, @unread_shown))

    ~H"""
    <div id="unread-posts">
      <button
        :for={entry <- @shown}
        type="button"
        phx-click={reveal_pending()}
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
      <.button
        id="unread-insert"
        variant="secondary"
        class="mt-3 w-full"
        phx-click={reveal_pending()}
      >
        {ngettext(
          "Show %{formatted} post in the feed",
          "Show %{formatted} posts in the feed",
          length(@entries),
          formatted: compact_count(length(@entries))
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
    page =
      Posts.feed_page(socket.assigns.current_user,
        limit: @page_size,
        cursor: socket.assigns.cursor,
        filter: socket.assigns.feed_filter
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
      |> with_engagement(socket.assigns.current_user)
      |> mark_filtered(socket.assigns.content_filters, socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign(:more?, page.more?)
     |> assign(:cursor, page.next_cursor)
     |> update(:entries, &(&1 ++ entries))
     |> stream(:posts, entries, at: -1)
     |> watch_pending_photos(entries)
     |> auto_translate_entries(entries)}
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
    RemotePostActions.mute(socket, account_id, &drop_remote_entries_of(&1, account_id))
  end

  # And the same menu's way out that lasts. The rows leave for the same reason —
  # they were here because of that follow — and the cached posts themselves go
  # with it once nobody here follows the account any more.
  def handle_event("unfollow-remote-account", %{"id" => account_id}, socket) do
    RemotePostActions.unfollow(socket, account_id, &drop_remote_entries_of(&1, account_id))
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

    # The rows are already on the page and the browser has already shown them
    # (`reveal_pending/0`). All that is left here is the state behind them: the
    # card and the pill go, and every later re-render of those rows now renders
    # them visible, because that is decided by this list.
    {:noreply, socket |> assign(:pending_posts, []) |> assign(:empty?, false)}
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
    |> assign(:entries, entries)
    |> stream(:posts, entries, reset: true)
    |> watch_pending_photos(entries)
  end

  @impl true
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
  def handle_info(:day_changed, socket) do
    {:noreply, DayClockRestream.restream(socket, :entries, :posts)}
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
  defp reveal_pending do
    JS.set_attribute({"data-pending-shown", "1"}, to: "#feed-posts > [hidden]")
    |> JS.remove_attribute("hidden", to: "#feed-posts > [hidden]")
    |> JS.push("show-new")
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

  # Swap the refreshed entry into the retained list by its stable entry id.
  defp replace_entry(entries, updated), do: replace_entry(entries, updated.id, updated)

  # Own activity (this or another session) appears immediately; other
  # people's waits behind the pill — and only when the post is visible.
  defp insert_entry(socket, nil, _actor_id), do: {:noreply, socket}

  defp insert_entry(socket, entry, actor_id) do
    user = socket.assigns.current_user

    cond do
      # The author must see what they just wrote. Every live arrival carries a
      # vutuv post, so on the Fediverse tab there is no row to put it in — the
      # feed switches back to All and reloads rather than swallowing the post,
      # which from the composer reads as the post having been lost.
      actor_id == user.id and
          not Posts.feed_filter_accepts?(socket.assigns.feed_filter, entry) ->
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
      Posts.feed_filter_accepts?(socket.assigns.feed_filter, entry) ->
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
    <div id="feed" class="py-6">
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
        <div class="min-w-0 space-y-4 md:col-span-2">
          <%!-- No visible headline: the top nav already marks Feed as active,
          so the page opens with the compose tile (like the profile's Beiträge
          card) and the h1 stays for screen readers only. The Likes/Bookmarks
          links that used to balance the headline were redundant — both live
          in the avatar menu and as tabs on the saved hub. --%>
          <h1 class="sr-only">{gettext("Feed")}</h1>

          <%!-- Collapsed by default: the shared avatar-card trigger (see
          <.composer_trigger>), revealed via phx-click, plus the camera button
          that opens the very same composer and client-side clicks its "Add
          photos" control (the label exists in the hidden panel, so the
          native picker opens in the same gesture; if a browser refuses the
          scripted click, the opened composer still shows the control). The
          composer stays mounted (just hidden) so a half-typed draft survives
          a background feed re-render; posting or the composer's corner ✕
          collapses it. A reconnect re-mounts this LiveView and would
          collapse it under a draft, so a drafting composer re-opens itself
          (:composer_drafting). --%>
          <%!-- Hidden rather than dropped while the composer is open, and the
          display class is picked by ONE condition so the two can never both
          land on the element (the #880 trap: `hidden` loses the cascade to a
          `flex` beside it). A conditional
          element ABOVE the editor is the caret-killer of #1200: when it comes
          and goes, morphdom relocates the following siblings to restore their
          order — a removeChild + insertBefore of #composer-panel, measured —
          and re-parenting a `contenteditable` blurs it, so a member typing
          when the composer collapses or re-opens loses the caret and the
          keystrokes after it. --%>
          <div
            id="composer-trigger"
            class={[
              if(@composer_open?, do: "hidden", else: "flex"),
              "items-center gap-2 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-slate-200 dark:bg-slate-900 dark:ring-slate-800"
            ]}
          >
            <.composer_trigger
              viewer={@current_user}
              surface={:flat}
              avatar_size="md"
              class="min-w-0 flex-1"
              id="open-composer"
              phx-click="open-composer"
            >
              {gettext("Write a post")}
            </.composer_trigger>
            <button
              type="button"
              id="open-photo-composer"
              phx-click={
                JS.push("open-composer")
                |> JS.dispatch("click", to: "#composer-add-photos input[type=file]")
              }
              title={gettext("Post photos")}
              aria-label={gettext("Post photos")}
              class="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-slate-100 text-slate-600 hover:bg-slate-200 hover:text-slate-900 dark:bg-slate-800 dark:text-slate-300 dark:hover:bg-slate-700 dark:hover:text-slate-100"
            >
              <svg
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
                aria-hidden="true"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M6.827 6.175A2.31 2.31 0 0 1 5.186 7.23c-.38.054-.757.112-1.134.175C2.999 7.58 2.25 8.507 2.25 9.574V18a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9.574c0-1.067-.75-1.994-1.802-2.169a47.865 47.865 0 0 0-1.134-.175 2.31 2.31 0 0 1-1.64-1.055l-.822-1.316a2.192 2.192 0 0 0-1.736-1.039 48.774 48.774 0 0 0-5.232 0 2.192 2.192 0 0 0-1.736 1.039l-.821 1.316Z"
                />
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M16.5 12.75a4.5 4.5 0 1 1-9 0 4.5 4.5 0 0 1 9 0Z"
                />
              </svg>
            </button>
          </div>

          <%!-- The panel is just the composer component; its corner ✕ bubbles a
          `close-composer` up to this LiveView, and it also collapses on its own
          after the viewer posts (see the {:new_post, …} handler). --%>
          <div id="composer-panel" class={[!@composer_open? && "hidden"]}>
            <.live_component
              module={VutuvWeb.PostLive.Composer}
              id="composer"
              current_user={@current_user}
              acting_as={@acting_as}
              post={nil}
              preloaded_draft={{:loaded, @draft}}
            />
          </div>

          <%!-- One line, two controls, and on a phone it is the only way to
          either of them. The filter button opens the band as a sheet, because
          the rail it normally lives in does not exist under `md`; the pill
          brings the waiting posts down and carries the newest one's opening
          line, since the phone has no "Not read yet" card to say what is
          waiting rather than merely how much.

          They share the line and the width is fought over: as soon as there is
          a quote to read, the filter button drops its word and keeps the glyph
          alone (Stefan, on the fourth demo). With nothing waiting the row is a
          phone-only affair, so it hides itself entirely on a desktop rather
          than leaving a gap above the timeline. --%>
          <div class={["flex items-center gap-2", @pending_posts == [] && "md:hidden"]}>
            <button
              type="button"
              id="open-filter-sheet"
              phx-click="open-band"
              aria-label={pgettext("feed filter sheet", "Filter")}
              class="inline-flex h-10 shrink-0 items-center gap-2 rounded-full bg-white px-3 text-sm font-semibold text-slate-700 shadow-sm ring-1 ring-slate-200 hover:bg-slate-50 md:hidden dark:bg-slate-900 dark:text-slate-200 dark:ring-slate-800 dark:hover:bg-slate-800"
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
              <span :if={@pending_posts == []}>{pgettext("feed filter sheet", "Filter")}</span>
            </button>

            <div :if={@pending_posts != []} class="min-w-0 flex-1 text-center">
              <button
                id="show-new-posts"
                type="button"
                phx-click={reveal_pending()}
                class="mx-auto flex w-full max-w-full items-center gap-2 rounded-full bg-brand-50 px-4 py-2 text-sm font-semibold text-brand-700 shadow-sm hover:bg-brand-100 sm:w-auto dark:bg-brand-900/40 dark:text-brand-100 dark:hover:bg-brand-900/70"
              >
                <span class="shrink-0 tabular-nums">
                  {ngettext(
                    "Show %{formatted} new post",
                    "Show %{formatted} new posts",
                    length(@pending_posts),
                    formatted: compact_count(length(@pending_posts))
                  )}
                </span>
                <span
                  :if={newest_quote(@pending_posts)}
                  class="flex min-w-0 flex-1 items-baseline gap-1 font-normal text-brand-600 dark:text-brand-200"
                >
                  <span class="min-w-0 max-w-[45%] shrink truncate">
                    {newest_quote(@pending_posts).who}
                  </span>
                  <span class="min-w-0 flex-1 truncate">{newest_quote(@pending_posts).text}</span>
                </span>
              </button>
            </div>
          </div>

          <%!-- The timeline is one card of flat divide-y rows — the same
          container and shared <.post_thread_entry> the profile Posts section
          uses, so the feed and a profile read as one UX (a reply nests the post
          it answers inline instead of the old flat "Replying to @handle"
          banner). Gated on @empty? so an empty feed shows the message below
          rather than a blank card; every live insert flips @empty? in the same
          diff, so the container is present whenever there is (or just became)
          content. --%>
          <.post_list :if={!@empty?} id="feed-posts" phx-update="stream" data-filter-list>
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
          <p
            :if={@empty? && @pending_posts == [] && @feed_filter != :all}
            class="text-slate-600 dark:text-slate-400"
          >
            {feed_filter_empty_text(to_string(@feed_filter))}
          </p>

          <p
            :if={@empty? && @pending_posts == [] && @feed_filter == :all}
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
                    count={compact_count(length(@pending_posts))}
                  >
                    <.unread_body entries={@pending_posts} />
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
