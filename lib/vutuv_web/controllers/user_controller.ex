defmodule VutuvWeb.UserController do
  use VutuvWeb, :controller
  plug(VutuvWeb.Plug.UserResolveSlug when action in [:edit, :update, :show])
  plug(VutuvWeb.Plug.RequireLogin when action in [:delete, :confirm_delete])
  plug(VutuvWeb.Plug.AuthUser when action in [:edit, :update])
  plug(VutuvWeb.Plug.EnsureActivated when action not in [:delete, :confirm_delete])
  import VutuvWeb.UserHelpers
  import Phoenix.LiveView.Controller, only: [live_render: 3]

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Notifications.Emailer
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

  # The human profile is a LiveView (VutuvWeb.UserProfileLive): the controller
  # stays the entry point so the agent formats above keep working, then hands
  # the HTML render to the socket so every viewer control runs without a reload
  # and the counts/tags update live. The user is already resolved + activated by
  # the plugs above; the LiveView re-loads everything from the id (the session
  # only carries serializable values). `?view_as=` stays a full reload (owner
  # preview), so the controller reads it here and threads it through.
  defp show_html(conn, params) do
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
    # layout itself (with the socket assigns the "View as" switcher reads), so
    # without this the page chrome — ShellLive included — renders twice. The
    # root layout (the document <head>) still applies.
    conn
    |> put_layout(html: false)
    |> live_render(VutuvWeb.UserProfileLive,
      session: %{
        "profile_user_id" => user.id,
        "view_as" => params["view_as"],
        "locale" => conn.assigns[:locale],
        "request_path" => conn.request_path,
        "user_id" => conn.assigns[:current_user_id]
      }
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
