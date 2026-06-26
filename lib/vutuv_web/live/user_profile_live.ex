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

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Social
  alias Vutuv.Social.Follow
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
    if connected?(socket), do: Activity.subscribe(profile_user_id)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:current_user_id, current_user && current_user.id)
      |> assign(:profile_user_id, profile_user_id)
      |> assign(:view_as_param, session["view_as"])
      # The shared layout reads @locale (contact / address localization, the
      # "Other formats" ?lang= suffix) and @shell_path (the embedded ShellLive)
      # straight off the socket; the controller hands both through the session.
      |> assign(:locale, session["locale"])
      |> assign(:shell_path, session["request_path"])
      |> load_profile()

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

    # `not preview?` rejects the owner's inert preview pill (its sentinel
    # "preview" id is not a real follow); scoped to the viewer, so a request can
    # only drop the viewer's own edge.
    if me && not socket.assigns.preview? do
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

  # Mute / unmute the viewer's own follow (feed-only, silent). Scoped to the
  # header's follow id so a crafted id is ignored; keeps its flash (the effect —
  # the followee's posts leaving your feed — is not visible on the profile).
  def handle_event("toggle_mute", %{"id" => follow_id}, socket) do
    me = socket.assigns.current_user

    if me && not socket.assigns.preview? && follow_id == socket.assigns.header_follow_id do
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

  # Owner-only "View as" preview switch (the layout's switcher), live: re-run the
  # whole load with the chosen tier so posts/emails/header all reflect it
  # server-side, with no reload. `view_as/2` maps "you" (and anything unknown)
  # back to the owner's own view. Honored only for the owner (can_preview?).
  def handle_event("view_as", %{"mode" => mode}, socket) do
    if socket.assigns.can_preview? do
      {:noreply, socket |> assign(:view_as_param, mode) |> load_profile()}
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

  def handle_info(_other, socket), do: {:noreply, socket}

  # Only a logged-in non-owner may endorse, and only a tag actually shown on
  # this profile (the pill is rendered for those alone), so an arbitrary
  # user_tag id from a crafted event is ignored.
  defp can_endorse?(socket, user_tag_id) do
    me = socket.assigns.current_user

    me && me.id != socket.assigns.user.id &&
      Enum.any?(socket.assigns.user_tags, &(&1.id == user_tag_id))
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
  # work-info and follow-state maps those rows read). Reads preview_as /
  # current_user / view_viewer / recommended_users off the socket, so set those
  # before piping through here.
  defp put_social_assigns(socket, user) do
    %{preview_as: preview_as, current_user: current_user, view_viewer: view_viewer} =
      socket.assigns

    followers = Enum.map(user.inbound_follows, & &1.follower)
    followees = Enum.map(user.outbound_follows, & &1.followee)

    preview_users =
      Enum.uniq_by(socket.assigns.recommended_users ++ followers ++ followees, & &1.id)

    # The header's whole follow state derives from at most the two directional
    # follow edges (viewer→owner, owner→viewer); resolve both once here instead
    # of the six overlapping lookups the four header_* helpers used to fire.
    rel = header_relationship(preview_as, current_user, user)

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
    |> assign(:following_by_id, following_map(view_viewer, preview_users))
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

    totals = assoc_totals(base_user)
    user = preload_user_for_show(base_user)
    owner? = !!(current_user && current_user.id == user.id)

    preview_as = view_as(owner?, socket.assigns.view_as_param)
    posts_viewer = posts_scope(preview_as, current_user)
    view_viewer = preview_viewer(preview_as, current_user)
    private_emails? = private_emails?(preview_as, current_user, user)

    # preload_user_for_show already loaded the date-ordered work experiences;
    # resolve the header's current job from that list in memory (the same
    # current_job_in_memory/1 the listing pages use) instead of re-running the
    # 2-4 query current_job/1 chain against work_experiences.
    header_job = current_job_in_memory(user.work_experiences)
    recommended_users = recommended_users(user, view_viewer)

    posts_total = Vutuv.Posts.count_author_posts(user, posts_viewer)
    as_owner? = owner? and is_nil(preview_as)
    steps = completion_steps(user, posts_total)
    show_completion? = as_owner? and Enum.any?(steps, &(not &1.done)) and onboarding_window?(user)

    socket
    |> assign(:can_preview?, owner?)
    |> assign(:view_as_full_width?, true)
    |> assign(:view_as_base_path, ~p"/#{user}")
    |> assign(:preview_as, preview_as)
    |> assign(:preview?, not is_nil(preview_as))
    |> assign(:as_owner?, as_owner?)
    |> assign(:view_viewer, view_viewer)
    |> assign(:view_viewer_id, view_viewer && view_viewer.id)
    |> assign(:vcard_full?, private_emails?)
    |> assign(:viewer_block, viewer_block(current_user, user))
    |> assign(:user_saved, header_user_saved(preview_as, current_user, user))
    |> assign(:emails, profile_emails(private_emails?, current_user, user))
    |> assign(:posts, Vutuv.Posts.profile_posts(user, posts_viewer))
    |> assign(:posts_total, posts_total)
    |> assign(:user_tags, user.user_tags)
    |> assign(:work_experience, user.work_experiences)
    |> assign(:header_job, header_job)
    |> assign(:work_info, work_information_string_for_job(header_job, 60))
    |> assign(:completion_steps, steps)
    |> assign(:show_completion?, show_completion?)
    |> assign(:recommended_users, recommended_users)
    |> assign(:totals, totals)
    # Builds the social slice (counts, header pill state, follow previews); reads
    # :view_viewer / :recommended_users / :preview_as set above, so it goes last.
    |> put_social_assigns(user)
  end

  # ── "View as" preview helpers (owner-only) ──

  defp view_as(false, _param), do: nil
  defp view_as(true, "public"), do: :public
  defp view_as(true, _param), do: nil

  defp posts_scope(:public, _current_user), do: nil
  defp posts_scope(nil, current_user), do: current_user

  defp preview_viewer(nil, current_user), do: current_user
  defp preview_viewer(_preview, _current_user), do: nil

  # A private address is owner-only, so no visitor preview tier ever reveals it;
  # only the owner's own view (nil, resolved through user_has_permissions?/2,
  # which is now same_user?/2) does.
  defp private_emails?(preview, _current_user, _user) when not is_nil(preview), do: false

  defp private_emails?(nil, current_user, user),
    do: !!user_has_permissions?(user, current_user)

  # private_emails? already resolved whether the viewer may see private
  # addresses, so hand that verdict straight to the loader instead of having
  # emails_for_display/2 re-run the follow permission check.
  defp profile_emails(allowed?, _current_user, user), do: emails_for_permission(user, allowed?)

  # The viewer's header follow relationship, resolved from at most the two
  # directional follow edges — the viewer's outbound edge to the owner and the
  # owner's inbound edge back — returned as one map. Replaces four helpers that
  # re-read the same edges six times (two follow_id, the two-exists connected?,
  # and a follow_edge for the mute state). The only preview tier is Public, which
  # falls through here as the owner viewing their own profile (all-false).
  defp header_relationship(_preview, current_user, user) do
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

  defp header_user_saved(_preview, current_user, user) do
    if current_user && current_user.id != user.id do
      Social.user_saved_flags(current_user, user)
    end
  end

  defp preload_user_for_show(user) do
    user
    |> Repo.preload(
      social_media_accounts: SocialMediaAccount.ordered(),
      user_tags: user_tags_query(),
      work_experiences:
        from(u in WorkExperience, limit: 3)
        |> WorkExperience.order_by_date(),
      phone_numbers: PhoneNumber.ordered() |> limit(3),
      urls: Url.ordered() |> limit(3),
      addresses: Address.ordered() |> limit(3),
      inbound_follows: {Follow.latest(3, :follower), [:follower]},
      outbound_follows: {Follow.latest(3, :followee), [:followee]}
    )
  end

  # The visible-tag preload, shared by the initial load and the live refresh:
  # the 10 most-endorsed tags, each with only its visible endorsers (and the
  # endorser preloaded for the roster), so a hidden account can't inflate the
  # count (issue #783).
  defp user_tags_query do
    UserTag.ordered_by_endorsements()
    |> limit(10)
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
      |> union_all(^section_count(PhoneNumber, uid, "numbers"))
      |> union_all(^section_count(Url, uid, "links"))
      |> union_all(^section_count(Address, uid, "addresses"))
      |> Repo.all()
      |> Map.new(fn %{section: section, total: total} -> {section, total} end)

    %{
      user_tags: Map.get(counts, "user_tags", 0),
      jobs: Map.get(counts, "jobs", 0),
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
      %{
        label: gettext("Add a profile photo"),
        done: present?(user.avatar),
        href: ~p"/#{user}/edit"
      },
      %{label: gettext("Add a tagline"), done: present?(user.headline), href: ~p"/#{user}/edit"},
      %{label: gettext("Add a tag"), done: user.user_tags != [], href: ~p"/#{user}/tags/new"},
      %{
        label: gettext("Add work experience"),
        done: user.work_experiences != [],
        href: ~p"/#{user}/work_experiences/new"
      },
      %{label: gettext("Write your first post"), done: posts_total > 0, href: ~p"/feed"}
    ]
  end

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: true

  defp onboarding_window?(user) do
    account_fresh?(user) or Vutuv.Sessions.fresh_return?(user)
  end

  defp account_fresh?(user) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), user.inserted_at, :second) < 24 * 60 * 60
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
  # the rail still fills with fresh faces. `viewer` is the effective viewer
  # (`view_viewer`, nil when logged out or previewing as the public), so a
  # logged-out visitor gets unfiltered suggestions and no follow state.
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
