defmodule VutuvWeb.UserProfileLive do
  @moduledoc """
  The member profile page (`/:slug`) as a LiveView, reached only for the HTML
  format. `VutuvWeb.UserController.show` keeps owning format negotiation and
  serves the agent-format siblings (.md/.txt/.json/.xml/.vcf) from
  `VutuvWeb.AgentDocs.ProfileDoc`, then delegates the HTML render here via
  `live_render/3` — so the agent formats are untouched while the human page
  behaves like a native app.

  The viewer controls that read as "the same action over and over" — the header
  Follow / Following pill and the tag endorsement pills — are `phx-click`
  handled here, so the page never reloads. The profile also subscribes to the
  owner's `Vutuv.Activity` topic (`"user:<id>"`), so the follower / following /
  connection counts and the tag endorsement counts update live whenever the
  social graph changes, **even when the change happens on another page or is
  made by another member** (e.g. someone follows this member from their feed).

  The page renders the very same `VutuvWeb.UserHTML.show/1` the controller used
  (embedded from `templates/user/show.html.heex`), so there is one profile
  markup. When that page gains or loses public data, keep `ProfileDoc` in sync —
  `agent_docs_drift_test.exs` enforces it.
  """
  use VutuvWeb, :live_view

  import Ecto.Query
  import VutuvWeb.UserHelpers

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.CodeStats
  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.Language
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.Follow
  alias Vutuv.SocialFeed
  alias Vutuv.Tags
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement
  alias VutuvWeb.Live.InitAssigns

  # The controller embeds this LiveView with `live_render/3` (not a `live/3`
  # router route), so `VutuvWeb.Live.InitAssigns` cannot be the on_mount: it
  # attaches a `:handle_params` hook, which an off-router LiveView rejects.
  # Mount mirrors what it would have done (current_user + the session locale),
  # and the shell path comes straight from the session instead of that hook.
  @impl true
  def mount(_params, session, socket) do
    current_user = InitAssigns.load_user(session["user_id"])
    VutuvWeb.LiveLocale.put_locale(current_user, session)

    profile_user_id = session["profile_user_id"]

    # The owner topic carries the live count / endorsement / follow-state
    # changes; subscribing only when connected keeps the disconnected (SEO /
    # test) render a single pass.
    if connected?(socket) do
      Activity.subscribe(profile_user_id)
      # Roll the shown posts' Berlin-day stamps over at midnight ("09:50 Uhr" ->
      # "Gestern, 09:50 Uhr") without a reload.
      Vutuv.DayClock.subscribe()
    end

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_id, current_user && current_user.id)
      |> assign(:profile_user_id, profile_user_id)
      # The shared layout reads @locale (contact / address localization, the
      # "Other formats" ?lang= suffix) and @shell_path (the embedded ShellLive)
      # straight off the socket; the controller hands both through the session.
      |> assign(:locale, session["locale"])
      |> assign(:shell_path, session["request_path"])
      # The Certificates & licenses card's All / Certificates / Licenses tab
      # (issue #859), one of "all" / "certification" / "license". Set once here
      # so it survives the PubSub re-renders that rebuild the profile assigns.
      |> assign(:qualifications_tab, "all")
      |> load_profile()

    # Only a real visitor triggers the (cached, single-flight) social feed
    # fetches; the disconnected SEO pass stays a no-network render. Rebinds:
    # the accounts being fetched carry the loading spinner on their rows.
    socket = if connected?(socket), do: request_social_feed_posts(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    # The big template lives in templates/user/show.html.heex, embedded as
    # VutuvWeb.UserHTML.show/1, so the profile has exactly one markup and there
    # is nothing to keep in sync between a dead and a live copy.
    VutuvWeb.UserHTML.show(assigns)
  end

  # ── Live viewer actions (no reload) ──
  # Each mirrors the controller action it replaces and calls the same context
  # function, then refreshes only the affected slice of the page.

  @impl true
  def handle_event("follow", %{"followee" => followee_id}, socket) do
    me = socket.assigns.current_user

    cond do
      is_nil(me) or me.id == followee_id ->
        {:noreply, socket}

      match?({:ok, _}, Social.follow(me, followee_id)) ->
        {:noreply, refresh_social(socket)}

      true ->
        {:noreply, put_flash(socket, :error, gettext("Something went wrong"))}
    end
  end

  def handle_event("unfollow", %{"id" => follow_id}, socket) do
    me = socket.assigns.current_user

    # Scoped to the viewer, so a request can only drop the viewer's own edge.
    if me do
      Social.unfollow!(me.id, follow_id)
      {:noreply, refresh_social(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("endorse", %{"id" => user_tag_id}, socket) do
    if can_endorse?(socket, user_tag_id) do
      # Through the Tags chokepoint so the owner gets the live notification.
      Tags.create_endorsement(%{
        user_tag_id: user_tag_id,
        user_id: socket.assigns.current_user.id
      })

      {:noreply, refresh_tags(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("unendorse", %{"id" => user_tag_id}, socket) do
    if can_endorse?(socket, user_tag_id) do
      Tags.delete_endorsement(user_tag_id, socket.assigns.current_user.id)
      {:noreply, refresh_tags(socket)}
    else
      {:noreply, socket}
    end
  end

  # Filter the Certificates & licenses card to one kind (issue #859). Pure view
  # state — no query — so an unknown value simply falls back to :all.
  def handle_event("qualifications_tab", %{"tab" => tab}, socket) do
    tab = if tab in ~w(certification license), do: tab, else: "all"
    {:noreply, assign(socket, :qualifications_tab, tab)}
  end

  # Mute / unmute the viewer's own follow (feed-only, silent). Scoped to the
  # header's follow id so a crafted id is ignored; keeps its flash (the effect —
  # the followee's posts leaving your feed — is not visible on the profile).
  def handle_event("toggle_mute", %{"id" => follow_id}, socket) do
    me = socket.assigns.current_user

    if me && follow_id == socket.assigns.header_follow_id do
      follow = Social.toggle_follow_mute!(me.id, follow_id)

      message =
        if follow.muted do
          gettext("Muted. Their posts no longer appear in your feed.")
        else
          gettext("Unmuted. Their posts appear in your feed again.")
        end

      {:noreply,
       socket |> assign(:header_follow_muted?, follow.muted) |> put_flash(:info, message)}
    else
      {:noreply, socket}
    end
  end

  # Private, silent saves of this member (bookmark / like): no follow, no
  # notification, no public count. The menu label flips on re-render.
  def handle_event("bookmark_user", _params, socket),
    do: {:noreply, save_member(socket, &Social.bookmark_user/2, gettext("Bookmarked."))}

  def handle_event("unbookmark_user", _params, socket),
    do: {:noreply, save_member(socket, &Social.unbookmark_user/2, gettext("Bookmark removed."))}

  def handle_event("like_user", _params, socket),
    do: {:noreply, save_member(socket, &Social.like_user/2, gettext("Liked."))}

  def handle_event("unlike_user", _params, socket),
    do: {:noreply, save_member(socket, &Social.unlike_user/2, gettext("Like removed."))}

  # Block / unblock this member. Both reshape the page (follows severed, the
  # control swaps to Unblock and back, counts change), so reload the whole
  # profile rather than patch a slice. The context is idempotent and scoped.
  def handle_event("block_user", _params, socket) do
    me = socket.assigns.current_user
    user = socket.assigns.user

    if me && me.id != user.id && match?({:ok, _}, Social.block_user(me, user)) do
      {:noreply,
       socket
       |> put_flash(:info, VutuvWeb.BlockText.blocked_flash(user.username))
       |> load_profile()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("unblock_user", _params, socket) do
    me = socket.assigns.current_user
    user = socket.assigns.user

    if me && me.id != user.id do
      Social.unblock_user(me, user)

      {:noreply,
       socket
       |> put_flash(:info, gettext("You unblocked @%{slug}.", slug: user.username))
       |> load_profile()}
    else
      {:noreply, socket}
    end
  end

  # Close the profile-completion checklist for good (its × control). Owner-only;
  # persists the flag so it stays gone on reload and on any later PubSub
  # re-render (load_profile re-reads the user and honours onboarding_dismissed?).
  def handle_event("dismiss_onboarding", _params, socket) do
    me = socket.assigns.current_user
    user = socket.assigns.user

    if me && me.id == user.id do
      {:ok, user} = Accounts.dismiss_onboarding(user)

      {:noreply, socket |> assign(:user, user) |> assign(:show_completion?, false)}
    else
      {:noreply, socket}
    end
  end

  # ── Live updates from elsewhere ──
  # Broadcast on the owner's topic by Vutuv.Social / Vutuv.Tags, so the page
  # reflects changes made on another page or by another member.

  @impl true
  def handle_info({:social_graph_changed, _payload}, socket),
    do: {:noreply, refresh_social(socket)}

  def handle_info({:endorsement_changed, _user_tag_id}, socket),
    do: {:noreply, refresh_tags(socket)}

  # A shown post was deleted elsewhere. The owner's posts broadcast their
  # deletion on the owner's topic (which this page already subscribes to), so
  # drop the entry rather than leave a stale card whose action-bar component no
  # longer subscribes per post. A post outside the shown preview (or a followed
  # author's, also on this topic) simply isn't found and nothing changes.
  def handle_info({:post_deleted, %{post_id: post_id}}, socket) do
    kept = Enum.reject(socket.assigns.posts, &(&1.post.id == post_id))

    socket =
      if length(kept) == length(socket.assigns.posts) do
        socket
      else
        socket
        |> assign(:posts, kept)
        |> assign(:posts_total, max(socket.assigns.posts_total - 1, 0))
      end

    {:noreply, socket}
  end

  # The Berlin day rolled over at midnight (Vutuv.DayClock): re-fetch the shown
  # posts so their stamps re-render with the new day ("today" -> "Gestern").
  # A fresh list (new identity) is what makes change tracking re-render the
  # `:for` over @posts; content barely differs, only the relative wording.
  def handle_info(:day_changed, socket) do
    posts = Vutuv.Posts.profile_posts(socket.assigns.user, socket.assigns.current_user)

    {:noreply, socket |> assign(:posts, posts) |> refresh_social_feed_stamps()}
  end

  # The social feed cache answered a mount-time request (or a concurrent
  # visitor's fetch this page joined — single-flight): drop the account's
  # loading spinner and, on success, fold the feed into the mixed posts card.
  # An error keeps the page exactly as it is (fail silent).
  def handle_info({:social_feed_posts, provider, handle, result}, socket) do
    key = {provider, handle}

    if Enum.any?(socket.assigns.social_feed_accounts, &(feed_key(&1) == key)) do
      socket =
        socket
        |> assign(:social_feed_loading, MapSet.delete(socket.assigns.social_feed_loading, key))
        |> put_social_feed(key, result)
        |> assign_social_feed_entries()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # The fetch never answered (a crashed cache loses its waiters): stop the
  # spinner rather than let it spin forever; the posts simply stay absent.
  def handle_info({:social_feed_loading_timeout, key}, socket) do
    loading = MapSet.delete(socket.assigns.social_feed_loading, key)
    {:noreply, assign(socket, :social_feed_loading, loading)}
  end

  # A background code-stats fetch finished (this mount's stale-refresh, or an
  # account just saved on the settings page): re-read the accounts so the
  # "Code" card fills or updates without a reload.
  def handle_info({:code_stats_updated, _account_id}, socket) do
    user =
      Repo.preload(socket.assigns.user, [social_media_accounts: SocialMediaAccount.ordered()],
        force: true
      )

    {:noreply,
     socket
     |> assign(:user, user)
     |> assign(:code_stats_accounts, CodeStats.visible_accounts(user))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The remote posts' <.post_time> wording ("09:50 Uhr" -> "Gestern, ...")
  # is computed at render, but the feed data itself is unchanged at midnight
  # and assign/3 skips equal values — flip through empty so the card
  # re-renders with the new Berlin day, like the vutuv posts above.
  defp refresh_social_feed_stamps(socket) do
    case socket.assigns.social_feed_entries do
      [] ->
        socket

      entries ->
        socket |> assign(:social_feed_entries, []) |> assign(:social_feed_entries, entries)
    end
  end

  # Only a logged-in non-owner may endorse, and only a *non* honor tag
  # actually shown on this profile (the pill is rendered for those alone), so an
  # arbitrary user_tag id — or a crafted endorse of an honor tag — is
  # ignored.
  defp can_endorse?(socket, user_tag_id) do
    me = socket.assigns.current_user

    me && me.id != socket.assigns.user.id &&
      Enum.any?(
        socket.assigns.user_tags,
        &(&1.id == user_tag_id and not &1.tag.honor?)
      )
  end

  # Run a private-save toggle (bookmark/like a member) for a logged-in
  # non-owner, then re-read the saved flags so the menu item label flips, and
  # confirm with the same copy the controller used.
  defp save_member(socket, fun, ok_msg) do
    me = socket.assigns.current_user
    user = socket.assigns.user

    cond do
      is_nil(me) or me.id == user.id ->
        socket

      fun.(me, user) == :ok ->
        socket
        |> assign(:user_saved, Social.user_saved_flags(me, user))
        |> put_flash(:info, ok_msg)

      true ->
        socket
    end
  end

  # Recompute the follow-graph slice after a follow/unfollow: re-preload just the
  # follow previews on the loaded user, then rebuild the shared social assigns.
  defp refresh_social(socket) do
    user =
      Repo.preload(
        socket.assigns.user,
        [
          inbound_follows: {Follow.latest(3, :follower), [:follower]},
          outbound_follows: {Follow.latest(3, :followee), [:followee]}
        ],
        force: true
      )

    put_social_assigns(socket, user)
  end

  # The follow-graph slice of the assigns, shared by the initial load and the
  # live refresh so the two can't drift: the three counts, the header pill's
  # directional state, and the follower / following previews (plus the per-row
  # work-info and follow-state maps those rows read). Reads current_user /
  # recommended_users off the socket, so set those before piping through here.
  defp put_social_assigns(socket, user) do
    current_user = socket.assigns.current_user

    followers = Enum.map(user.inbound_follows, & &1.follower)
    followees = Enum.map(user.outbound_follows, & &1.followee)

    preview_users =
      Enum.uniq_by(socket.assigns.recommended_users ++ followers ++ followees, & &1.id)

    # The header's whole follow state derives from at most the two directional
    # follow edges (viewer→owner, owner→viewer); resolve both once here instead
    # of the six overlapping lookups the four header_* helpers used to fire.
    rel = header_relationship(current_user, user)

    socket
    |> assign(:user, user)
    |> assign(:follower_count, Social.follower_count(user))
    |> assign(:followee_count, Social.followee_count(user))
    |> assign(:connection_count, Social.connection_count(user))
    |> assign(:header_follow_id, rel.follow_id)
    |> assign(:header_follows_viewer?, rel.follows_viewer?)
    |> assign(:header_connected?, rel.connected?)
    |> assign(:header_follow_muted?, rel.follow_muted?)
    |> assign(:followers, followers)
    |> assign(:followees, followees)
    |> assign(:work_info_by_id, work_information_map(preview_users, 24))
    |> assign(:following_by_id, following_map(current_user, preview_users))
  end

  # Re-read the visible tags (with their endorsers), so an endorse / unendorse
  # — here or elsewhere — re-renders the affected pill's count and roster.
  defp refresh_tags(socket) do
    assign(socket, :user_tags, load_user_tags(socket.assigns.user))
  end

  defp load_user_tags(user) do
    user
    |> Repo.preload([user_tags: user_tags_query()], force: true)
    |> Map.fetch!(:user_tags)
  end

  # ── Initial load (ports UserController.show_html) ──

  defp load_profile(socket) do
    current_user = socket.assigns.current_user
    base_user = Repo.get!(User, socket.assigns.profile_user_id)

    owner? = !!(current_user && current_user.id == base_user.id)

    totals = assoc_totals(base_user)
    user = preload_user_for_show(base_user, owner?)

    private_emails? = private_emails?(current_user, user)

    # preload_user_for_show loaded ALL work experiences (date-ordered for the
    # Experience card); resolve the header's current job from the id-sorted
    # full list, exactly like ProfileDoc and the vCard do. A truncated or
    # date-ordered list can pick a different role (a pin outside the newest
    # three, or several ongoing roles) and make header and agent docs disagree.
    header_job =
      current_job_in_memory(
        Enum.sort_by(user.work_experiences, & &1.id),
        user.profile_work_experience_id
      )

    recommended_users = recommended_users(user, current_user)

    posts_total = Vutuv.Posts.count_author_posts(user, current_user)
    steps = completion_steps(user, posts_total)

    show_completion? =
      owner? and not user.onboarding_dismissed? and
        Enum.any?(steps, &(not &1.done)) and onboarding_window?(user)

    socket
    |> assign(:as_owner?, owner?)
    |> assign(:vcard_full?, private_emails?)
    |> assign(:viewer_block, viewer_block(current_user, user))
    |> assign(:user_saved, header_user_saved(current_user, user))
    |> assign(:emails, profile_emails(private_emails?, current_user, user))
    |> assign(:posts, Vutuv.Posts.profile_posts(user, current_user))
    |> assign(:posts_total, posts_total)
    |> assign(:user_tags, user.user_tags)
    # The whole history: the Experience card clusters it and previews up to
    # WorkExperienceHTML.profile_preview_limit/0 roles. Clustering must see every
    # role so a truncated employer still shows its true total tenure (a preview
    # cut inside a company must not report only the shown roles' years).
    |> assign(:work_experience, user.work_experiences)
    |> assign(:education, user.educations)
    |> assign(:languages, user.languages)
    # Expired-credential hiding (issue #859) is already applied in the preload
    # via Qualification.visible_to(owner?): a visitor gets only valid entries,
    # the owner gets all of theirs (their card marks the lapsed ones).
    |> assign(:qualifications, user.qualifications)
    |> assign(:header_job, header_job)
    |> assign(:work_info, work_information_string_for_job(header_job, 60))
    |> assign(:completion_steps, steps)
    |> assign(:show_completion?, show_completion?)
    |> assign(:recommended_users, recommended_users)
    |> assign(:totals, totals)
    # Builds the social slice (counts, header pill state, follow previews); reads
    # :current_user / :recommended_users set above, so it goes last.
    |> put_social_assigns(user)
    |> put_social_feed_assigns(user)
    |> put_code_stats_assigns(user)
  end

  # The code-forge statistics (Vutuv.CodeStats): the "Code" card renders each
  # account's stored snapshot — a DB read, never the network. A connected
  # (real-visitor) mount additionally asks for a background refresh of stale
  # snapshots; the fresh data arrives as {:code_stats_updated, _} on the
  # owner's topic, handled above.
  defp put_code_stats_assigns(socket, user) do
    if connected?(socket) and CodeStats.enabled?() and user.show_code_stats? do
      Enum.each(CodeStats.accounts_of(user), &CodeStats.refresh_if_stale/1)
    end

    assign(socket, :code_stats_accounts, CodeStats.visible_accounts(user))
  end

  # The inline social feeds (Vutuv.SocialFeed): every feed-capable account
  # (Mastodon, Bluesky) on the profile, whatever the cache already holds for
  # each — a synchronous ETS read, never the network. The fast path runs on
  # connected sockets only, so the disconnected (SEO / crawler) pass renders
  # without posts, consistent with the agent formats (ProfileDoc deliberately
  # excludes them).
  defp put_social_feed_assigns(socket, user) do
    accounts = if user.show_mastodon_feed?, do: SocialFeed.accounts_of(user), else: []
    feeds = if connected?(socket), do: cached_social_feeds(accounts), else: %{}

    socket
    |> assign(:social_feed_accounts, accounts)
    |> assign(:social_feeds, feeds)
    |> assign(:social_feed_loading, MapSet.new())
    |> assign_social_feed_entries()
  end

  # An account's key in the feeds map / loading set: the same {provider,
  # handle} pair the cache keys by (two providers could store an identical
  # value).
  defp feed_key(account), do: {account.provider, account.value}

  # The strict %Feed{} matches double as armor: an entry written by an older
  # code version (dev code reload; the ETS table outlives the modules) must
  # degrade to "no posts", never crash the profile mount.
  defp cached_social_feeds(accounts) do
    accounts
    |> Enum.flat_map(fn account ->
      with {:ok, %SocialFeed.Feed{} = feed} <- SocialFeed.cached_posts(account),
           %SocialFeed.Feed{} = rendered <- rendered_social_feed(feed) do
        [{feed_key(account), rendered}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp put_social_feed(socket, key, {:ok, %SocialFeed.Feed{} = feed}) do
    case rendered_social_feed(feed) do
      %SocialFeed.Feed{} = rendered ->
        feeds = Map.put(socket.assigns.social_feeds, key, rendered)
        assign(socket, :social_feeds, feeds)

      _stale ->
        socket
    end
  end

  defp put_social_feed(socket, _key, _error), do: socket

  # The mixed timeline the "Social media posts" card renders: every fetched
  # account's posts tagged with their feed (name/avatar/url) and network,
  # newest first — a member's Mastodon and Bluesky accounts merge into one
  # list. The provider comes from the map key (never the cached struct, so a
  # stale ETS shape cannot break it). Cross-posts (the same text pushed to
  # both networks) collapse into one row whose `sources` carry every network
  # badge; a lone post's `sources` is just its own network.
  defp assign_social_feed_entries(socket) do
    entries =
      socket.assigns.social_feeds
      |> Enum.flat_map(fn {{provider, _handle}, feed} ->
        Enum.map(feed.posts, fn post ->
          %{
            provider: provider,
            feed: feed,
            post: post,
            key: cross_post_key(post.text),
            sources: [%{provider: provider, feed: feed}]
          }
        end)
      end)
      |> merge_cross_posts()
      |> Enum.sort_by(& &1.post.created_at, {:desc, DateTime})

    assign(socket, :social_feed_entries, entries)
  end

  # There is no shared id across networks — a crosspost is two unrelated
  # posts (a Mastodon status id and a Bluesky record key that know nothing of
  # each other) — so duplicates are matched by normalized text within a
  # posting window. The prefix rule catches the truncated copy: Bluesky caps
  # posts at 300 characters, so crossposters cut the text there.
  @cross_post_window_seconds 24 * 60 * 60
  @cross_post_prefix_min 40

  # Longest text first, so a group's keeper (the fullest copy, usually the
  # Mastodon one) is fixed before its truncated siblings arrive; the earlier
  # post wins a length tie (it is the original). A sibling contributes only
  # its network badge.
  defp merge_cross_posts(entries) do
    entries
    |> Enum.sort_by(&{-String.length(&1.post.text), DateTime.to_unix(&1.post.created_at)})
    |> Enum.reduce([], fn entry, kept ->
      case Enum.find_index(kept, &cross_post?(&1, entry)) do
        nil -> kept ++ [entry]
        index -> List.update_at(kept, index, &add_source(&1, entry))
      end
    end)
  end

  # One badge per network: a second account on an already-badged network
  # would only repeat the same glyph.
  defp add_source(keeper, entry) do
    %{keeper | sources: Enum.uniq_by(keeper.sources ++ entry.sources, & &1.provider)}
  end

  defp cross_post?(a, b) do
    a.key != "" and b.key != "" and
      abs(DateTime.diff(a.post.created_at, b.post.created_at)) <= @cross_post_window_seconds and
      same_cross_post_text?(a.key, b.key)
  end

  defp same_cross_post_text?(key, key), do: true

  defp same_cross_post_text?(a, b) do
    {long, short} = if String.length(a) >= String.length(b), do: {a, b}, else: {b, a}
    String.length(short) >= @cross_post_prefix_min and String.starts_with?(long, short)
  end

  # What survives each network's own rendering differences: links are dropped
  # (every network truncates a displayed URL its own way), punctuation and
  # whitespace collapse (the "…" a crossposter appends included), case folds.
  defp cross_post_key(text) do
    text
    |> String.downcase()
    |> String.replace(~r{https?://\S+}u, " ")
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  # The cache carries the domain feed (plain text); the page shows each post
  # through the member-post pipeline (Markdown, autolinked URLs, #hashtags to
  # our tag pages — @mentions deliberately not linked, they name remote
  # accounts, not vutuv members). Rendered once per arriving feed, not per
  # re-render. Map.put (not struct-update) plus the rescue is stale-shape
  # armor: the ETS table outlives a dev code reload, so an entry written by an
  # older module version may carry posts without the newest struct fields —
  # that must degrade to "no posts", never crash the profile mount.
  defp rendered_social_feed(%SocialFeed.Feed{} = feed) do
    %{
      feed
      | posts: Enum.map(feed.posts, &Map.put(&1, :html, VutuvWeb.Markdown.render_remote(&1.text)))
    }
  rescue
    _stale_shape -> nil
  end

  # How long an account row may show its loading spinner before giving up
  # (the fetch itself is hard-capped well below this).
  @social_feed_loading_timeout :timer.seconds(15)

  # Ask the cache for every feed not already rendered; each reply arrives as
  # a {:social_feed_posts, ...} message. request_posts/1 re-checks each
  # account's persisted backoff/deactivation gate, so a struggling server is
  # left in peace no matter how often the profile is opened. Accounts actually
  # being fetched go into :social_feed_loading — their rows show the spinner.
  defp request_social_feed_posts(socket) do
    Enum.reduce(socket.assigns.social_feed_accounts, socket, fn account, socket ->
      if Map.has_key?(socket.assigns.social_feeds, feed_key(account)) do
        socket
      else
        request_one_social_feed(socket, account)
      end
    end)
  end

  defp request_one_social_feed(socket, account) do
    case SocialFeed.request_posts(account) do
      :ok ->
        Process.send_after(
          self(),
          {:social_feed_loading_timeout, feed_key(account)},
          @social_feed_loading_timeout
        )

        loading = MapSet.put(socket.assigns.social_feed_loading, feed_key(account))
        assign(socket, :social_feed_loading, loading)

      :ignored ->
        socket
    end
  end

  # ── Viewer-scoping helpers ──

  # A private address is owner-only: only the owner's own view (resolved through
  # user_has_permissions?/2, which is now same_user?/2) reveals it.
  defp private_emails?(current_user, user),
    do: !!user_has_permissions?(user, current_user)

  # private_emails? already resolved whether the viewer may see private
  # addresses, so hand that verdict straight to the loader instead of having
  # emails_for_display/2 re-run the follow permission check.
  defp profile_emails(allowed?, _current_user, user), do: emails_for_permission(user, allowed?)

  # The viewer's header follow relationship, resolved from at most the two
  # directional follow edges — the viewer's outbound edge to the owner and the
  # owner's inbound edge back — returned as one map. Replaces four helpers that
  # re-read the same edges six times (two follow_id, the two-exists connected?,
  # and a follow_edge for the mute state).
  defp header_relationship(current_user, user) do
    if current_user && current_user.id != user.id do
      outbound = Social.follow_edge(current_user.id, user.id)
      inbound = Social.follow_edge(user.id, current_user.id)

      %{
        follow_id: outbound && outbound.id,
        follow_muted?: (outbound && outbound.muted?) || false,
        connected?: not is_nil(outbound) and not is_nil(inbound),
        follows_viewer?: not is_nil(inbound)
      }
    else
      %{follow_id: false, follow_muted?: false, connected?: false, follows_viewer?: false}
    end
  end

  defp viewer_block(current_user, user) do
    if current_user && current_user.id != user.id do
      Social.get_block(current_user.id, user.id)
    end
  end

  defp header_user_saved(current_user, user) do
    if current_user && current_user.id != user.id do
      Social.user_saved_flags(current_user, user)
    end
  end

  defp preload_user_for_show(user, owner?) do
    user
    |> Repo.preload(
      social_media_accounts: SocialMediaAccount.ordered(),
      user_tags: user_tags_query(),
      # Deliberately unlimited: the header-job pick must see every role (a
      # pinned one can sit outside the newest three; see load_profile). The
      # Experience card takes its top 3 in memory; rows per member are few.
      work_experiences: WorkExperience.order_by_date(WorkExperience),
      educations:
        from(e in Education, limit: 3)
        |> Education.order_by_date(),
      languages: Language.ordered() |> limit(6),
      # visible_to(owner?) hides expired credentials from visitors in SQL (the
      # same scope the section page, CV and agent docs use), so the card renders
      # what is loaded — no in-memory filter, and limit-after-filter is correct.
      qualifications: Qualification.visible_to(owner?) |> Qualification.ordered() |> limit(8),
      phone_numbers: PhoneNumber.ordered() |> limit(3),
      urls: Url.ordered() |> limit(3),
      addresses: Address.ordered() |> limit(3),
      inbound_follows: {Follow.latest(3, :follower), [:follower]},
      outbound_follows: {Follow.latest(3, :followee), [:followee]}
    )
  end

  # The visible-tag preload, shared by the initial load and the live refresh:
  # up to 30 tags (honor tags first, then most-endorsed), each with only its
  # visible endorsers (and the endorser preloaded for the roster), so a hidden
  # account can't inflate the count (issue #783). Keep this cap in sync with the
  # `preview={30}` the Tags card's manage_footer uses in show.html.heex.
  defp user_tags_query do
    UserTag.ordered_by_endorsements()
    |> limit(30)
    |> preload(endorsements: ^UserTagEndorsement.visible_with_endorser())
  end

  # The five section totals ("N total, showing 3") in one round trip instead of
  # five separate count queries: a union_all of per-section counts, keyed back to
  # the totals map. Each count returns exactly one row (0 when empty), so every
  # section is always present.
  defp assoc_totals(%User{id: uid}) do
    counts =
      section_count(UserTag, uid, "user_tags")
      |> union_all(^section_count(WorkExperience, uid, "jobs"))
      |> union_all(^section_count(Education, uid, "educations"))
      |> union_all(^section_count(Language, uid, "languages"))
      |> union_all(^section_count(Qualification, uid, "qualifications"))
      |> union_all(^section_count(PhoneNumber, uid, "numbers"))
      |> union_all(^section_count(Url, uid, "links"))
      |> union_all(^section_count(Address, uid, "addresses"))
      |> Repo.all()
      |> Map.new(fn %{section: section, total: total} -> {section, total} end)

    %{
      user_tags: Map.get(counts, "user_tags", 0),
      jobs: Map.get(counts, "jobs", 0),
      educations: Map.get(counts, "educations", 0),
      languages: Map.get(counts, "languages", 0),
      qualifications: Map.get(counts, "qualifications", 0),
      numbers: Map.get(counts, "numbers", 0),
      links: Map.get(counts, "links", 0),
      addresses: Map.get(counts, "addresses", 0)
    }
  end

  defp section_count(schema, uid, section) do
    from(r in schema,
      where: r.user_id == ^uid,
      select: %{section: type(^section, :string), total: count()}
    )
  end

  defp completion_steps(user, posts_total) do
    [
      # Sign-up requires three tags, so this step arrives already checked: the
      # checklist opens with visible progress instead of a wall of zeros
      # (people finish lists they have visibly started). It stays actionable
      # for tag-less accounts from before the minimum, in their
      # dormant-return window.
      %{label: gettext("Add a tag"), done: user.user_tags != [], href: ~p"/settings/tags/new"},
      %{
        label: gettext("Add a profile photo"),
        done: present?(user.avatar),
        href: ~p"/#{user}/edit"
      },
      %{label: gettext("Add a tagline"), done: present?(user.headline), href: ~p"/#{user}/edit"},
      # Same #compose hash as the Posts-card tile: land on the feed with the
      # composer already open instead of a closed one. "Add work experience"
      # is deliberately not a step any more: the checklist leads toward the
      # first post, not CV upkeep (the Experience card keeps its own tile).
      %{
        label: gettext("Write your first post"),
        done: posts_total > 0,
        href: ~p"/feed#compose",
        hint: first_post_hint(user)
      }
    ]
  end

  # A concrete first-post prompt borrowed from the member's own sign-up tags
  # ("a thought on #elixir") — which doubles as a quiet demo that #hashtags
  # work in posts. user_tags arrive most-endorsed first, slug as tiebreaker,
  # so a fresh account gets its alphabetically first tag.
  defp first_post_hint(%User{user_tags: [user_tag | _]}) do
    gettext("For example, a thought on %{tag}.", tag: "#" <> user_tag.tag.slug)
  end

  defp first_post_hint(_user), do: nil

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: true

  # The checklist is a brief, one-time post-registration nudge: it shows only
  # during the first hour after sign-up, then never again. A member who wants it
  # gone sooner closes it with the × (the dismiss_onboarding event sets
  # users.onboarding_dismissed? for good — see the show_completion? gate above).
  @onboarding_window_seconds 60 * 60

  defp onboarding_window?(user) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), user.inserted_at, :second) <
      @onboarding_window_seconds
  end

  # The rail's count, and the size of the popularity pool we top up from when the
  # topical pool is thin.
  @recommended_count 6
  @recommended_pool 60

  # The "Who to follow" rail. We suggest members most endorsed for this profile's
  # leading tag (so the suggestion is topically tied to whoever you're viewing),
  # falling back to the most-followed members when the profile has no tag. Then we
  # drop everyone the rail must never suggest: the profile owner, the `viewer`
  # themselves and — the bug this fixes — anyone the viewer *already follows*
  # (listing someone you already follow as a suggestion is pointless; the rail
  # used to come back all "Following" rows). When the topical pool is mostly
  # already-followed and runs thin, we top it up from the most-followed pool so
  # the rail still fills with fresh faces. `viewer` is the current user (nil when
  # logged out), so a logged-out visitor gets unfiltered suggestions and no
  # follow state.
  defp recommended_users(user, viewer) do
    topical =
      case first_tag(user) do
        nil -> []
        tag -> Tag.recommended_users(tag)
      end
      |> suggestable(user, viewer)

    users =
      if length(topical) >= @recommended_count do
        topical
      else
        popular = suggestable(Social.most_followed_users(@recommended_pool), user, viewer)
        Enum.uniq_by(topical ++ popular, & &1.id)
      end

    Enum.take(users, @recommended_count)
  end

  # Keep only members the rail may suggest: not the profile owner, not the viewer,
  # and not anyone the viewer already follows (one batched lookup via `following_map`).
  defp suggestable(candidates, user, viewer) do
    following = following_map(viewer, candidates)
    # `viewer` is nil for a logged-out visitor; a nil id never equals a real UUID,
    # so the comparison stays a plain boolean (a bare `viewer && …` would yield nil
    # and blow up the strict `or`).
    viewer_id = viewer && viewer.id

    Enum.reject(candidates, fn u ->
      u.id == user.id or u.id == viewer_id or Map.has_key?(following, u.id)
    end)
  end

  defp first_tag(user) do
    Repo.one(
      from(w in Ecto.assoc(user, :user_tags),
        join: t in assoc(w, :tag),
        order_by: w.inserted_at,
        limit: 1,
        select: t
      )
    )
  end
end
