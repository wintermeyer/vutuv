defmodule VutuvWeb.UserController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.UserResolveSlug when action in [:show])
  plug(VutuvWeb.Plug.RequireLogin when action in [:delete, :confirm_delete])
  plug(VutuvWeb.Plug.AuthUser when action in [:edit, :update])
  plug(VutuvWeb.Plug.EnsureActivated when action not in [:delete, :confirm_delete])
  plug(VutuvWeb.Plug.AgentExportOptOut when action in [:show])
  import VutuvWeb.UserHelpers
  import Phoenix.LiveView.Controller, only: [live_render: 3]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.Notifications.Emailer
  alias Vutuv.Profiles.SocialMediaAccount
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.ProfileDoc
  alias VutuvWeb.Fediverse.Docs
  alias VutuvWeb.FediverseController
  alias VutuvWeb.RateLimit

  plug(:scrub_params, "user" when action in [:update])

  # The profile is also served as Markdown / text / JSON / vCard (same URL
  # plus .md/.txt/.json/.vcf, or Accept negotiation) — the agent formats.
  # All four render from VutuvWeb.AgentDocs.ProfileDoc, so when show.html
  # gains or loses public data, ProfileDoc must follow (the drift test
  # agent_docs_drift_test.exs enforces it).
  def show(conn, params) do
    user = conn.assigns[:user]

    # An ActivityPub Accept on the profile URL gets the actor document (what
    # Mastodon fetches when someone pastes the profile URL into its search) —
    # or a 404 for members who don't federate, which AP clients read as
    # "nothing here" instead of choking on HTML.
    cond do
      FediverseController.ap_request?(conn) and Fediverse.federated?(user) ->
        {:ok, actor} = Fediverse.ensure_actor(user)

        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, Jason.encode!(Docs.actor(user, actor)))

      FediverseController.ap_request?(conn) ->
        send_resp(conn, 404, "")

      true ->
        # The profile is the one page that also serves :vcf; the doc embeds the
        # photo only for that format, so the doc fun takes the negotiated format.
        AgentDocs.respond(conn,
          allowed: AgentDocs.formats(),
          html: &show_html(&1, params),
          doc: &ProfileDoc.build(conn.assigns[:user], include_photo: &1 == :vcf)
        )
    end
  end

  # The human profile is a LiveView (VutuvWeb.UserProfileLive): the controller
  # stays the entry point so the agent formats above keep working, then hands
  # the HTML render to the socket so every viewer control runs without a reload
  # and the counts/tags update live. The user is already resolved + activated by
  # the plugs above; the LiveView re-loads everything from the id (the session
  # only carries serializable values). Signed-in members always see their own
  # view of a profile; there is no owner "view as public" preview — to see the
  # public view you log out.
  defp show_html(conn, _params) do
    # The profile also advertises the member's RSS feed next to the agent
    # formats respond/2 already put there.
    conn =
      AgentDocs.put_feed_alternate(
        conn,
        VutuvWeb.Feeds.user_feed_path(conn.assigns[:user]),
        "#{full_name(conn.assigns[:user])} · #{gettext("Posts")}"
      )

    user = conn.assigns[:user]

    # Drop the controller's own `:app` layout: the LiveView brings the `:app`
    # layout itself, so without this the page chrome — ShellLive included —
    # renders twice. The root layout (the document <head>) still applies.
    conn
    # rel="me" identity links in the <head> for the member's listed social
    # accounts (the visible chips already carry rel="me" too). This is what
    # Mastodon's link verification reads: a member who adds their profile URL
    # to their Mastodon profile gets it shown as verified there — Fediverse
    # identity without any federation.
    |> assign(:rel_me_urls, rel_me_urls(user))
    # Federating members advertise their actor document, so a pasted profile
    # URL resolves in Mastodon's search even from the HTML rendering.
    |> maybe_assign_actor_alternate(user)
    # The member's search/AI opt-outs as a response header, belt and braces
    # to the layout's robots meta tag (the post pages and the agent-format
    # documents already answer with it).
    |> VutuvWeb.ContentPolicy.put_robots_header(user.noindex?, user.noai?)
    |> put_layout(html: false)
    |> live_render(VutuvWeb.UserProfileLive,
      session: %{
        "profile_user_id" => user.id,
        "locale" => conn.assigns[:locale],
        "request_path" => conn.request_path,
        "user_id" => conn.assigns[:current_user_id]
      }
    )
  end

  defp maybe_assign_actor_alternate(conn, user) do
    if Fediverse.federated?(user) do
      assign(conn, :activity_json_alternate, Docs.actor_url(user))
    else
      conn
    end
  end

  # The canonical URLs of the member's listed social accounts (position
  # order), skipping handle-only providers that have no linkable URL — the
  # <head> rel="me" set the root layout renders for show_html above.
  defp rel_me_urls(user) do
    user
    |> Ecto.assoc(:social_media_accounts)
    |> SocialMediaAccount.ordered()
    |> Repo.all()
    |> Enum.map(&SocialMediaAccount.url/1)
    |> Enum.filter(&String.starts_with?(&1, "http"))
  end

  # The old /:slug/edit: the basics form moved to the user-agnostic
  # /settings/profile; send bookmarks and muscle memory there.
  def edit_redirect(conn, _params), do: redirect(conn, to: ~p"/settings/profile")

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

  def update(conn, %{"user" => user_params} = params) do
    user = conn.assigns[:user]
    user_params = clear_birthdate_if_requested(user_params, params)

    # Go through Accounts.update_user/2 so the people-search index is rebuilt
    # from the changeset's final field values, not the raw params. The old local
    # helper rebuilt straight from params, so a partial submission missing a name
    # key wiped every search term (issue #780).
    case Accounts.update_user(user, user_params) do
      {:ok, updated} ->
        conn
        |> save_flash(user, updated)
        |> redirect(to: ~p"/#{updated}")

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render("edit.html", user: user, changeset: changeset)
    end
  end

  # The native <input type="date"> on the profile editor gives no clear button
  # in some browsers (notably Safari on macOS, where it renders as mm/dd/yyyy
  # spinners), so a member who set a birthday could never remove it (issue #901).
  # The editor's "Remove date of birth" button submits `clear_birthdate`; honour
  # it by nilling the date before it reaches the changeset, since without JS the
  # date input still carries its old value alongside the clear request. (The JS
  # enhancement instead empties the field client-side, which the changeset
  # already nils from the resulting "".)
  defp clear_birthdate_if_requested(user_params, %{"clear_birthdate" => _}) do
    Map.put(user_params, "birthdate", nil)
  end

  defp clear_birthdate_if_requested(user_params, _params), do: user_params

  # Editing a name or birthday auto-revokes a prior identity verification
  # (User.changeset/2). When that happened, explain it instead of the generic
  # success toast: friendly, and spelling out the why (so verified profiles stay
  # trustworthy and nobody can rename a verified account to a fake identity). A
  # persistent error toast is used on purpose so the member can read it.
  defp save_flash(conn, %User{identity_verified?: true}, %User{identity_verified?: false}) do
    put_flash(
      conn,
      :error,
      gettext(
        "Your verified badge was removed because you changed your name, gender or date of birth. We re-check identity against those details so members can trust verified profiles and nobody can set up a fake verified account. An admin can verify you again anytime."
      )
    )
  end

  defp save_flash(conn, _before, _after) do
    put_flash(conn, :info, gettext("User updated successfully."))
  end

  # Step 1: mail a PIN and render the PIN-entry form. Nothing is deleted yet.
  # The member must first re-type their own username (the /settings/delete
  # form): a deliberate, hard-to-do-in-passing confirmation. The JS on that
  # page only disables the button until the field matches, so this server-side
  # check is the real gate (it also guards no-JS and scripted requests).
  def delete(conn, params) do
    user = conn.assigns[:current_user]

    if confirm_username_matches?(user, params) do
      mail_deletion_pin(conn, user)
    else
      conn
      |> put_flash(
        :error,
        gettext("Please type your username exactly as shown to confirm the deletion.")
      )
      |> redirect(to: ~p"/settings/delete")
    end
  end

  defp mail_deletion_pin(conn, user) do
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

  # Usernames are stored lower-cased ([a-z0-9_]); accept the member's input
  # case-insensitively and tolerate a stray leading "@" or surrounding space.
  defp confirm_username_matches?(%User{username: username}, params) do
    typed =
      params
      |> Map.get("username", "")
      |> to_string()
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    typed != "" and typed == username
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

      {:already_used, message} ->
        conn
        |> put_flash(:info, message)
        |> redirect(to: ~p"/#{user}")

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
