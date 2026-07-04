defmodule VutuvWeb.SettingsController do
  @moduledoc """
  The owner's settings. `index/2` is the **hub**: the one grouped map of
  everything a member can change about themselves (the profile-content
  sections, the account areas, privacy, notifications, apps, and the delete
  exit). The account areas are focused subpages carved out of the old
  everything-on-one-scroll account hub: sign-in & security (username, emails,
  devices, passkeys), language & maps, import (LinkedIn), export (GDPR),
  and the delete-account danger page. The profile basics (photos, name, about)
  stay on `UserController.edit`.

  Routed user-agnostically under /settings (see the router's :settings_pipe):
  RequireLogin + SettingsUser assign :user = the logged-in member, so the same
  URL edits whoever opens it. The only slug-routed action left is
  `legacy_redirect`, which sends old /:slug/settings/* bookmarks here.
  """
  use VutuvWeb, :controller

  # Under /settings the pipeline (RequireLogin + SettingsUser +
  # EnsureActivated) provides :user = the logged-in member; AuthUser then
  # holds trivially and stays as a belt-and-braces guard. legacy_redirect is
  # the one slug-routed action (old /:slug/settings/* bookmarks) and redirects
  # whoever arrives to their own /settings.
  plug(VutuvWeb.Plug.AuthUser when action not in [:legacy_redirect])

  plug(
    :scrub_params,
    "user" when action in [:update_privacy, :update_notifications, :update_language, :update_maps]
  )

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.Credentials
  alias Vutuv.Sessions

  # The hub: no forms of its own, just the grouped rows with per-section entry
  # counts. Each page sets its own :page_title so the browser tab / history
  # reads "Settings - vutuv" etc. rather than falling back to the bare member
  # name (LayoutHTML.page_title/1).
  def index(conn, _params) do
    user = conn.assigns[:user]

    render(conn, "index.html",
      user: user,
      section_counts: hub_counts(user),
      page_title: gettext("Settings")
    )
  end

  # The Accounts counts are keyed by domain name (urls, phone_numbers, ...);
  # the hub rows are keyed by menu key (links, phones, ...). Translate once
  # here so the template stays a dumb list.
  defp hub_counts(user) do
    counts = Accounts.profile_section_counts(user)

    %{
      work: counts.work_experiences,
      education: counts.educations,
      links: counts.urls,
      social: counts.social_media_accounts,
      emails: counts.emails,
      phones: counts.phone_numbers,
      addresses: counts.addresses,
      tags: counts.tags
    }
  end

  # Sign-in & security: username, email addresses, signed-in devices and
  # passkeys — the credential cluster, on one focused page.
  def security(conn, _params) do
    user = conn.assigns[:user]

    render(conn, "security.html",
      user: user,
      sessions: Sessions.list_active(user),
      current_session_id: conn.assigns[:current_session_id],
      passkeys: Credentials.list_for_user(user),
      page_title: gettext("Sign-in & security")
    )
  end

  # Language & maps: the interface-language and map-preference forms, so they
  # need a changeset like the privacy/notifications pages.
  def preferences(conn, _params) do
    user = conn.assigns[:user]

    render(conn, "preferences.html",
      user: user,
      changeset: User.changeset(user),
      page_title: gettext("Language & maps")
    )
  end

  # The export page: explains the GDPR download and offers it as a button
  # (the file itself is GET /settings/export/download, ExportController).
  def export(conn, _params) do
    user = conn.assigns[:user]
    render(conn, "export.html", user: user, page_title: gettext("Export"))
  end

  # "Ihre Daten" was split into Import and Export; the drawer URL lived only
  # briefly, so its bookmarks land on the hub.
  def data_redirect(conn, _params), do: redirect(conn, to: ~p"/settings")

  # The danger page: the warning and the PIN-mailing delete control live on
  # their own page (never straight on the hub), so the destructive action is
  # easy to find but hard to trigger in passing. The actual DELETE stays
  # UserController.delete.
  def delete_account(conn, _params) do
    user = conn.assigns[:user]
    render(conn, "delete_account.html", user: user, page_title: gettext("Delete account"))
  end

  def privacy(conn, _params) do
    user = conn.assigns[:user]

    render(conn, "privacy.html",
      user: user,
      changeset: User.changeset(user),
      page_title: gettext("Privacy settings")
    )
  end

  def apps(conn, _params) do
    user = conn.assigns[:user]
    render(conn, "apps.html", user: user, page_title: gettext("Apps & API"))
  end

  def update_privacy(conn, %{"user" => params}) do
    save(
      conn,
      params,
      "privacy.html",
      ~p"/settings/privacy",
      gettext("Privacy settings saved."),
      # The member's open shells only re-read "Show when I'm online" on a full
      # reload, so push the new value to them to start/stop their dot live.
      fn saved ->
        Vutuv.Activity.broadcast(saved.id, {:presence_pref, saved.show_online_status?})
      end
    )
  end

  # Follow-only federation (Vutuv.Fediverse): the member's handle, the
  # remote-follower count and the opt-in. Enabling mints the actor keypair
  # right away, so WebFinger answers the moment the switch is on.
  def fediverse(conn, _params) do
    user = conn.assigns[:user]

    render(
      conn,
      "fediverse.html",
      fediverse_assigns(user) ++
        [user: user, changeset: User.changeset(user), page_title: gettext("Fediverse")]
    )
  end

  def update_fediverse(conn, %{"user" => params}) do
    save(
      conn,
      params,
      "fediverse.html",
      ~p"/settings/fediverse",
      gettext("Fediverse settings saved."),
      fn saved ->
        if saved.fediverse_followers?, do: Vutuv.Fediverse.ensure_actor(saved)
      end
    )
  end

  defp fediverse_assigns(user) do
    [
      follower_count: Vutuv.Fediverse.follower_count(user),
      fediverse_host: VutuvWeb.Endpoint.host()
    ]
  end

  def notifications(conn, _params) do
    user = conn.assigns[:user]

    render(conn, "notifications.html",
      user: user,
      changeset: User.changeset(user),
      page_title: gettext("Notification settings")
    )
  end

  def update_notifications(conn, %{"user" => params}) do
    save(
      conn,
      params,
      "notifications.html",
      ~p"/settings/notifications",
      gettext("Notification settings saved.")
    )
  end

  # The interface language (`locale`) is the user's own UI-language preference,
  # not public profile content, so it lives on the language & maps page rather
  # than the profile editor. It posts back to that page and rerenders it on
  # error.
  def update_language(conn, %{"user" => params}) do
    save(
      conn,
      params,
      "preferences.html",
      ~p"/settings/preferences",
      gettext("Language updated.")
    )
  end

  # Map preferences (which map services to show on addresses and which is the
  # default) are a viewing preference, not public profile content, so they sit
  # on the language & maps page. The form posts the three enable checkboxes
  # plus the default select; `Vutuv.Maps` reconciles a default that points at
  # a disabled service at render time, so no extra validation here.
  def update_maps(conn, %{"user" => params}) do
    save(
      conn,
      params,
      "preferences.html",
      ~p"/settings/preferences",
      gettext("Map preferences saved.")
    )
  end

  # ── Signed-in devices (issue #794) ──

  # Log out one device. Only the owner's own sessions are reachable
  # (Sessions.get_session/2 scopes by user), and an unknown/foreign id is a
  # quiet no-op redirect rather than an error.
  def revoke_session(conn, %{"id" => id}) do
    user = conn.assigns[:user]

    case Sessions.get_session(user, id) do
      nil -> nil
      session -> Sessions.revoke(session)
    end

    conn
    |> put_flash(:info, gettext("That device has been logged out."))
    |> redirect(to: ~p"/settings/security")
  end

  # Log out every other device, keeping the current one (so the member is not
  # logged out of the very page they clicked from).
  def revoke_other_sessions(conn, _params) do
    user = conn.assigns[:user]
    Sessions.revoke_all_except(user, conn.assigns[:current_session_id])

    conn
    |> put_flash(:info, gettext("All other devices have been logged out."))
    |> redirect(to: ~p"/settings/security")
  end

  # The old owner URLs (/:slug/settings and /:slug/settings/whatever) moved
  # to the user-agnostic /settings scope; send bookmarks and muscle memory to
  # the same subpath there. Whoever arrives lands on their OWN settings (or
  # the login flow), which is exactly what the old URL meant.
  def legacy_redirect(conn, params) do
    rest = params["rest"] || []
    redirect(conn, to: "/settings" <> subpath(rest))
  end

  defp subpath([]), do: ""
  defp subpath(rest), do: "/" <> Enum.join(rest, "/")

  # The settings sub-forms each submit only their own fields; Accounts.update_user/2
  # casts that subset and leaves the rest of the profile untouched. On success we
  # stay on the same settings page (not the public profile) so the change reads as
  # "saved, here", with the toggle reflecting the new value.
  defp save(conn, params, template, redirect_to, flash, on_success \\ fn _user -> :ok end) do
    user = conn.assigns[:user]

    case Accounts.update_user(user, params) do
      {:ok, saved} ->
        on_success.(saved)

        conn
        |> put_flash(:info, flash)
        |> redirect(to: redirect_to)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(template, error_assigns(conn, template, changeset))
    end
  end

  # Every settings form page re-renders with user + changeset; the pages that
  # need more (the security page's devices and passkeys) carry no forms —
  # except the Fediverse page, whose shell shows the follower count.
  defp error_assigns(conn, "fediverse.html", changeset) do
    [user: conn.assigns[:user], changeset: changeset] ++
      fediverse_assigns(conn.assigns[:user])
  end

  defp error_assigns(conn, _template, changeset),
    do: [user: conn.assigns[:user], changeset: changeset]
end
