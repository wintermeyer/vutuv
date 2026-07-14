defmodule VutuvWeb.SettingsController do
  @moduledoc """
  The owner's settings. `index/2` is the **hub**: the one grouped map of
  everything a member can change about themselves (the profile-content
  sections, the account areas, privacy, notifications, apps, and the delete
  exit). The account areas are focused subpages carved out of the old
  everything-on-one-scroll account hub: sign-in & security (username, emails,
  devices, passkeys), language & display, import (LinkedIn), export (GDPR),
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
  alias Vutuv.LoginCodes
  alias Vutuv.Organizations
  alias Vutuv.Prefs
  alias Vutuv.SavedSearches
  alias Vutuv.SavedSearches.SavedSearch
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
      qualifications: counts.qualifications,
      languages: counts.languages,
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
    login_codes = LoginCodes.list_codes(user)

    render(conn, "security.html",
      user: user,
      sessions: Sessions.list_active(user),
      current_session_id: conn.assigns[:current_session_id],
      passkeys: Credentials.list_for_user(user),
      totp_enabled?: LoginCodes.totp_enabled?(user),
      list_codes_total: length(login_codes),
      list_codes_unused: Enum.count(login_codes, &is_nil(&1.used_at)),
      page_title: gettext("Sign-in & security")
    )
  end

  # Language & display: the interface-language, map-preference and post-display
  # forms, so they need a changeset like the privacy/notifications pages. The
  # changeset is built over the member's *effective* preferences
  # (Vutuv.Prefs.with_effective/1): an inherited (nil) field renders the
  # installation default it actually resolves to, so the form always shows
  # what applies. Saving stores the submitted values as the member's own;
  # the reset links below each card go back to inheriting.
  def preferences(conn, _params) do
    user = conn.assigns[:user]

    render(conn, "preferences.html",
      user: user,
      changeset: User.changeset(Prefs.with_effective(user)),
      page_title: gettext("Language & display")
    )
  end

  # The export area lives under the profile now (/:slug/export, where issue
  # #841 put the formatted CV beside the GDPR download); send the settings-era
  # URLs there — the download URL straight to the file.
  def export_redirect(conn, _params),
    do: redirect(conn, to: ~p"/#{conn.assigns[:user]}/export")

  def export_download_redirect(conn, _params),
    do: redirect(conn, to: ~p"/#{conn.assigns[:user]}/export/download")

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

  # "Your organizations": the organization pages the member owns or helps run
  # (each a {organization, role} pair, pending ones included), plus the explainer
  # and the add call to action. Read-only here — creating, editing, inviting and
  # transferring happen on the organization's own pages.
  def organizations(conn, _params) do
    user = conn.assigns[:user]

    render(conn, "organizations.html",
      user: user,
      organizations: Organizations.member_organizations(user),
      page_title: gettext("Organizations")
    )
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
      followers: Vutuv.Fediverse.list_followers(user),
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

  # --- Saved searches (issue #935) -----------------------------------------

  @saved_searches_per_page 20

  def saved_searches(conn, params) do
    user = conn.assigns[:user]
    offset = params_offset(params)
    page = SavedSearches.list_for_user(user, limit: @saved_searches_per_page, offset: offset)

    render(conn, "saved_searches.html",
      user: user,
      page: page,
      offset: offset,
      per_page: @saved_searches_per_page,
      page_title: gettext("Saved searches")
    )
  end

  def update_saved_search(conn, %{"id" => id, "saved_search" => %{"notify" => notify}}) do
    user = conn.assigns[:user]

    with %SavedSearch{} = search <- SavedSearches.get_for_user(user, id),
         {:ok, _} <- SavedSearches.update_notify(search, %{notify: notify}) do
      conn
      |> put_flash(:info, gettext("Alert updated."))
      |> redirect(to: ~p"/settings/saved_searches")
    else
      _ ->
        conn
        |> put_flash(:error, gettext("That did not work."))
        |> redirect(to: ~p"/settings/saved_searches")
    end
  end

  def delete_saved_search(conn, %{"id" => id}) do
    user = conn.assigns[:user]

    case SavedSearches.get_for_user(user, id) do
      %SavedSearch{} = search ->
        SavedSearches.delete(search)

        conn
        |> put_flash(:info, gettext("Saved search deleted."))
        |> redirect(to: ~p"/settings/saved_searches")

      _ ->
        conn
        |> put_flash(:error, gettext("That did not work."))
        |> redirect(to: ~p"/settings/saved_searches")
    end
  end

  defp params_offset(%{"offset" => raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _} when n > 0 -> n
      _ -> 0
    end
  end

  defp params_offset(_params), do: 0

  # The interface language (`locale`) is the user's own UI-language preference,
  # not public profile content, so it lives on the language & display page rather
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
  # on the language & display page. The form posts the three enable checkboxes
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

  # Post-display preferences (how many lines a post is clamped to and whether the
  # body hyphenates, desktop and mobile independently). A reading preference like
  # the maps, so it lives on the same language & display page and posts back to it.
  def update_post_display(conn, %{"user" => params}) do
    save(
      conn,
      normalize_post_lines(params),
      "preferences.html",
      ~p"/settings/preferences",
      gettext("Post display settings saved.")
    )
  end

  # A blank line field means "no truncation" (0). Ecto's cast reads "" as "no
  # value given" and would keep the previous count, so map a blank to "0" — the
  # other way a reader expresses no-truncation — before the changeset sees it.
  # (Going back to the installation default is the explicit reset link, not a
  # blank field.)
  defp normalize_post_lines(params) do
    Enum.reduce(~w(post_lines_desktop post_lines_mobile), params, fn field, acc ->
      if Map.get(acc, field) == "", do: Map.put(acc, field, "0"), else: acc
    end)
  end

  # The per-group reset links: clear every pref of the group back to nil =
  # "inherit the installation default" (Vutuv.Prefs), current and future.
  def reset_post_display(conn, _params) do
    reset_prefs(conn, :post_display, gettext("Post display settings reset to the site defaults."))
  end

  def reset_maps(conn, _params) do
    reset_prefs(conn, :maps, gettext("Map preferences reset to the site defaults."))
  end

  defp reset_prefs(conn, group, flash) do
    {:ok, _user} = Prefs.reset_group(conn.assigns[:user], group)

    conn
    |> put_flash(:info, flash)
    |> redirect(to: ~p"/settings/preferences")
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
