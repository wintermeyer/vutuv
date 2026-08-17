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

  use Phoenix.Component
  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.AccountEvents.AccountEvent
  alias Vutuv.Prefs
  alias VutuvWeb.UI

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
  def event_label("preferences_changed"), do: gettext("Language & display settings changed")
  def event_label("fediverse_changed"), do: gettext("Fediverse settings changed")
  def event_label("member_blocked"), do: gettext("Member blocked")
  def event_label("member_unblocked"), do: gettext("Member unblocked")
  def event_label("filter_added"), do: gettext("Filter added")
  def event_label("filter_removed"), do: gettext("Filter removed")

  def event_label("auto_post_deletion_changed"),
    do: gettext("Automatic post deletion changed")

  def event_label("posts_auto_deleted"), do: gettext("Posts deleted automatically")

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
  def event_label("job_reference_added"), do: gettext("Employment reference added")
  def event_label("job_reference_updated"), do: gettext("Employment reference changed")
  def event_label("job_reference_removed"), do: gettext("Employment reference deleted")

  def event_label("job_reference_reviewed"),
    do: gettext("Employment reference reviewed by the AI")

  def event_label("activity_log_viewed"), do: gettext("Activity log opened")

  # Issue #1335. Deliberately worded as speaking rather than as switching: what
  # the reader needs to recognise months later is that anything published in
  # that window carried the organization's name, not their own.
  def event_label("acted_as_organization"), do: gettext("Started writing as an organization")

  def event_label("stopped_acting_as_organization"),
    do: gettext("Stopped writing as an organization")

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

  # Which model read it. The transparency box on the references page names the
  # model this installation runs *today*; this says which one actually read
  # yours, months later and after an upgrade.
  defp detail("job_reference_reviewed", %{"model" => model}) when is_binary(model), do: model

  defp detail("activity_log_viewed", %{"member" => member}) when is_binary(member),
    do: "@" <> member

  defp detail(kind, %{"organization" => name})
       when kind in ~w(acted_as_organization stopped_acting_as_organization) and
              is_binary(name),
       do: name

  # How many posts that day's pass took (issue #1255). The count is the whole
  # detail the log keeps — which posts they were is what is gone.
  defp detail("posts_auto_deleted", %{"count" => count}) when is_integer(count) do
    ngettext("%{count} post", "%{formatted} posts", count, formatted: UI.delimited_count(count))
  end

  # The fediverse save is the one that says both things: which switches it
  # carried, and where the take-part switch stands afterwards — the setting
  # whose consequences nobody can take back, and the reason a row reading only
  # "Fediverse participation" would leave the member guessing which way it went.
  defp detail("fediverse_changed", %{"enabled" => enabled} = details)
       when is_boolean(enabled) do
    case field_list(details) do
      nil -> participation_label(enabled)
      fields -> fields <> " · " <> participation_label(enabled)
    end
  end

  defp detail(_kind, details), do: field_list(details)

  defp field_list(%{"fields" => fields}) when is_list(fields) and fields != [],
    do: Enum.map_join(fields, ", ", &field_label/1)

  defp field_list(_details), do: nil

  defp participation_label(true), do: gettext("taking part in the Fediverse")
  defp participation_label(false), do: gettext("not taking part in the Fediverse")

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
  def field_label("name_pronunciation"), do: gettext("Name pronunciation")
  def field_label("birthdate"), do: gettext("Date of birth")
  def field_label("salutation"), do: gettext("Salutation")
  # Kept for events recorded before the gender field became a salutation
  # preference: the activity log is append-only, so its old rows still name
  # the old field and must keep rendering as something a member can read.
  def field_label("gender"), do: gettext("Gender")
  def field_label("avatar"), do: gettext("Photo")
  def field_label("cover_photo"), do: gettext("Cover picture")
  def field_label("locale"), do: gettext("Interface language")
  # The employment-reference fields. "public?" is the one that matters: it is
  # the field whose change cannot be taken back.
  def field_label("employer"), do: gettext("Employer")
  def field_label("issued_on"), do: gettext("Issue date")
  def field_label("body"), do: gettext("Text")
  def field_label("document"), do: gettext("File")
  def field_label("public?"), do: gettext("Visibility")
  def field_label("employment_status"), do: gettext("Job search")
  def field_label("noindex?"), do: gettext("Search engines")
  def field_label("noai?"), do: gettext("AI agents")
  def field_label("show_online_status?"), do: gettext("Online status")
  def field_label("show_mastodon_feed?"), do: gettext("Mastodon posts")
  def field_label("mastodon_clients?"), do: gettext("Mastodon-compatible apps")
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
  def field_label("fediverse_reactions?"), do: gettext("Fediverse reactions")
  def field_label("fediverse_replies?"), do: gettext("Fediverse replies")
  def field_label("also_known_as_input"), do: gettext("Fediverse aliases")

  # Automatic post deletion (issue #1255). Named one by one rather than left to
  # the humanizing fallback below, which would render the longest of them as
  # "Auto post deletion keep bookmarked".
  def field_label("auto_post_deletion?"), do: gettext("Automatic post deletion")
  def field_label("auto_post_deletion_after_days"), do: gettext("Post age")
  def field_label("auto_post_deletion_keep_photos?"), do: gettext("Keep photo posts")
  def field_label("auto_post_deletion_keep_answered?"), do: gettext("Keep answered posts")
  def field_label("auto_post_deletion_keep_bookmarked?"), do: gettext("Keep bookmarked posts")
  def field_label("auto_post_deletion_delete_replies?"), do: gettext("Delete replies too")
  def field_label("auto_post_deletion_min_likes"), do: gettext("Like floor")
  def field_label("auto_post_deletion_min_bookmarks"), do: gettext("Bookmark floor")
  def field_label("auto_post_deletion_min_reposts"), do: gettext("Repost floor")

  # A `Vutuv.Prefs` knob is named by the registry that also labels it on the
  # settings form, so the log and the form cannot word the same switch
  # differently — and a new pref needs no clause here. A key the registry no
  # longer knows falls through to the humanizer below, which is what keeps the
  # append-only log's old rows readable after a pref is retired.
  def field_label(raw) when is_binary(raw) do
    case Prefs.key(raw) do
      nil -> humanize_field(raw)
      key -> Prefs.label(key)
    end
  end

  def field_label(raw), do: to_string(raw)

  defp humanize_field(raw) do
    raw
    |> String.trim_trailing("?")
    |> String.replace("_", " ")
    |> :string.titlecase()
    |> to_string()
  end

  @doc """
  Whether this event was somebody else's doing. The whole point of the log, so
  it gets its own predicate rather than an inline `is_nil` at three call sites.
  """
  def by_someone_else?(%AccountEvent{actor_user_id: nil}), do: false
  def by_someone_else?(%AccountEvent{user_id: id, actor_user_id: id}), do: false
  def by_someone_else?(%AccountEvent{}), do: true

  attr(:class, :any, default: "mt-1")
  slot(:inner_block, required: true)

  @doc """
  The amber marker on a row somebody else caused — the one line on those pages
  that has to shout.

  The wording differs by page (the member is told it was not them, the admin is
  told who it was), which is the slot; everything else is the same badge, and
  keeping it in one place is what puts `data-event-by-other` on all three. The
  `/settings/security` copy was written without that attribute, so the test
  asserting the marker exists never covered that page at all.

  Guard the call site with `:if={by_someone_else?(event)}` as before.
  """
  def by_other_badge(assigns) do
    ~H"""
    <span
      data-event-by-other
      class={[
        "inline-flex items-center rounded-full bg-amber-50 px-2 py-0.5 text-xs font-semibold text-amber-800 dark:bg-amber-900/30 dark:text-amber-200",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end
end
