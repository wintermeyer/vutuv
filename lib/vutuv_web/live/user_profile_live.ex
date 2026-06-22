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

    socket
    |> assign(:user, user)
    |> assign(:follower_count, Social.follower_count(user))
    |> assign(:followee_count, Social.followee_count(user))
    |> assign(:connection_count, Social.connection_count(user))
    |> assign(:header_follow_id, header_follow_id(preview_as, current_user, user))
    |> assign(:header_follows_viewer?, header_follows_viewer?(preview_as, current_user, user))
    |> assign(:header_connected?, header_connected?(preview_as, current_user, user))
    |> assign(:header_follow_muted?, header_follow_muted?(preview_as, current_user, user))
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

    header_job = current_job(user)
    recommended_users = recommended_users(user)

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
  defp view_as(true, "follower"), do: :follower
  defp view_as(true, "connection"), do: :connection
  defp view_as(true, "public"), do: :public
  defp view_as(true, _param), do: nil

  defp posts_scope(:follower, _current_user),
    do: {:preview, %{follower?: true, followee?: false, connection?: false}}

  defp posts_scope(:connection, _current_user),
    do: {:preview, %{follower?: true, followee?: true, connection?: true}}

  defp posts_scope(:public, _current_user), do: nil
  defp posts_scope(nil, current_user), do: current_user

  defp preview_viewer(nil, current_user), do: current_user
  defp preview_viewer(_preview, _current_user), do: nil

  defp private_emails?(:connection, _current_user, _user), do: true
  defp private_emails?(preview, _current_user, _user) when not is_nil(preview), do: false

  defp private_emails?(nil, current_user, user),
    do: !!user_has_permissions?(user, current_user)

  defp profile_emails(true, current_user, user), do: emails_for_display(user, current_user)
  defp profile_emails(false, _current_user, user), do: emails_for_display(user, nil)

  defp header_connected?(:connection, _current_user, _user), do: true
  defp header_connected?(:follower, _current_user, _user), do: false

  defp header_connected?(_preview, current_user, user) do
    current_user != nil and current_user.id != user.id and
      Social.connected?(current_user.id, user.id)
  end

  defp header_follows_viewer?(:connection, _current_user, _user), do: true
  defp header_follows_viewer?(:follower, _current_user, _user), do: false

  defp header_follows_viewer?(_preview, current_user, user) do
    current_user != nil and current_user.id != user.id and
      is_binary(user_follows_user?(user, current_user))
  end

  defp header_follow_muted?(preview, _current_user, _user)
       when preview in [:follower, :connection],
       do: false

  defp header_follow_muted?(_preview, current_user, user) do
    if current_user && current_user.id != user.id do
      case Social.follow_edge(current_user.id, user.id) do
        %{muted?: muted?} -> muted?
        _ -> false
      end
    else
      false
    end
  end

  defp header_follow_id(preview, _current_user, _user) when preview in [:follower, :connection],
    do: "preview"

  defp header_follow_id(_preview, current_user, user) do
    if current_user && current_user.id != user.id do
      user_follows_user?(current_user, user)
    else
      false
    end
  end

  defp viewer_block(current_user, user) do
    if current_user && current_user.id != user.id do
      Social.get_block(current_user.id, user.id)
    end
  end

  defp header_user_saved(preview, _current_user, _user) when preview in [:follower, :connection],
    do: %{bookmarked?: false, liked?: false}

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

  defp assoc_totals(user) do
    %{
      user_tags: count_assoc(user, :user_tags),
      jobs: count_assoc(user, :work_experiences),
      numbers: count_assoc(user, :phone_numbers),
      links: count_assoc(user, :urls),
      addresses: count_assoc(user, :addresses)
    }
  end

  defp count_assoc(user, assoc), do: Repo.aggregate(Ecto.assoc(user, assoc), :count)

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

  defp recommended_users(user) do
    case first_tag(user) do
      nil ->
        Social.most_followed_users(6)

      tag ->
        tag_users = Tag.recommended_users(tag)
        if tag_users == [user], do: Social.most_followed_users(6), else: tag_users
    end
    |> Enum.reject(&(&1.id == user.id))
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
