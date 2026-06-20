defmodule VutuvWeb.UserController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.UserResolveSlug when action in [:edit, :update, :show])
  plug(VutuvWeb.Plug.RequireLogin when action in [:delete, :confirm_delete])
  plug(VutuvWeb.Plug.AuthUser when action in [:edit, :update])
  plug(VutuvWeb.Plug.EnsureActivated when action not in [:delete, :confirm_delete])
  import VutuvWeb.UserHelpers

  import Ecto.Query

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Social.Follow
  alias Vutuv.Tags.Tag
  alias Vutuv.Tags.UserTag
  alias Vutuv.Tags.UserTagEndorsement
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.RateLimit

  plug(:scrub_params, "user" when action in [:update])

  # The profile is also served as Markdown / text / JSON / vCard (same URL
  # plus .md/.txt/.json/.vcf, or Accept negotiation) — the agent formats.
  # All four render from VutuvWeb.AgentDocs.ProfileDoc, so when show.html
  # gains or loses public data, ProfileDoc must follow (the drift test
  # agent_docs_drift_test.exs enforces it).
  def show(conn, params) do
    # The profile is the one page that also serves :vcf; the doc embeds the
    # photo only for that format, so the doc fun takes the negotiated format.
    AgentDocs.respond(conn,
      allowed: AgentDocs.formats(),
      html: &show_html(&1, params),
      doc: &ProfileDoc.build(conn.assigns[:user], include_photo: &1 == :vcf)
    )
  end

  defp show_html(conn, params) do
    # The profile also advertises the member's RSS feed next to the agent
    # formats respond/2 already put there.
    conn =
      AgentDocs.put_feed_alternate(
        conn,
        VutuvWeb.Feeds.user_feed_path(conn.assigns[:user]),
        "#{full_name(conn.assigns[:user])} · #{gettext("Posts")}"
      )

    # The totals drive the "View all" links for the sections whose preloads
    # below are cut off after a few entries.
    totals = assoc_totals(conn.assigns[:user])
    user = preload_user_for_show(conn.assigns[:user])
    current_user = conn.assigns[:current_user]
    # A strict boolean (not the nil/false `&&` would yield): the template gates
    # owner-only chrome with the strict `and`, which rejects a nil left side.
    owner? = !!(current_user && current_user.id == user.id)

    # Owner-only "view as" preview: render the profile as another viewer would
    # see it, by the relationship tiers the app already names — a Follower
    # (follows you), a connection (vernetzt) or the public (logged-out visitors
    # and search engines). Honored ONLY for the owner; the small helpers below
    # do the per-tier resolution. The reload is server-side on purpose: private
    # data must never reach a preview's HTML to be hidden client-side.
    preview_as = view_as(owner?, params)
    posts_viewer = posts_scope(preview_as, current_user)
    # The secondary chrome (post author menu, the rail's follow controls)
    # renders from the logged-out viewpoint in any preview, so no live control
    # fires as the owner. The header's controls are set explicitly below.
    view_viewer = preview_viewer(preview_as, current_user)
    private_emails? = private_emails?(preview_as, current_user, user)

    # Resolve the header's current job once (DB-backed, over all the user's
    # work experiences) and derive the work line from it, so the template
    # does not run the current_job/1 query chain itself.
    header_job = current_job(user)

    recommended_users = recommended_users(user)
    followers = Enum.map(user.inbound_follows, & &1.follower)
    followees = Enum.map(user.outbound_follows, & &1.followee)
    # One work-info and one follow-state query for all the small user lists on
    # the page (the "Who to follow" rail plus both follow previews).
    preview_users = Enum.uniq_by(recommended_users ++ followers ++ followees, & &1.id)

    posts_total = Vutuv.Posts.count_author_posts(user, posts_viewer)

    as_owner? = owner? and is_nil(preview_as)
    steps = completion_steps(user, posts_total)
    # The checklist is a brief nudge, not permanent furniture: only the owner,
    # only while a step is undone, and only inside the onboarding window. The
    # window query is the last term so it runs only when the cheap checks pass.
    show_completion? = as_owner? and Enum.any?(steps, &(not &1.done)) and onboarding_window?(user)

    conn
    |> assign(:can_preview?, owner?)
    # The profile content spans the full main column, so the layout's "View as"
    # bar goes full width here (max-w-6xl) instead of the section pages' 48rem.
    |> assign(:view_as_full_width?, true)
    |> assign(:preview_as, preview_as)
    |> assign(:preview?, not is_nil(preview_as))
    |> assign(:as_owner?, as_owner?)
    |> assign(:view_viewer, view_viewer)
    |> assign(:view_viewer_id, view_viewer && view_viewer.id)
    |> assign(:header_follow_id, header_follow_id(preview_as, current_user, user))
    |> assign(:vcard_full?, private_emails?)
    |> assign(:viewer_block, viewer_block(current_user, user))
    |> assign(:user_saved, header_user_saved(preview_as, current_user, user))
    |> assign(:emails, profile_emails(private_emails?, current_user, user))
    |> assign(:posts, Vutuv.Posts.profile_posts(user, posts_viewer))
    |> assign(:posts_total, posts_total)
    |> assign(:user_tags, user.user_tags)
    |> assign(:work_experience, user.work_experiences)
    |> assign(:follower_count, Vutuv.Social.follower_count(user))
    |> assign(:followee_count, Vutuv.Social.followee_count(user))
    |> assign(:connection_count, Vutuv.Social.connection_count(user))
    |> assign(:header_connected?, header_connected?(preview_as, current_user, user))
    |> assign(:header_follow_muted?, header_follow_muted?(preview_as, current_user, user))
    |> assign(:user, user)
    |> assign(:header_job, header_job)
    |> assign(:work_info, work_information_string_for_job(header_job, 60))
    |> assign(:completion_steps, steps)
    |> assign(:show_completion?, show_completion?)
    |> assign(:recommended_users, recommended_users)
    |> assign(:followers, followers)
    |> assign(:followees, followees)
    |> assign(:totals, totals)
    |> assign(
      :work_info_by_id,
      VutuvWeb.UserHelpers.work_information_map(preview_users, 24)
    )
    |> assign(
      :following_by_id,
      VutuvWeb.UserHelpers.following_map(view_viewer, preview_users)
    )
    |> render("show.html", conn: conn)
  end

  # ── "View as" preview helpers (owner-only) ──
  # Each resolves one slice of the previewed viewer, kept small and pattern
  # matched so show_html/2 stays a straight assign chain.

  # The preview tier (nil = the owner's own view). Honored only for the owner,
  # so a stranger's ?view_as= can never widen what they see.
  defp view_as(false, _params), do: nil

  defp view_as(true, params) do
    case params["view_as"] do
      "follower" -> :follower
      "connection" -> :connection
      "public" -> :public
      _ -> nil
    end
  end

  # The timeline scope: a simulated relationship in a preview (so the owner's
  # own connections-only post shows under "Vernetzt" but stays hidden under
  # "Follower"/"Public"), the real viewer otherwise. Public reuses anonymous.
  defp posts_scope(:follower, _current_user),
    do: {:preview, %{follower?: true, followee?: false, connection?: false}}

  defp posts_scope(:connection, _current_user),
    do: {:preview, %{follower?: true, followee?: true, connection?: true}}

  defp posts_scope(:public, _current_user), do: nil
  defp posts_scope(nil, current_user), do: current_user

  # The viewer for the secondary chrome (rail follow controls, post author
  # menu): nobody in a preview, the real viewer otherwise.
  defp preview_viewer(nil, current_user), do: current_user
  defp preview_viewer(_preview, _current_user), do: nil

  # Private emails go to the owner, anyone the owner follows, and the Vernetzt
  # preview (a connection is a mutual follow, so the rule already grants it).
  # Follower / Public previews see the public set only. Drives the vCard too.
  defp private_emails?(:connection, _current_user, _user), do: true
  defp private_emails?(preview, _current_user, _user) when not is_nil(preview), do: false
  # `user_has_permissions?/2` returns the follow id (a truthy UUID) rather than
  # a strict boolean, so coerce it: `profile_emails/3` and `:vcard_full?` both
  # expect a real `true`/`false`, and a leaked id 500s the profile page.
  defp private_emails?(nil, current_user, user),
    do: !!user_has_permissions?(user, current_user)

  defp profile_emails(true, current_user, user), do: emails_for_display(user, current_user)
  defp profile_emails(false, _current_user, user), do: emails_for_display(user, nil)

  # Whether the header shows the "✓ Vernetzt" badge: the viewer and this member
  # follow each other. Previews show the tier's state — a Follower is not
  # vernetzt, the Vernetzt preview is.
  defp header_connected?(:connection, _current_user, _user), do: true
  defp header_connected?(:follower, _current_user, _user), do: false

  defp header_connected?(_preview, current_user, user) do
    current_user != nil and current_user.id != user.id and
      Vutuv.Social.connected?(current_user.id, user.id)
  end

  # Whether the viewer has muted their follow of this member (drives the mute
  # toggle's state). Inert in a preview.
  defp header_follow_muted?(preview, _current_user, _user)
       when preview in [:follower, :connection],
       do: false

  defp header_follow_muted?(_preview, current_user, user) do
    if current_user && current_user.id != user.id do
      case Vutuv.Social.follow_edge(current_user.id, user.id) do
        %{muted?: muted?} -> muted?
        _ -> false
      end
    else
      false
    end
  end

  # Whether the header follow button reads "Following": a real follower, and
  # both relationship previews (inert there via pointer-events-none).
  defp header_follow_id(preview, _current_user, _user) when preview in [:follower, :connection],
    do: "preview"

  defp header_follow_id(_preview, current_user, user) do
    if current_user && current_user.id != user.id do
      user_follows_user?(current_user, user)
    else
      false
    end
  end

  # The footer Block/Unblock control: my own block row on this profile (nil =
  # not blocking / logged out / own profile).
  defp viewer_block(current_user, user) do
    if current_user && current_user.id != user.id do
      Vutuv.Social.get_block(current_user.id, user.id)
    end
  end

  # The header's private save toggles (like / bookmark a member). A
  # relationship preview shows the fresh state: nothing saved yet.
  defp header_user_saved(preview, _current_user, _user) when preview in [:follower, :connection],
    do: %{bookmarked?: false, liked?: false}

  defp header_user_saved(_preview, current_user, user) do
    if current_user && current_user.id != user.id do
      Vutuv.Social.user_saved_flags(current_user, user)
    end
  end

  # Only what show.html.heex (and the root layout's meta description) actually
  # renders: the first 10 tags, the latest 3 of each list-like association,
  # all social media accounts (there can be at most one per provider).
  defp preload_user_for_show(user) do
    user
    |> Repo.preload(
      social_media_accounts: SocialMediaAccount.ordered(),
      # Most endorsed first, so the 10-tag cut keeps the strongest tags. The
      # endorsement rows drive both the chip's displayed count (Enum.count) and
      # the template's "already endorsed?" check, so preload only the visible
      # endorsers: hidden accounts must not inflate the count (issue #783). The
      # viewer is logged in and visible, so their own row survives the filter.
      user_tags:
        UserTag.ordered_by_endorsements()
        |> limit(10)
        |> preload(endorsements: ^UserTagEndorsement.visible_with_endorser()),
      work_experiences:
        from(u in Vutuv.Profiles.WorkExperience, limit: 3)
        |> WorkExperience.order_by_date(),
      # The contact sections lead with the owner's chosen order (see
      # Vutuv.Ordering), so the profile preview shows the same first entries the
      # section pages do.
      phone_numbers: PhoneNumber.ordered() |> limit(3),
      urls: Url.ordered() |> limit(3),
      addresses: Address.ordered() |> limit(3),
      inbound_follows: {Follow.latest(3, :follower), [:follower]},
      outbound_follows: {Follow.latest(3, :followee), [:followee]}
    )
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

  # The new-member onboarding checklist: the few highest-impact steps that make a
  # profile findable and recognizable. Each links straight to where it is done;
  # the profile shows it to the owner only while something is still undone, and it
  # disappears once every step is done. Replaces the old 10-minute welcome note,
  # which vanished long before most people finished setting up.
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

  # When to surface the onboarding checklist at all: the first 24h of a new
  # account, plus the 24h after a long-dormant member (or a legacy account that
  # predates per-session tracking) signs back in. `or` short-circuits, so the
  # session query in fresh_return?/1 runs only for accounts past the cheap
  # account-age check.
  defp onboarding_window?(user) do
    account_fresh?(user) or Vutuv.Sessions.fresh_return?(user)
  end

  defp account_fresh?(user) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), user.inserted_at, :second) < 24 * 60 * 60
  end

  defp recommended_users(user) do
    case first_tag(user) do
      nil ->
        Vutuv.Social.most_followed_users(6)

      tag ->
        tag_users = Tag.recommended_users(tag)
        if tag_users == [user], do: Vutuv.Social.most_followed_users(6), else: tag_users
    end
    # Never suggest following the profile you are already looking at: both the
    # tag-endorsement and the most-followed queries can return the owner
    # themselves (they are usually the top-endorsed person for their own tag).
    |> Enum.reject(&(&1.id == user.id))
  end

  defp first_tag(user) do
    Repo.one(
      from(w in assoc(user, :user_tags),
        join: t in assoc(w, :tag),
        order_by: w.inserted_at,
        limit: 1,
        select: t
      )
    )
  end

  def edit(conn, _params) do
    user = conn.assigns[:user]

    changeset = User.changeset(user)

    # Own its <title> so the browser tab/history reads "Edit profile - vutuv"
    # rather than falling back to the member name (this is the Profile settings
    # tab, not the public profile).
    render(conn, "edit.html",
      user: user,
      changeset: changeset,
      page_title: gettext("Edit profile")
    )
  end

  def update(conn, %{"user" => user_params}) do
    user = conn.assigns[:user]

    # Go through Accounts.update_user/2 so the people-search index is rebuilt
    # from the changeset's final field values, not the raw params. The old local
    # helper rebuilt straight from params, so a partial submission missing a name
    # key wiped every search term (issue #780).
    case Accounts.update_user(user, user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("User updated successfully."))
        |> redirect(to: ~p"/#{user}")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render("edit.html", user: user, changeset: changeset)
    end
  end

  # Step 1: mail a PIN and render the PIN-entry form. Nothing is deleted yet.
  def delete(conn, _params) do
    user = conn.assigns[:current_user]
    email = Accounts.first_email_value(user)

    case RateLimit.check(conn, :account_deletion, email) do
      :ok ->
        user
        |> Vutuv.Accounts.gen_pin_for("delete")
        |> Emailer.user_deletion_email(email, user)
        |> Emailer.deliver()

        render(conn, "delete_confirmation.html", body_class: "stretch")

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/#{user}")
    end
  end

  # Step 2: the PIN confirms the deletion, which is then irreversible.
  def confirm_delete(conn, %{"account_deletion" => %{"pin" => pin}}) do
    user = conn.assigns[:current_user]

    case RateLimit.check(conn, :account_deletion_pin, Accounts.first_email_value(user)) do
      :ok ->
        verify_deletion_pin(conn, user, pin)

      :rate_limited ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: ~p"/#{user}")
    end
  end

  defp verify_deletion_pin(conn, user, pin) do
    case Vutuv.Accounts.check_pin(user, pin, "delete") do
      {:ok, user} ->
        # Clean, complete teardown: DB cascade for the rows, plus the on-disk
        # files (post images, avatar, cover, link-preview screenshots) the
        # cascade can't reach.
        {:ok, _} = Vutuv.Accounts.delete_user(user)

        conn
        |> Vutuv.Accounts.logout()
        |> put_flash(:info, gettext("User deleted successfully."))
        |> redirect(to: ~p"/")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> render("delete_confirmation.html", body_class: "stretch")

      {:expired, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/#{user}")

      :lockout ->
        conn
        |> put_flash(:error, gettext("Too many incorrect attempts."))
        |> redirect(to: ~p"/#{user}")
    end
  end
end
