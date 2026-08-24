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
  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.RemoteFollow
  alias Vutuv.Organizations.Organization
  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.Language
  alias Vutuv.Profiles.Messenger
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.References.JobReference
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.Follow
  alias Vutuv.SocialFeed
  alias Vutuv.Tags
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.Live.InitAssigns
  alias VutuvWeb.Live.MountHandoff
  alias VutuvWeb.Live.PostTranslations

  # The controller embeds this LiveView with `live_render/3` (not a `live/3`
  # router route), so `VutuvWeb.Live.InitAssigns` cannot be the on_mount: it
  # attaches a `:handle_params` hook, which an off-router LiveView rejects.
  # Mount mirrors what it would have done (current_user + the session locale),
  # and the shell path comes straight from the session instead of that hook.
  @impl true
  def mount(_params, session, socket) do
    socket = InitAssigns.assign_embedded(socket, session)

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
      |> assign(:profile_user_id, profile_user_id)
      # The Certificates & licenses card's All / Certificates / Licenses tab
      # (issue #859), one of "all" / "certification" / "license". Set once here
      # so it survives the PubSub re-renders that rebuild the profile assigns.
      |> assign(:qualifications_tab, "all")
      # On-demand translations (issue #1462): per-card view state; a map
      # means this viewer gets the controls, nil means they do not.
      |> assign(:post_translations, PostTranslations.initial_map(socket.assigns.current_user))
      |> mount_profile()

    # Only a real visitor triggers the (cached, single-flight) social feed
    # fetches; the disconnected SEO pass stays a no-network render. Rebinds:
    # the accounts being fetched carry the loading spinner on their rows.
    socket = if connected?(socket), do: request_social_feed_posts(socket), else: socket

    {:ok, socket}
  end

  # The dead render computes the page and stashes the result; the connected
  # mount — moments later, same authenticated viewer — takes it and skips
  # re-running the same ~50 queries (`VutuvWeb.Live.MountHandoff`). Any miss
  # (anonymous viewer, expired, already consumed by an earlier connect, a
  # reconnect after a blip or deploy) falls back to the plain full load, so
  # the handoff is a fast path, never a requirement.
  defp mount_profile(socket) do
    viewer_id = socket.assigns.current_user && socket.assigns.current_user.id
    subject = {:profile, socket.assigns.profile_user_id}

    if connected?(socket) do
      case MountHandoff.take(viewer_id, subject) do
        {:ok, payload} -> apply_handoff(socket, payload)
        :error -> load_profile(socket)
      end
    else
      before_keys = Map.keys(socket.assigns)
      socket = load_profile(socket)
      # Exactly the assigns load_profile added — diffed, not listed, so an
      # assign added to load_profile later rides the handoff automatically.
      MountHandoff.stash(viewer_id, subject, Map.drop(socket.assigns, before_keys))
      socket
    end
  end

  # Apply the dead render's assigns, then recompute the two connected-only
  # slices the dead pass deliberately left cold: the social-feed card reads
  # the ETS cache (no network, no DB) and the code-stats card asks for its
  # background refresh — the same calls load_profile would have made on a
  # connected socket, working off the payload's preloaded user.
  defp apply_handoff(socket, payload) do
    socket
    |> assign(payload)
    |> put_social_feed_assigns(payload.user)
    |> put_code_stats_assigns(payload.user)
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

  # Following a member **as the page you are speaking for** (issue #1336). Its
  # own pair of events rather than a branch inside the two above: the member
  # path carries a follow id and the page path does not need one (the page plus
  # this profile decide the edge), and folding them together would mean an
  # id-shaped parameter that is sometimes ignored.
  def handle_event("follow-as-page", _params, socket) do
    {:noreply, toggle_page_follow(socket, &Social.follow_as_organization/2)}
  end

  def handle_event("unfollow-as-page", _params, socket) do
    {:noreply, toggle_page_follow(socket, &Social.unfollow_as_organization/2)}
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

  def handle_event("translate", %{"kind" => kind, "id" => id}, socket) do
    case PostTranslations.request(socket.assigns.current_user, kind, id) do
      {:ok, key, state} ->
        translations = Map.put(socket.assigns.post_translations, key, state)
        {:noreply, assign(socket, :post_translations, translations)}

      :denied ->
        {:noreply, socket}
    end
  end

  def handle_event("show-original", %{"kind" => kind, "id" => id}, socket) do
    case PostTranslations.show_original(socket.assigns.post_translations, kind, id) do
      :ignore -> {:noreply, socket}
      {_key, map} -> {:noreply, assign(socket, :post_translations, map)}
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

  # Filter the Beiträge card to one entry kind (issue #945): All / Own posts /
  # Reposts / Replies. Re-fetches the preview and the active filter's total for
  # the "View all" footer; an unknown value falls back to "all".
  def handle_event("posts_filter", %{"type" => type}, socket) do
    filter = if type in ~w(all posts reposts replies), do: type, else: "all"

    {:noreply,
     socket
     |> assign(:post_filter, filter)
     |> assign_posts_with_engagement(filter)
     |> assign(
       :post_filter_total,
       Vutuv.Posts.count_author_posts(
         socket.assigns.user,
         socket.assigns.current_user,
         Vutuv.Posts.normalize_post_filter(filter)
       )
     )}
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
  # notification, no public count. The header card's two glyph toggles flip on
  # the re-render, which is the whole confirmation — no toast. They used to
  # flash one, because back when they were ⋯-menu items the label flipped out
  # of sight behind a closing menu and nothing else moved; a filled bookmark
  # sitting right under the cursor says it better, and a toast repeating it
  # trains members to stop reading toasts. The classic CSRF route
  # (UserSaveController, the no-JS path) keeps its flash: there the page
  # reloads and the flash is the only thing that reports what happened.
  def handle_event("bookmark_user", _params, socket),
    do: {:noreply, save_member(socket, &Social.bookmark_user/2)}

  def handle_event("unbookmark_user", _params, socket),
    do: {:noreply, save_member(socket, &Social.unbookmark_user/2)}

  def handle_event("like_user", _params, socket),
    do: {:noreply, save_member(socket, &Social.like_user/2)}

  def handle_event("unlike_user", _params, socket),
    do: {:noreply, save_member(socket, &Social.unlike_user/2)}

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
  def handle_info({:translation_ready, %Vutuv.Translations.Translation{} = translation}, socket) do
    case PostTranslations.apply_ready(socket.assigns.post_translations, translation) do
      :ignore -> {:noreply, socket}
      {_key, map} -> {:noreply, assign(socket, :post_translations, map)}
    end
  end

  def handle_info({:translation_failed, key, target}, socket) do
    case PostTranslations.apply_failed(socket.assigns.post_translations, key, target) do
      :ignore -> {:noreply, socket}
      {_key, map} -> {:noreply, assign(socket, :post_translations, map)}
    end
  end

  def handle_info({:social_graph_changed, _payload}, socket),
    do: {:noreply, refresh_social(socket)}

  def handle_info({:endorsement_changed, _user_tag_id}, socket),
    do: {:noreply, refresh_tags(socket)}

  # The owner changed their job-search availability or exclusion list (issue
  # #938): recompute this viewer's two visibility booleans so an excluded
  # viewer's badge / salary line drops out (or reappears) with no reload.
  def handle_info({:job_search_visibility_changed, _payload}, socket),
    do: {:noreply, put_job_search_assigns(socket, socket.assigns.user)}

  # A shown post was deleted elsewhere. The owner's posts broadcast their
  # deletion on the owner's topic (which this page already subscribes to), so
  # drop the entry rather than leave a stale card whose action-bar component no
  # longer subscribes per post. A post outside the shown preview (or a followed
  # author's, also on this topic) simply isn't found and nothing changes.
  def handle_info({:post_deleted, %{post_id: post_id}}, socket) do
    kept = Enum.reject(socket.assigns.posts, &(&1.post.id == post_id))

    # The pinned post (issue #1110) is shown above the timeline, not in it, so
    # it needs its own check. Deleting it unpins it in the DB (ON DELETE SET
    # NULL); the block has to go with it.
    pinned_gone? = match?(%{id: ^post_id}, socket.assigns.pinned_post)

    socket = if pinned_gone?, do: assign(socket, :pinned_post, nil), else: socket

    socket =
      if length(kept) == length(socket.assigns.posts) and not pinned_gone? do
        socket
      else
        # A shown post sits in both the overall count and the active filter's
        # count (it passed that filter to be shown), so drop it from each — the
        # "View all" footer stays honest under a non-"all" filter (issue #945).
        socket
        |> assign(:posts, kept)
        |> assign(:posts_total, max(socket.assigns.posts_total - 1, 0))
        |> assign(:post_filter_total, max(socket.assigns.post_filter_total - 1, 0))
      end

    {:noreply, socket}
  end

  # The Berlin day rolled over at midnight (Vutuv.DayClock): re-fetch the shown
  # posts so their stamps re-render with the new day ("today" -> "Gestern").
  # A fresh list (new identity) is what makes change tracking re-render the
  # `:for` over @posts; content barely differs, only the relative wording.
  def handle_info(:day_changed, socket) do
    {:noreply, socket |> reload_posts() |> refresh_social_feed_stamps()}
  end

  # A shown post's link screenshot finished capturing (fan-out reaches this page
  # over the profile owner's activity topic): re-fetch the posts so the card
  # gains its screenshot with no reload. A fresh list re-renders the `:for`.
  def handle_info({:post_screenshot_ready, _payload}, socket) do
    {:noreply, reload_posts(socket)}
  end

  # The owner removed a bad link screenshot: re-fetch so the card drops it.
  def handle_info({:post_screenshot_removed, _payload}, socket) do
    {:noreply, reload_posts(socket)}
  end

  # An AI image-moderation verdict landed for this profile's owner
  # (Vutuv.Moderation.ImageScans): re-fetch the user so an approved avatar /
  # cover swaps in (and the owner's limbo pill drops) with no reload; a
  # post-image verdict re-fetches the shown posts the same way.
  def handle_info({:image_moderation, kind, _subject_id, _verdict}, socket)
      when kind in ["avatar", "cover"] do
    case Vutuv.Accounts.get_user(socket.assigns.user.id) do
      nil ->
        {:noreply, socket}

      user ->
        {:noreply,
         assign(
           socket,
           :user,
           Map.merge(
             socket.assigns.user,
             Map.take(user, [
               :avatar,
               :avatar_fingerprint,
               :avatar_crop,
               :avatar_moderation,
               :cover_photo,
               :cover_fingerprint,
               :cover_crop,
               :cover_moderation,
               :updated_at
             ])
           )
         )}
    end
  end

  def handle_info({:image_moderation, "post_image", _subject_id, _verdict}, socket) do
    {:noreply, reload_posts(socket)}
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
  # non-owner, then re-read the saved flags so the glyph fills (or empties) and
  # its label flips on the re-render.
  defp save_member(socket, fun) do
    me = socket.assigns.current_user
    user = socket.assigns.user

    cond do
      is_nil(me) or me.id == user.id -> socket
      fun.(me, user) == :ok -> assign(socket, :user_saved, Social.user_saved_flags(me, user))
      true -> socket
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

    socket
    |> put_social_assigns(user, [])
    # The follow step is the one checklist item completable on this very page
    # (the promoted rail's follow buttons), so re-derive the steps and the tick
    # lands live. The checklist's visibility and the rail's promoted spot stay
    # as mounted; recomputing them here would yank the panel (or the card)
    # away under the member's cursor on the fifth follow.
    |> refresh_completion_steps()
  end

  # The follow-graph slice of the assigns, shared by the initial load and the
  # live refresh so the two can't drift: the three counts, the header pill's
  # directional state, and the follower / following previews (plus the per-row
  # work-info and follow-state maps those rows read). Reads current_user /
  # recommended_users off the socket, so set those before piping through here.
  #
  # `opts` lets the mount hand in what it already resolved — `counts:` (from
  # the one per-mount counts union) and `following:` (the hoisted follow-state
  # map) — so the initial load re-queries neither; the social-graph refresh
  # passes only fresh `counts:` and re-reads the follow map, which is exactly
  # what just changed.
  defp put_social_assigns(socket, user, opts) do
    current_user = socket.assigns.current_user

    followers = Enum.map(user.inbound_follows, & &1.follower)
    followees = Enum.map(user.outbound_follows, & &1.followee)

    preview_users =
      Enum.uniq_by(socket.assigns.recommended_users ++ followers ++ followees, & &1.id)

    # The header's whole follow state derives from at most the two directional
    # follow edges (viewer→owner, owner→viewer), read together in one query.
    rel = header_relationship(current_user, user)

    counts = Keyword.get(opts, :counts) || Social.social_counts(user)
    following = Keyword.get(opts, :following) || following_map(current_user, preview_users)

    socket
    |> assign(:user, user)
    |> assign(:follower_count, counts.followers)
    |> assign(:followee_count, counts.followees)
    |> assign(:connection_count, counts.connections)
    |> assign(:header_follow_id, rel.follow_id)
    |> assign(:header_follows_viewer?, rel.follows_viewer?)
    # Whether the page being spoken for follows this member. Only asked while
    # acting as one, so an ordinary visit pays no extra query.
    |> assign(:page_follows?, page_follows?(socket.assigns[:acting_as], user))
    |> assign(:header_connected?, rel.connected?)
    |> assign(:header_follow_muted?, rel.follow_muted?)
    |> assign(:followers, followers)
    |> assign(:followees, followees)
    |> assign(:work_info_by_id, work_information_map(preview_users, 24))
    |> assign(:following_by_id, following)
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

  # The Beiträge card's preview, honouring the active type filter (issue #945).
  # Every re-fetch path (a tab click, the midnight day roll, a screenshot /
  # image-moderation update) goes through here so a background refresh keeps
  # the filter the reader chose instead of snapping back to "all".
  defp fetch_profile_posts(socket, filter) do
    profile_posts(
      socket.assigns.user,
      socket.assigns.current_user,
      filter,
      socket.assigns[:pinned_post]
    )
  end

  # Re-fetch the Beiträge preview and hand every shown card its engagement from
  # one batched query (:posts + :pinned_engagement in one go).
  defp assign_posts_with_engagement(socket, filter) do
    {entries, pinned_engagement} =
      socket
      |> fetch_profile_posts(filter)
      |> attach_engagement(socket.assigns[:pinned_post], socket.assigns.current_user)

    socket
    |> assign(:posts, entries)
    |> assign(:pinned_engagement, pinned_engagement)
  end

  # One engagement read for everything the Beiträge card shows — the timeline
  # entries, the thread parents they nest and the pinned post — so the per-card
  # action bars render from handed-in data instead of each running the heavy
  # engagement query on mount (it ran once per card until v7.201). Returns the
  # decorated entries plus the pinned post's own engagement. A reshared remote
  # post has no vutuv post (and no action bar), so it passes through untouched.
  defp attach_engagement(entries, pinned_post, viewer) do
    ancestor_ids = fn entry -> Enum.map(entry[:ancestors] || [], & &1.id) end
    local = Enum.reject(entries, &Vutuv.Posts.remote_feed_entry?/1)

    ids =
      local
      |> Enum.flat_map(fn entry -> [entry.post.id | ancestor_ids.(entry)] end)
      |> then(&if(pinned_post, do: [pinned_post.id | &1], else: &1))
      |> Enum.uniq()

    engagement = if ids == [], do: %{}, else: Vutuv.Posts.post_engagement_map(ids, viewer)

    entries =
      Enum.map(entries, fn entry ->
        if Vutuv.Posts.remote_feed_entry?(entry) do
          entry
        else
          entry
          |> Map.put(:engagement, engagement[entry.post.id])
          |> Map.put(:ancestor_engagement, Map.take(engagement, ancestor_ids.(entry)))
        end
      end)

    {entries, pinned_post && engagement[pinned_post.id]}
  end

  # The Beiträge card shows the pinned post (issue #1110) in its own block above
  # the timeline, so the timeline leaves it out — one post, shown once. Only
  # under the unfiltered "All" tab: the filtered views are the plain timeline and
  # the pinned block is hidden there, so nothing would be missing. A repost entry
  # of the same post stays (it is a different timeline event).
  defp profile_posts(user, viewer, filter, pinned_post) do
    entries =
      Vutuv.Posts.profile_posts(user, viewer, type: Vutuv.Posts.normalize_post_filter(filter))

    if filter == "all" and pinned_post do
      Enum.reject(entries, &pinned_entry?(&1, pinned_post))
    else
      entries
    end
  end

  defp pinned_entry?(%{post: %{id: id}, reposted_by: nil}, %{id: id}), do: true
  defp pinned_entry?(_entry, _pinned_post), do: false

  # Re-fetch the shown posts in the reader's current filter and re-assign them:
  # the fresh list (new identity) re-renders the `:for` with no reload. The
  # pinned post rides along — it is a post card too, so it needs the same day
  # roll, screenshot and image-moderation refresh the timeline gets.
  defp reload_posts(socket) do
    socket
    |> assign(
      :pinned_post,
      Vutuv.Posts.pinned_post(socket.assigns.user, socket.assigns.current_user)
    )
    |> then(&assign_posts_with_engagement(&1, &1.assigns.post_filter))
  end

  # ── Initial load (ports UserController.show_html) ──

  # The discovery threshold: the owner's own profile leads the rail with the
  # promoted "Who to follow" card (and the checklist carries a follow step)
  # until they follow at least this many members. Below it their feed is too
  # empty to be worth visiting (Home.path even keeps them on the profile), so
  # discovery outranks their own detail cards.
  @discovery_follow_target 5

  # The "Who to follow" rail's count, how many ranked candidates we draw before
  # the per-viewer exclusions (self, owner, already-followed, blocked) thin
  # them, and the recent-output window a candidate must have posted within.
  # Defined above load_profile/1, which reads them (a module attribute is nil
  # until the line that sets it).
  @recommended_count 6
  @recommended_pool 60
  @suggested_window_days 28

  defp load_profile(socket) do
    current_user = socket.assigns.current_user
    base_user = Repo.get!(User, socket.assigns.profile_user_id)

    owner? = !!(current_user && current_user.id == base_user.id)

    # Every count the page renders — the nine section totals, the three social
    # counts and the posts total — in ONE union query per mount (they were
    # three separate round trips, the three most expensive queries on the page).
    counts = profile_counts(base_user, current_user)
    totals = section_totals(counts)
    posts_total = Map.get(counts, "posts_total", 0)

    social_counts = %{
      followers: Map.get(counts, "followers", 0),
      followees: Map.get(counts, "followees", 0),
      connections: Map.get(counts, "connections", 0)
    }

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

    # One follow-state lookup serves both the "Who to follow" filter and the
    # preview rows' follow buttons: the candidates and the follower/followee
    # previews are resolved against the viewer together, instead of
    # `following_map/2` running once for each.
    followers = Enum.map(user.inbound_follows, & &1.follower)
    followees = Enum.map(user.outbound_follows, & &1.followee)
    candidates = Vutuv.Posts.top_recent_posters(@suggested_window_days, @recommended_pool)

    following =
      following_map(
        current_user,
        Enum.uniq_by(candidates ++ followers ++ followees, & &1.id)
      )

    recommended_users =
      candidates
      |> suggestable(user, current_user, following)
      |> Enum.take(@recommended_count)

    # The showcased post (issue #1110), scoped to this viewer: a pin that is
    # restricted, frozen or gone simply isn't there. It renders above the
    # timeline, which therefore leaves it out (see profile_posts/4).
    pinned_post = Vutuv.Posts.pinned_post(user, current_user)

    {post_entries, pinned_engagement} =
      user
      |> profile_posts(current_user, "all", pinned_post)
      |> attach_engagement(pinned_post, current_user)

    socket
    |> assign(:as_owner?, owner?)
    |> assign(:vcard_full?, private_emails?)
    |> assign(:viewer_block, viewer_block(current_user, user))
    |> assign(:user_saved, header_user_saved(current_user, user))
    |> assign(:emails, profile_emails(private_emails?, current_user, user))
    |> assign(:pinned_post, pinned_post)
    |> assign(:pinned_engagement, pinned_engagement)
    |> assign(:posts, post_entries)
    |> assign(:posts_total, posts_total)
    # The Beiträge card's type filter (issue #945). Resets to "all" on a full
    # profile reload (mount, block/unblock); a tab click re-fetches in place.
    # :post_filter_total is the active filter's count, driving the "View all"
    # footer; it equals :posts_total while the filter is "all".
    |> assign(:post_filter, "all")
    |> assign(:post_filter_total, posts_total)
    |> assign(:user_tags, user.user_tags)
    # The whole history: the Experience card clusters it and previews up to
    # WorkExperienceHTML.profile_preview_limit/0 roles. Clustering must see every
    # role so a truncated employer still shows its true total tenure (a preview
    # cut inside an organization must not report only the shown roles' years).
    |> assign(:work_experience, user.work_experiences)
    |> assign(:education, user.educations)
    |> assign(:languages, user.languages)
    # Expired-credential hiding (issue #859) is already applied in the preload
    # via Qualification.visible_to(owner?): a visitor gets only valid entries,
    # the owner gets all of theirs (their card marks the lapsed ones).
    |> assign(:qualifications, user.qualifications)
    # Only the published ones are preloaded, so the owner sees exactly what a
    # visitor sees here; their private entries live at /settings/job_references.
    |> assign(:job_references, user.job_references)
    |> assign(:header_job, header_job)
    # The header line: a pinned education (issue #882) leads with its
    # "Degree, School", else the pinned/heuristic job's "Title @ Org". The user
    # already has :educations preloaded, so profile_headline/3 resolves it in
    # memory (no extra query). header_job stays the resolved work role for the
    # JSON-LD Person markup below.
    |> assign(:work_info, profile_headline(user, header_job, 60))
    |> assign(:recommended_users, recommended_users)
    # The two-line samples under each suggestion. Drawn once with the slate
    # itself: the rail's membership is fixed for the page view (a follow only
    # flips that row's button), so re-drawing them on every refresh would cost
    # a query to render the same lines.
    |> assign(
      :suggested_posts_by_id,
      Vutuv.Posts.recent_posts_by_authors(recommended_users, current_user)
    )
    |> assign(:totals, totals)
    # Builds the social slice (counts, header pill state, follow previews); reads
    # :current_user / :recommended_users set above, so it goes last. The counts
    # and the follow-state map were already resolved above (the counts union,
    # the hoisted following_map), so the mount hands them in instead of
    # re-querying; the refresh path passes neither and queries fresh.
    |> put_social_assigns(user, counts: social_counts, following: following)
    # The rail promotion and the checklist's follow step both read the followee
    # count put_social_assigns just computed. The promotion is deliberately set
    # only here, never on the social-graph refresh: the fifth follow, made from
    # the promoted rail itself, must not teleport the card to the bottom of the
    # page under the member's cursor. The next visit demotes it.
    |> then(
      &assign(
        &1,
        :promote_discovery?,
        owner? and &1.assigns.followee_count < @discovery_follow_target
      )
    )
    |> refresh_completion_steps()
    |> then(&assign(&1, :show_completion?, show_completion?(&1.assigns)))
    |> put_social_feed_assigns(user)
    |> put_code_stats_assigns(user)
    |> put_job_search_assigns(user)
    |> put_fediverse_assigns(user)
  end

  # The Fediverse half of the Subscribe card (nil = no half; the card itself
  # still renders for the RSS feed), written for a visitor who is NOT a member:
  # someone on Mastodon and friends needs the member's address over there,
  # which the page never showed. Pure field reads
  # plus the federation gate, so it costs no query. `moved_to` is set when the
  # member redirected their Fediverse followers to another account (issue #986):
  # the handle here still resolves, but following it would be a dead end, so the
  # card shows the forwarding address instead of the follow tool.
  defp put_fediverse_assigns(socket, user) do
    card =
      if Fediverse.federated?(user) do
        %{
          handle: Docs.handle(user),
          moved_to: user.moved_to,
          moved_handle: user.moved_to && RemoteFollow.display_address(user.moved_to)
        }
      end

    assign(socket, :fediverse, card)
  end

  # The two job-search field visibilities for this viewer (issue #928 base gate
  # + issue #938 exclusion list), resolved together in one query. Kept as
  # assigns so a PubSub re-render (the owner editing their availability or
  # exclusion list) can recompute them without reload; the template reads the
  # two booleans instead of calling the gate inline.
  defp put_job_search_assigns(socket, user) do
    vis = Accounts.job_search_visibility(user, socket.assigns.current_user)

    socket
    |> assign(:show_employment_status?, vis.employment_status)
    |> assign(:show_desired_salary?, vis.salary)
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
  # owner's inbound edge back — read together in one query
  # (`Social.follow_edges_between/2`) and returned as one map. Replaces four
  # helpers that re-read the same edges six times (two follow_id, the
  # two-exists connected?, and a follow_edge for the mute state).
  defp header_relationship(current_user, user) do
    if current_user && current_user.id != user.id do
      %{outbound: outbound, inbound: inbound} =
        Social.follow_edges_between(current_user.id, user.id)

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

  defp page_follows?(%Organization{} = page, %User{} = user),
    do: Social.organization_follows?(page, user)

  defp page_follows?(_acting_as, _user), do: false

  # Both page-follow events go through here: resolve who is speaking, refuse
  # anything but a page, act, then re-read the state from the database rather
  # than assuming the write landed.
  defp toggle_page_follow(socket, fun) do
    case socket.assigns[:acting_as] do
      %Organization{} = page ->
        fun.(page, socket.assigns.user)
        assign(socket, :page_follows?, page_follows?(page, socket.assigns.user))

      _not_acting ->
        socket
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

  # THE single source of the per-section preview caps: preload_user_for_show/2
  # limits its preloads with it and user/show.html.heex reads the same numbers
  # for its `preview={...}` / "more than the preview" checks, so the queries
  # and the template can never disagree. :experience rides along too — its
  # preload is deliberately unlimited (see below) and the cap is applied
  # in memory by WorkExperienceHTML.grouped_clusters/3, reached through the
  # delegating WorkExperienceHTML.profile_preview_limit/0.
  @preview_limits %{
    experience: 10,
    educations: 3,
    languages: 6,
    qualifications: 8,
    phone_numbers: 3,
    links: 3,
    addresses: 3,
    followers: 3,
    following: 3
  }

  @doc """
  How many entries a profile section card previews before its footer switches
  to "View All (N)" — one number per section, shared by this LiveView's
  preloads and the `preview={...}` checks in `user/show.html.heex`.
  """
  def preview_limit(section), do: Map.fetch!(@preview_limits, section)

  defp preload_user_for_show(user, owner?) do
    user
    |> Repo.preload(
      social_media_accounts: SocialMediaAccount.ordered(),
      messengers: Messenger.ordered(),
      user_tags: user_tags_query(),
      # Deliberately unlimited: the header-job pick must see every role (a
      # pinned one can sit outside the newest three; see load_profile). The
      # Experience card takes its preview_limit(:experience) top roles in
      # memory; rows per member are few.
      # display_preloads: the verified organization page (issue #931) and the
      # cited credential (issue #858) ride along for the Experience card.
      work_experiences:
        {WorkExperience.order_by_date(WorkExperience), WorkExperience.display_preloads()},
      educations:
        from(e in Education, limit: ^preview_limit(:educations))
        |> Education.order_by_date(),
      languages: Language.ordered() |> limit(^preview_limit(:languages)),
      # visible_to(owner?) hides expired credentials from visitors in SQL (the
      # same scope the section page, CV and agent docs use), so the card renders
      # what is loaded — no in-memory filter, and limit-after-filter is correct.
      # citing_jobs_preload: the jobs earned with each credential ride along
      # for the usage badges (issue #1005).
      qualifications:
        {Qualification.visible_to(owner?)
         |> Qualification.ordered()
         |> limit(^preview_limit(:qualifications)), Qualification.citing_jobs_preload()},
      # Published Arbeitszeugnisse. No limit: a member holds a handful, and the
      # card's total is the loaded list, which keeps this out of the counts
      # union query. `:links` rides along so the card can name the CV entry a
      # Zeugnis documents — and so the CV entries can name their Zeugnis back,
      # from the same rows, without a query per entry.
      job_references: {JobReference.public_scope(), :links},
      phone_numbers: PhoneNumber.ordered() |> limit(^preview_limit(:phone_numbers)),
      urls: Url.ordered() |> limit(^preview_limit(:links)),
      addresses: Address.ordered() |> limit(^preview_limit(:addresses)),
      inbound_follows: {Follow.latest(preview_limit(:followers), :follower), [:follower]},
      outbound_follows: {Follow.latest(preview_limit(:following), :followee), [:followee]}
    )
  end

  # The visible-tag preload, shared by the initial load and the live refresh:
  # up to 30 tags (honor tags first, then most-endorsed), each with only its
  # visible endorsers (and the endorser preloaded for the roster), so a hidden
  # account can't inflate the count (issue #783). The 30 is a defensive bound
  # only, not a preview cap: members hold at most Vutuv.Tags.max_user_tags/0
  # (15) tags, and the Tags card's footer always links to /:slug/tags instead
  # of truncating on a preview threshold.
  defp user_tags_query do
    UserTag.ordered_by_endorsements()
    |> limit(30)
    |> preload(endorsements: ^UserTagEndorsement.visible_with_endorser())
  end

  # Every count the profile renders, in ONE round trip: the nine section
  # totals ("N total, showing 3"), the three social-graph counts
  # (`Social.profile_count_queries/1`) and the viewer-scoped posts total
  # (`Posts.author_timeline_count_query/2`) — a 13-arm union_all keyed back to
  # a `kind => total` map. They used to run as three separate queries (and
  # before that, as sixteen), which made counting the most expensive thing on
  # the page after the preloads. Each arm returns exactly one row (0 when
  # empty), so every kind is always present.
  defp profile_counts(%User{id: uid} = user, viewer) do
    [first | rest] =
      [
        section_count(UserTag, uid, "user_tags"),
        section_count(WorkExperience, uid, "jobs"),
        section_count(Education, uid, "educations"),
        section_count(Language, uid, "languages"),
        section_count(Qualification, uid, "qualifications"),
        section_count(PhoneNumber, uid, "numbers"),
        section_count(Messenger, uid, "messengers"),
        section_count(Url, uid, "links"),
        section_count(Address, uid, "addresses")
      ] ++
        Social.profile_count_queries(uid) ++
        [Vutuv.Posts.author_timeline_count_query(user, viewer)]

    rest
    |> Enum.reduce(first, fn arm, acc -> union_all(acc, ^arm) end)
    |> Repo.all()
    |> Map.new(fn %{kind: kind, total: total} -> {kind, total} end)
  end

  # The section-totals map the template reads, from the combined counts.
  defp section_totals(counts) do
    %{
      user_tags: Map.get(counts, "user_tags", 0),
      jobs: Map.get(counts, "jobs", 0),
      educations: Map.get(counts, "educations", 0),
      languages: Map.get(counts, "languages", 0),
      qualifications: Map.get(counts, "qualifications", 0),
      numbers: Map.get(counts, "numbers", 0),
      messengers: Map.get(counts, "messengers", 0),
      links: Map.get(counts, "links", 0),
      addresses: Map.get(counts, "addresses", 0)
    }
  end

  defp section_count(schema, uid, kind) do
    from(r in schema,
      where: r.user_id == ^uid,
      select: %{kind: type(^kind, :string), total: count()}
    )
  end

  # Re-derive the checklist from the current assigns; called from the initial
  # load and from the social-graph refresh (the follow step's count changes
  # live). Reads :followee_count, so it must run after put_social_assigns.
  defp refresh_completion_steps(socket) do
    %{user: user, followee_count: followee_count} = socket.assigns

    assign(
      socket,
      :completion_steps,
      completion_steps(user, followee_count, socket.assigns.recommended_users != [])
    )
  end

  defp show_completion?(%{as_owner?: owner?, user: user, completion_steps: steps}) do
    owner? and not user.onboarding_dismissed? and
      Enum.any?(steps, &(not &1.done)) and onboarding_window?(user)
  end

  defp completion_steps(user, followee_count, suggestions?) do
    [
      # Sign-up requires three tags, so this step arrives already checked: the
      # checklist opens with visible progress instead of a wall of zeros
      # (people finish lists they have visibly started). It stays actionable
      # for tag-less accounts from before the minimum, in their
      # dormant-return window.
      %{label: gettext("Add a tag"), done: user.user_tags != [], href: ~p"/settings/tags/new"},
      # Both land on /settings/profile, which is where the two fields actually
      # live. They used to point at /:slug/edit, the retired owner URL that only
      # redirects there — one wasted round trip, and a link that shows the old
      # address in the status bar.
      %{
        label: gettext("Add a profile photo"),
        done: present?(user.avatar),
        href: ~p"/settings/profile"
      },
      %{
        label: gettext("Add a tagline"),
        done: present?(user.headline),
        href: ~p"/settings/profile"
      },
      # There is deliberately NO "write your first post" step. It asked the one
      # thing a member cannot do well on their first minute here — they have
      # nobody reading yet and nothing to answer — and it is the step a new
      # account is least likely to complete, so the list ended on a dead end.
      # Posting has its own permanent invitation at the top of the Posts card
      # and on the feed; it does not need a checkbox.
      # vutuv runs on following: the feed stays empty until the member follows
      # people, so the list closes with the social step. Its link jumps to the
      # "Who to follow" card, which the under-threshold owner view promotes to
      # the top of the rail; an installation with nobody to suggest falls back
      # to the browsable most-followed listing instead of a dead anchor.
      %{
        # Deliberately no number in the label. "Follow 5 members" reads as a
        # quota to be served, and the figure is ours, not the member's. The
        # threshold below still decides when the step is done; the hint under it
        # reports real progress, which is the encouraging half of a count.
        label: gettext("Follow other members"),
        done: followee_count >= @discovery_follow_target,
        href:
          if(suggestions?, do: "#profile-who-to-follow", else: ~p"/listings/most_followed_users"),
        hint: follow_step_hint(followee_count)
      }
    ]
  end

  # Progress under the follow step ("You already follow 2 members."): visible
  # momentum once the count has started, nothing at zero (the label alone
  # reads cleaner) and nothing once the step is done.
  defp follow_step_hint(n) when n < 1 or n >= @discovery_follow_target, do: nil

  defp follow_step_hint(n),
    do: ngettext("You already follow one member.", "You already follow %{count} members.", n)

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

  # The candidate window (@suggested_window_days, defined at the top with its
  # siblings): only members who posted within it are suggested at all. The
  # card promises that following fills your feed, and a silent account cannot
  # keep that promise - strict on purpose, a thin (or empty) card is more
  # honest than padding it with inactive accounts.

  # The "Who to follow" rail draws from the window's most-hearted recent
  # posters (`Posts.top_recent_posters/2` - members who posted in the last
  # @suggested_window_days days, ranked by the hearts those posts collected),
  # minus everyone the rail must never suggest: the profile owner, the
  # `viewer` themselves, anyone the viewer *already follows* (suggesting them
  # is pointless) and blocked members. `viewer` is the current user (nil when
  # logged out), so a logged-out visitor gets unfiltered suggestions and no
  # follow state. This replaced a most-followed/topical-tag source: follower
  # totals reward the past, but the card's promise is a feed with something
  # in it, which only current, liked output can keep.
  #
  # `following` is the hoisted follow-state map load_profile resolved once for
  # the candidates AND the preview rows together — this filter and the rows'
  # follow buttons read the same lookup.
  defp suggestable(candidates, user, viewer, following) do
    # `viewer` is nil for a logged-out visitor; a nil id never equals a real UUID,
    # so the comparison stays a plain boolean (a bare `viewer && …` would yield nil
    # and blow up the strict `or`).
    viewer_id = viewer && viewer.id
    blocked = if viewer, do: Social.blocked_user_ids(viewer.id), else: MapSet.new()

    Enum.reject(candidates, fn u ->
      u.id == user.id or u.id == viewer_id or Map.has_key?(following, u.id) or
        MapSet.member?(blocked, u.id)
    end)
  end
end
