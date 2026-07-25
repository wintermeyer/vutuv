defmodule VutuvWeb.AccountEventText do
  @moduledoc """
  How an account-activity event reads (issue #1087). The **one** place the log's
  wording lives, so the member's page (`/settings/activity`), the admin's page
  (`/admin/activity`) and the short recap on `/settings/security` can never tell
  the same event three different ways.

  Three pieces per row:

    * `label/1` — what happened, as a short heading ("Username changed"). Also
      the kind filter's option text on both pages.
    * `detail/1` — the specific of it ("@old to @new", "an***@example.com",
      the field names that were touched), or `nil` when the label says it all.
    * `factor_label/1` — how it was confirmed ("with a passkey").

  Everything it renders comes out of the event row, and what may be in that row
  is `Vutuv.AccountEvents`' business — so nothing here can leak a value the
  context decided not to keep.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.AccountEvents.AccountEvent

  @doc "What happened, as a short heading. Also the kind filter's option text."
  def event_label(%AccountEvent{kind: kind}), do: event_label(kind)

  def event_label("signed_in"), do: gettext("Signed in")
  def event_label("signed_out"), do: gettext("Signed out")
  def event_label("session_revoked"), do: gettext("Device signed out")
  def event_label("other_sessions_revoked"), do: gettext("All other devices signed out")
  def event_label("passkey_added"), do: gettext("Passkey added")
  def event_label("passkey_removed"), do: gettext("Passkey removed")
  def event_label("totp_enabled"), do: gettext("Authenticator app set up")
  def event_label("totp_disabled"), do: gettext("Authenticator app turned off")
  def event_label("login_codes_generated"), do: gettext("One-time code list created")
  def event_label("login_codes_deleted"), do: gettext("One-time code list deleted")
  def event_label("username_changed"), do: gettext("Username changed")
  def event_label("email_added"), do: gettext("Email address added")
  def event_label("email_removed"), do: gettext("Email address removed")
  def event_label("email_updated"), do: gettext("Email address changed")
  def event_label("profile_updated"), do: gettext("Profile changed")
  def event_label("privacy_changed"), do: gettext("Visibility settings changed")
  def event_label("notifications_changed"), do: gettext("Notification settings changed")
  def event_label("fediverse_changed"), do: gettext("Fediverse settings changed")
  def event_label("member_blocked"), do: gettext("Member blocked")
  def event_label("member_unblocked"), do: gettext("Member unblocked")
  def event_label("filter_added"), do: gettext("Filter added")
  def event_label("filter_removed"), do: gettext("Filter removed")
  def event_label("data_exported"), do: gettext("Data downloaded")
  def event_label("import_applied"), do: gettext("Import applied")
  def event_label("api_token_created"), do: gettext("Access token created")
  def event_label("api_token_revoked"), do: gettext("Access token revoked")
  def event_label("app_disconnected"), do: gettext("App disconnected")
  def event_label("account_frozen"), do: gettext("Account frozen")
  def event_label("account_unfrozen"), do: gettext("Account unfrozen")
  def event_label("account_restored"), do: gettext("Account restored")
  def event_label("identity_verified"), do: gettext("Identity verified")
  def event_label("preferences_overridden"), do: gettext("Settings changed by support")
  def event_label("activity_log_viewed"), do: gettext("Activity log opened")
  def event_label(other), do: other

  @doc """
  The specific of an event — what changed to what — or `nil` when the label
  already says everything. Reads straight out of the whitelisted `details` map.
  """
  def detail(%AccountEvent{kind: kind, details: details}), do: detail(kind, details || %{})

  defp detail("username_changed", %{"from" => from, "to" => to}) do
    gettext("@%{from} to @%{to}", from: from, to: to)
  end

  defp detail(kind, %{"email" => email}) when kind in ~w(email_added email_removed),
    do: email

  defp detail("email_updated", %{"email" => email} = details) do
    case details["public"] do
      true -> gettext("%{email}, now shown on your profile", email: email)
      false -> gettext("%{email}, now hidden from your profile", email: email)
      _unchanged -> email
    end
  end

  defp detail("session_revoked", %{"target_device" => device}) when is_binary(device), do: device

  defp detail("other_sessions_revoked", %{"count" => count}) when is_integer(count) do
    ngettext("%{count} device", "%{count} devices", count)
  end

  defp detail("login_codes_generated", %{"count" => count}) when is_integer(count) do
    ngettext("%{count} code", "%{count} codes", count)
  end

  defp detail(kind, %{"nickname" => nickname})
       when kind in ~w(passkey_added passkey_removed) and is_binary(nickname),
       do: nickname

  defp detail(kind, %{"handle" => handle}) when kind in ~w(member_blocked member_unblocked),
    do: "@" <> handle

  defp detail("filter_added", %{"filter_kind" => "tag"}), do: gettext("a tag")
  defp detail("filter_added", %{"filter_kind" => _word}), do: gettext("a word or phrase")

  defp detail("import_applied", %{"source" => "linkedin"}), do: "LinkedIn"

  defp detail(kind, %{"name" => name})
       when kind in ~w(api_token_created api_token_revoked) and is_binary(name),
       do: name

  defp detail("app_disconnected", %{"app" => app}) when is_binary(app), do: app

  defp detail("activity_log_viewed", %{"member" => member}) when is_binary(member),
    do: "@" <> member

  defp detail("fediverse_changed", %{"enabled" => true}),
    do: gettext("taking part in the Fediverse")

  defp detail("fediverse_changed", %{"enabled" => false}),
    do: gettext("not taking part in the Fediverse")

  defp detail(_kind, %{"fields" => fields}) when is_list(fields) and fields != [] do
    Enum.map_join(fields, ", ", &field_label/1)
  end

  defp detail(_kind, _details), do: nil

  @doc """
  How the change was confirmed, as a phrase to hang off the row. `nil` for a
  change that needed no extra proof — most of them, since a live session is
  already a proof.
  """
  def factor_label(%AccountEvent{factor: factor}), do: factor_label(factor)

  def factor_label("passkey"), do: gettext("with a passkey")
  def factor_label("authenticator"), do: gettext("with your authenticator app")
  def factor_label("list_code"), do: gettext("with a one-time list code")
  def factor_label("pin"), do: gettext("with an emailed PIN")
  def factor_label("session"), do: gettext("from a signed-in session")
  def factor_label("admin"), do: gettext("by the site operators")
  def factor_label(_none), do: nil

  @doc """
  A member-readable name for one settings field, so a save reads as "Search
  engines, Online status" rather than as a list of column names. Falls back to
  a humanized version of the raw name, which is why a new field needs no change
  here to render sensibly.
  """
  def field_label("first_name"), do: gettext("First name")
  def field_label("last_name"), do: gettext("Last name")
  def field_label("headline"), do: gettext("Tagline")
  def field_label("birthdate"), do: gettext("Date of birth")
  def field_label("gender"), do: gettext("Gender")
  def field_label("avatar"), do: gettext("Photo")
  def field_label("cover_photo"), do: gettext("Cover picture")
  def field_label("locale"), do: gettext("Interface language")
  def field_label("employment_status"), do: gettext("Job search")
  def field_label("noindex?"), do: gettext("Search engines")
  def field_label("noai?"), do: gettext("AI agents")
  def field_label("show_online_status?"), do: gettext("Online status")
  def field_label("show_mastodon_feed?"), do: gettext("Mastodon posts")
  def field_label("show_code_stats?"), do: gettext("Code statistics")
  def field_label("notification_emails?"), do: gettext("Notification emails")
  def field_label("newsletter_emails?"), do: gettext("Newsletter")
  def field_label("email_on_follower?"), do: gettext("New follower emails")
  def field_label("email_on_endorsement?"), do: gettext("Endorsement emails")
  def field_label("dm_email_each_message?"), do: gettext("Unread message emails")
  def field_label("dm_email_delay_minutes"), do: gettext("Unread message delay")
  def field_label("saved_search_emails?"), do: gettext("Saved search alerts")
  def field_label("cv_update_notifications?"), do: gettext("CV update notifications")
  def field_label("thread_notifications?"), do: gettext("Thread notifications")
  def field_label("fediverse_followers?"), do: gettext("Fediverse participation")
  def field_label("fediverse_reactions?"), do: gettext("Fediverse reaction counts")
  def field_label("fediverse_replies?"), do: gettext("Fediverse replies")
  def field_label("also_known_as_input"), do: gettext("Fediverse aliases")

  def field_label(raw) when is_binary(raw) do
    raw
    |> String.trim_trailing("?")
    |> String.replace("_", " ")
    |> :string.titlecase()
    |> to_string()
  end

  def field_label(raw), do: to_string(raw)

  @doc """
  Whether this event was somebody else's doing. The whole point of the log, so
  it gets its own predicate rather than an inline `is_nil` at three call sites.
  """
  def by_someone_else?(%AccountEvent{actor_user_id: nil}), do: false
  def by_someone_else?(%AccountEvent{user_id: id, actor_user_id: id}), do: false
  def by_someone_else?(%AccountEvent{}), do: true
end
