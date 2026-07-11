defmodule Vutuv.Accounts.User do
  @moduledoc false

  use VutuvWeb, :model
  alias Vutuv.Handles
  alias Vutuv.Prefs
  @derive {Phoenix.Param, key: :username}

  schema "users" do
    field(:first_name, :string)
    field(:last_name, :string)
    field(:middle_name, :string)
    field(:nickname, :string)
    field(:honorific_prefix, :string)
    field(:honorific_suffix, :string)
    field(:gender, :string)
    # The member's job-availability signal (issue #870), shown as a badge next
    # to the tagline on the profile. nil = not specified (the default, no
    # badge); "open" = employed but open to offers; "looking" = actively
    # looking for a new role. `cast/3` folds the form's blank "not open to
    # work" choice back to nil (its default empty_values), and the changeset's
    # validate_inclusion pins it to the set.
    field(:employment_status, :string)
    # Who may see the employment-status badge (issue #928): "everyone" (all
    # visitors, incl. logged-out + crawlers/agent formats), "members" (only a
    # signed-in member — the safe default) or "hidden" (nobody; the status
    # stays stored but shows to no one). Resolved for a given viewer through
    # employment_status_visible?/2, the single seam the profile pill and the
    # agent docs both read. NOT NULL with a "members" default in the DB.
    field(:employment_status_visibility, :string, default: "members")
    # The member's minimum salary expectation / Gehaltsvorstellung (issue #928):
    # a whole-currency-unit integer (nil = not stated — the codebase models
    # money as integers, never :decimal, and the display uses the integer-only
    # delimited_count/1). Its real job is matching, not display — even at
    # "hidden" it will feed the member's own job-board filter and alerts
    # (milestone issues 6/9, 8/9); desired_salary_visibility (default "hidden")
    # only governs who else sees it, resolved per viewer by
    # desired_salary_visible?/2. There is deliberately no current/past-salary
    # field (the EU pay-transparency directive bans that employer question).
    field(:desired_salary_min, :integer)
    field(:desired_salary_currency, :string, default: "EUR")
    field(:desired_salary_period, :string, default: "year")
    field(:desired_salary_visibility, :string, default: "hidden")
    field(:birthdate, :date)
    field(:locale, :string)
    # An admin checked this person's physical ID against their name: this IS that
    # person. Admin-only (deliberately NOT in @optional_fields); drives the
    # "Verified profile" badge and the admin review queue. Not to be confused
    # with email_confirmed? below.
    field(:identity_verified?, :boolean, default: false)
    field(:avatar, :string)
    field(:cover_photo, :string)
    # Content fingerprint (sha256(original)[0..11]) of the current avatar/cover,
    # baked into the served filename `<username>-<version>-<fingerprint>.avif`
    # (Vutuv.Uploads). nil = not yet migrated to the fingerprinted scheme: the URL
    # builder then emits the legacy `?v=` URL, so a nil here serves exactly as
    # before. Set programmatically on store/regenerate, never cast from params.
    # The crop string (below) is folded into this hash, so re-cropping the same
    # original yields a fresh fingerprint and therefore a fresh, cache-safe URL.
    field(:avatar_fingerprint, :string)
    field(:cover_fingerprint, :string)
    # The user-chosen crop rectangle for each image, "x,y,w,h" fractions (0..1)
    # of the EXIF-rotated original; nil = no crop (centered, the pre-crop-UI
    # behavior). Set programmatically alongside the file post-commit
    # (Accounts.store_pending_image/6), never cast from params — like :avatar /
    # :cover_photo themselves. Persisted so Vutuv.Uploads.Regenerator can
    # re-apply the crop when it re-derives served versions from the original.
    field(:avatar_crop, :string)
    field(:cover_crop, :string)
    field(:username, :string)
    # The member's original legacy handle (the dotted / over-length import),
    # preserved before Accounts.normalize_legacy_usernames/0 rewrote :username
    # to a valid one - kept so the old handle is never lost. It also drives the
    # old-URL redirect: VutuvWeb.Plug.UserResolveSlug resolves an unknown slug
    # through here. nil for accounts that were already valid. Set once by the
    # backfill, never cast from params.
    field(:legacy_username, :string)
    field(:admin?, :boolean)
    field(:headline, :string)
    field(:noindex?, :boolean, default: false)
    # The AI counterpart to noindex?: true = AI agents and LLMs may not use
    # this member's content. Independent axes (VutuvWeb.ContentPolicy). The
    # DB default is true while this struct default is false — deliberate,
    # see the add_noai_to_users migration.
    field(:noai?, :boolean, default: false)
    # Non-essential notification mail (the unread-message nudge). Off via the
    # notifications settings form or the tokenized unsubscribe link in every
    # such email (RFC 8058 one-click); transactional mail (PINs, moderation)
    # ignores it. This is the "unread messages" switch in the granular set below.
    field(:notification_emails?, :boolean, default: true)
    # How the unread-message nudge behaves when it is on. Defaults reproduce the
    # historical behaviour: one email per unread burst (each_message? false),
    # sent once the message has sat unread for 15 minutes (the debounce delay).
    # `dm_email_each_message?` true switches to an email per unread message;
    # `dm_email_delay_minutes` is how long Vutuv.Chat waits before mailing (a
    # grace period so an online member can read it first). See the notifications
    # settings page.
    field(:dm_email_each_message?, :boolean, default: false)
    field(:dm_email_delay_minutes, :integer, default: 15)
    # The opt-in granular notification mails (set on the notifications settings
    # page, each with its own one-click unsubscribe). Default false so enabling
    # the feature never mass-mails existing members. The events themselves are
    # always pushed in-app regardless; these only gate the email copy.
    field(:email_on_endorsement?, :boolean, default: false)
    field(:email_on_follower?, :boolean, default: false)
    # The admin newsletter ("Rundbrief", Vutuv.Newsletters). Unlike the event
    # notices above this is an opt-OUT (default true): existing members are
    # subscribed and every newsletter carries a one-click unsubscribe that flips
    # this off. Settable on the notifications settings page or that link.
    field(:newsletter_emails?, :boolean, default: true)
    # Whether this member's avatar shows the real-time "online" green dot while
    # they have the site open. Default on; opting out (Privacy settings) means
    # VutuvWeb.Presence never tracks them, so they show as online to no one.
    field(:show_online_status?, :boolean, default: true)
    # Whether the profile's "Social media posts" card shows the latest public
    # posts of the listed feed-capable accounts (Vutuv.SocialFeed: Mastodon +
    # Bluesky — the column name predates Bluesky and gates the whole card).
    # Default on; the opt-out lives on the Privacy settings page.
    field(:show_mastodon_feed?, :boolean, default: true)
    # Whether the profile's "Code" card shows the cached public statistics of
    # the listed code-forge accounts (Vutuv.CodeStats: GitHub, GitLab,
    # Codeberg). Default on; the opt-out lives on the Privacy settings page.
    # Off, the accounts still render as plain links on the Social Media card.
    field(:show_code_stats?, :boolean, default: true)
    # The Fediverse opt-in (Privacy settings, default off). Federation is not
    # built yet: the flag ships ahead of the feature to measure demand and to
    # collect the per-member consent any future ActivityPub federation must be
    # gated on (remote deletion is unenforceable, so opt-in is the only lawful
    # default). Until federation ships, nothing reads this flag.
    field(:fediverse_followers?, :boolean, default: false)
    # The member-preference fields (the Vutuv.Prefs registry): deliberately
    # WITHOUT schema or DB defaults — nil means "inherit the installation
    # default" (admin-set at /admin/preferences, else the shipped default from
    # the registry). Never read these raw at a render site; resolve through
    # Vutuv.Prefs.get/2 (or the post_prefs/1 / Vutuv.Maps seams below).
    #
    # The viewer's map preferences (language & display settings page, applied to
    # every address this member looks at): which map services to show and which
    # one is the default rendered as the primary "Open in …" button. Shipped
    # defaults mean "all three on, Google the default". `Vutuv.Maps` owns the
    # resolution and never trusts these to be consistent.
    field(:map_google?, :boolean)
    field(:map_openstreetmap?, :boolean)
    field(:map_apple?, :boolean)
    field(:default_map_service, :string)
    # The reader's post-display preferences (same settings page, applied to
    # every post this member reads: feed, profile Beiträge, permalink). The
    # line counts drive the CSS line-clamp on the preview body, desktop and
    # mobile independently; an explicit `0` means "no truncation at all". The
    # hyphenation booleans drive `hyphens:` on the post body. The shipped
    # defaults reproduce the previous fixed behaviour: clamp at 6 lines on
    # desktop / 8 on a phone, hyphenate only the narrow phone column. Read
    # through `post_prefs/1`, never straight off the struct.
    field(:post_lines_desktop, :integer)
    field(:post_lines_mobile, :integer)
    field(:post_hyphenate_desktop, :boolean)
    field(:post_hyphenate_mobile, :boolean)
    # The account owner proved control of their email by entering a login PIN
    # (set true on first successful login). The anti-spam visibility gate: while
    # false the account is hidden from search, the feed, follower lists and
    # messaging. Not to be confused with identity_verified? above.
    field(:email_confirmed?, :boolean, default: false)
    # Set programmatically by Vutuv.Activity.mark_notifications_read/1; never cast.
    field(:notifications_read_at, :naive_datetime)
    # The owner closed the profile-completion checklist with its × (it also
    # auto-hides an hour after sign-up). Set programmatically by
    # Vutuv.Accounts.dismiss_onboarding/1; never cast from a profile form.
    field(:onboarding_dismissed?, :boolean, default: false)
    # Moderation state, managed by Vutuv.Moderation, never cast from params.
    # frozen_at: profile in the freezer pending review (hidden from everyone
    # but the owner and admins). suspended_until: strike 2, login blocked and
    # profile hidden until the date. deactivated_at: strike 3, permanent.
    field(:frozen_at, :naive_datetime)
    field(:suspended_until, :naive_datetime)
    field(:deactivated_at, :naive_datetime)
    # Why the account carries a moderation state, when set by an admin ruling
    # (e.g. "spam"). Internal only — never rendered publicly, never cast from
    # params; set alongside deactivated_at by Vutuv.Moderation.remove_owner and
    # cleared by Vutuv.Accounts.admin_restore_user. Drives the /admin/users
    # "spam" filter and the daily-report tally.
    field(:moderation_reason, :string)
    # Deliverability state, managed by Vutuv.Deliverability, never cast from
    # params. unreachable_at: the account has no deliverable email left (every
    # address bounced), so it can never receive a login PIN. The profile is
    # hidden from other members like a moderation freeze, but this is a
    # deliverability fact, not an abuse ruling. Cleared when a login PIN proves
    # an address works again, or by an admin.
    field(:unreachable_at, :naive_datetime)
    field(:tag_list, :string, virtual: true)

    has_many(:search_query_requesters, Vutuv.Search.SearchQueryRequester)
    has_many(:search_query_results, Vutuv.Search.SearchQueryResult)
    has_many(:login_pins, Vutuv.Accounts.LoginPin)
    has_many(:emails, Vutuv.Accounts.Email)
    has_many(:user_tags, Vutuv.Tags.UserTag)
    has_many(:username_changes, Vutuv.Accounts.UsernameChange)
    has_many(:urls, Vutuv.Profiles.Url)
    has_many(:phone_numbers, Vutuv.Profiles.PhoneNumber)
    has_many(:addresses, Vutuv.Profiles.Address)
    has_many(:work_experiences, Vutuv.Profiles.WorkExperience)
    has_many(:educations, Vutuv.Profiles.Education)
    has_many(:social_media_accounts, Vutuv.Profiles.SocialMediaAccount)
    has_many(:languages, Vutuv.Profiles.Language)
    has_many(:qualifications, Vutuv.Profiles.Qualification)

    # The work experience the member pinned as their profile job title (issue
    # #833). nil = pick it automatically (UserHelpers.current_job/1). Set only
    # through Accounts.pin_profile_work_experience/2 / unpin_profile_work_experience/1
    # (never cast from the profile form), and nulled by the DB when the pinned
    # experience is deleted (ON DELETE SET NULL), so it can never point at a
    # gone role.
    belongs_to(:profile_work_experience, Vutuv.Profiles.WorkExperience)
    has_many(:search_terms, Vutuv.Accounts.SearchTerm, on_replace: :delete)
    has_many(:endorsements, Vutuv.Tags.UserTagEndorsement)

    has_many(:tags, through: [:user_tags, :tag])

    has_many(:inbound_follows, Vutuv.Social.Follow, foreign_key: :followee_id)
    has_many(:followers, through: [:inbound_follows, :follower])

    has_many(:outbound_follows, Vutuv.Social.Follow, foreign_key: :follower_id)
    has_many(:followees, through: [:outbound_follows, :followee])

    timestamps()
  end

  @doc """
  The columns a user listing row renders: the id (links, follow state, work-
  info maps), the name parts `full_name/1` and the avatar initials read, the
  slug (`Phoenix.Param`) and the avatar. Listing queries (most-followed,
  tag-recommended) select only these via `select: struct(u, listing_fields())`
  so their group-by doesn't drag all user columns through aggregate and sort.
  """
  def listing_fields do
    # :avatar_fingerprint is loaded so listing-rendered avatars build the
    # fingerprinted URL `<username>-<version>-<fp>.avif` (see Vutuv.Uploads).
    # :updated_at is still loaded for rows not yet migrated to that scheme: their
    # avatar falls back to the legacy `?v=#{phash2(updated_at)}` cache-buster, so
    # a re-uploaded thumbnail doesn't keep serving the cached old image.
    # :profile_work_experience_id is loaded so a listing row's work line reflects
    # a member's pinned profile job title (issue #833) via work_information_map/2,
    # not just the automatic heuristic.
    ~w(id first_name last_name honorific_prefix honorific_suffix username avatar avatar_fingerprint updated_at profile_work_experience_id)a
  end

  # :username is deliberately NOT here: the username is unique, rate-limited
  # and Twitter-validated, so it only changes through username_changeset/2 (used by
  # Accounts.update_username/2), never through the generic profile form.
  # :email_confirmed? is NOT here either: it flips only via the login-PIN path
  # (Accounts.activate_user/1, its own narrow cast) — castable, it would let a
  # registration self-activate without ever proving control of an email.
  @optional_fields ~w(noindex? noai? notification_emails? dm_email_each_message? dm_email_delay_minutes email_on_endorsement? email_on_follower? newsletter_emails? show_online_status? show_mastodon_feed? show_code_stats? fediverse_followers? map_google? map_openstreetmap? map_apple? default_map_service post_lines_desktop post_lines_mobile post_hyphenate_desktop post_hyphenate_mobile headline employment_status employment_status_visibility desired_salary_min desired_salary_currency desired_salary_period desired_salary_visibility first_name last_name middle_name nickname honorific_prefix honorific_suffix gender birthdate locale tag_list)a

  # The job-availability values a member can advertise (issue #870), other
  # than the "not specified" default which is stored as nil. The single source
  # of truth for the changeset's validate_inclusion and, via
  # employment_statuses/0, the edit form's select options
  # (VutuvWeb.UserHelpers.employment_status_options/0), so the form can never
  # offer a value the changeset would reject.
  @employment_statuses ~w(open looking)

  def employment_statuses, do: @employment_statuses

  # The shared three-way visibility set (issue #928), used by BOTH
  # employment_status_visibility (default "members") and
  # desired_salary_visibility (default "hidden"): "everyone" (all visitors,
  # incl. logged-out + crawlers/agent formats), "members" (only a signed-in
  # member) or "hidden" (nobody). The single source of truth for the
  # changeset's validate_inclusion on either column and, via
  # visibility_options/0, both Basics-form selects, so the form can never offer
  # a value the changeset would reject.
  @visibilities ~w(everyone members hidden)

  def visibilities, do: @visibilities

  # The currencies and periods the salary expectation may use (issue #928).
  # Whitelisted single sources for the changeset's validate_inclusion and the
  # Basics-form selects (via desired_salary_currency_options/0 /
  # desired_salary_period_options/0). Defaults "EUR" / "year".
  @desired_salary_currencies ~w(EUR USD GBP CHF)

  def desired_salary_currencies, do: @desired_salary_currencies

  @desired_salary_periods ~w(hour day week month year)

  def desired_salary_periods, do: @desired_salary_periods

  # The delay presets the notifications settings page offers (minutes a message
  # may sit unread before the nudge email goes out). The single source of truth
  # for both the select's options and the changeset's validation, so the form
  # can never save a value the query does not expect. 0 means "as soon as the
  # next sweep runs".
  @dm_email_delay_values [0, 5, 15, 30, 60, 120]

  def dm_email_delay_values, do: @dm_email_delay_values

  # Upper bound for a post-display line clamp. A generous cap so nobody sets an
  # absurd value, while still comfortably above any real preference; 0 means
  # "no truncation". The bound itself lives in the Vutuv.Prefs registry (the
  # single source all three GUIs validate against); this is the schema-side
  # accessor the changeset's validate_number and the settings form's number
  # input share.
  def post_lines_max, do: Prefs.pref!(:post_lines_desktop).max

  # The SHIPPED defaults for the reader's post-display preferences, mirrored by
  # the CSS custom-property fallbacks in `.post-clamp` / `.markdown--post`
  # (components.css). Deliberately NOT the installation defaults: this map is
  # what `VutuvWeb.PostComponents.post_body_style/1` compares against to decide
  # whether a reader's DOM can stay clean and lean on the CSS fallbacks — that
  # comparison must track what the stylesheet says, not what the admin chose.
  @post_prefs_defaults %{
    lines_desktop: 6,
    lines_mobile: 8,
    hyphenate_desktop: false,
    hyphenate_mobile: true
  }

  def post_prefs_defaults, do: @post_prefs_defaults

  @doc """
  The reader's post-display preferences as a plain map, resolved for rendering.

  Resolves through `Vutuv.Prefs`: the member's explicit value (an explicit `0`
  line count means "no truncation"), else the installation default, else the
  shipped default — and the installation defaults for an anonymous viewer
  (`nil`), so a logged-out feed follows the admin's choice too. This is the
  single seam `VutuvWeb.PostComponents` reads; never touch the raw struct
  fields at a call site.
  """
  def post_prefs(user) when is_nil(user) or is_struct(user, __MODULE__) do
    %{
      lines_desktop: Prefs.get(user, :post_lines_desktop),
      lines_mobile: Prefs.get(user, :post_lines_mobile),
      hyphenate_desktop: Prefs.get(user, :post_hyphenate_desktop),
      hyphenate_mobile: Prefs.get(user, :post_hyphenate_mobile)
    }
  end

  @doc """
  The notification-email preference fields, by the param/column name a
  one-click unsubscribe link may switch off. Shared by `UnsubscribeToken`
  (the allowlist of fields a token may name) and `Accounts.set_email_pref/3`,
  so the unsubscribe capability can never name a non-pref column.
  """
  def email_pref_fields,
    do: ~w(notification_emails? email_on_endorsement? email_on_follower? newsletter_emails?)a

  @max_image_filesize Application.compile_env!(:vutuv, [VutuvWeb.Endpoint, :max_image_filesize])

  # Deliberately does NOT cast :emails: an address is an identity that must be
  # PIN-verified before it is attached (EmailController.create/confirm, issue
  # #759). Only registration_changeset/2 accepts the initial address, which the
  # login PIN then verifies.
  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @optional_fields)
    |> validate_avatar(params)
    |> validate_cover_photo(params)
    |> validate_first_name_or_last_name_or_nickname(params)
    |> validate_length(:first_name, max: 50)
    |> validate_length(:last_name, max: 50)
    |> validate_length(:middle_name, max: 50)
    |> validate_length(:nickname, max: 50)
    |> validate_length(:honorific_prefix, max: 50)
    |> validate_length(:honorific_suffix, max: 50)
    |> validate_length(:gender, max: 50)
    |> validate_length(:headline, max: 255)
    # locale is user-writable (profile form + PATCH /api/2.0/me) over a
    # varchar(255) column, so cap it or an oversized value raises Postgres 22001.
    |> validate_length(:locale, max: 255)
    # The literal mirrors the canonical service list in `Vutuv.Maps`; it is kept
    # inline (not `Maps.service_strings/0`) to avoid a compile cycle, since Maps
    # pattern-matches the `User` struct.
    |> validate_inclusion(:default_map_service, ~w(google openstreetmap apple))
    # Post-display line clamp: 0 means "no truncation"; anything above is a
    # line count, capped so nobody stores an absurd value (the bound comes from
    # the Vutuv.Prefs registry via post_lines_max/0). validate_number only
    # fires on a present, non-nil change, so a cleared field stays nil and
    # reads as "inherit the installation default" in post_prefs/1.
    |> validate_number(:post_lines_desktop,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: post_lines_max()
    )
    |> validate_number(:post_lines_mobile,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: post_lines_max()
    )
    |> validate_inclusion(:dm_email_delay_minutes, @dm_email_delay_values)
    |> validate_inclusion(:employment_status, @employment_statuses)
    |> validate_inclusion(:employment_status_visibility, @visibilities)
    # Salary expectation (issue #928): a positive whole-unit amount, a
    # whitelisted currency + period, and the shared three-way visibility.
    # validate_number only fires on a present, non-nil change, so clearing the
    # amount (empty field → nil) is valid and simply stores "no expectation".
    |> validate_number(:desired_salary_min, greater_than: 0)
    |> validate_inclusion(:desired_salary_currency, @desired_salary_currencies)
    |> validate_inclusion(:desired_salary_period, @desired_salary_periods)
    |> validate_inclusion(:desired_salary_visibility, @visibilities)
    |> nullify_default_birthdate()
    |> validate_birthdate()
    |> revoke_verification_on_identity_change()
  end

  # Every identity detail the verified badge vouches for: the legal name parts,
  # the nickname, the honorific titles, the gender and the birthday. An admin
  # checked these against the member's ID, so changing any of them invalidates
  # that check. Deliberately broad ("sicher ist sicher") — even a nickname,
  # title or gender edit shifts the verified identity, so it re-opens it.
  @identity_fields ~w(first_name middle_name last_name nickname
    honorific_prefix honorific_suffix gender birthdate)a

  # Auto-revoke a prior identity verification when the member edits their name or
  # birthday. The admin's ID check was made against exactly those details, so it
  # no longer holds once they change; without this someone could get a real
  # identity verified and then rename the account to impersonate, keeping the
  # badge. identity_verified? is admin-only (never cast), so this programmatic
  # put_change is the only way the edit form can clear it — re-verification is a
  # fresh admin action. Runs after nullify_default_birthdate/1 so resubmitting
  # the unset 1900-01-01 birthday sentinel is not mistaken for a change.
  defp revoke_verification_on_identity_change(changeset) do
    identity_changed? = Enum.any?(@identity_fields, &Map.has_key?(changeset.changes, &1))

    if identity_changed? and get_field(changeset, :identity_verified?) do
      put_change(changeset, :identity_verified?, false)
    else
      changeset
    end
  end

  @doc """
  The one changeset that may touch the username. The grammar (letters, digits
  and underscores, `Vutuv.Handles` length bounds, never a reserved route word)
  is the shared `Vutuv.Handles.validate_handle/2` — the same definition the
  company handle uses, so the member and company namespaces cannot drift apart.
  Handles are case-insensitive, so they are stored lowercase. Uniqueness across
  members is the `unique_constraint`; profiles live at the URL root, so a handle
  equal to a route prefix would shadow that route forever (hence "reserved").
  """
  def username_changeset(model, params \\ %{}) do
    model
    |> cast(params, [:username])
    |> validate_required(:username)
    |> Handles.validate_handle(:username)
    |> unique_constraint(:username)
  end

  # Registration is the one place where an email address may ride along with
  # the user: the address is verified right afterwards by the login PIN. It is
  # also the one place that enforces the tag minimum — tags are how members
  # are found, so an account may not start without at least three distinct
  # ones (an existing member is never forced to keep three).
  def registration_changeset(model, params \\ %{}) do
    model
    |> changeset(params)
    |> validate_minimum_tags()
    |> cast_assoc(:emails)
  end

  # How many distinct tags a sign-up must bring.
  @min_registration_tags 3

  # Counts exactly what Accounts.register_user/3 later materializes as tags:
  # the tag_list split on commas/spaces (Vutuv.Tags.parse_tag_names/1), then
  # case-insensitively de-duplicated — so a padded "Go, go, GO" is one tag,
  # not three.
  defp validate_minimum_tags(changeset) do
    distinct_tags =
      changeset
      |> get_field(:tag_list)
      |> Vutuv.Tags.parse_tag_names()
      |> Enum.uniq_by(&String.downcase/1)

    if length(distinct_tags) >= @min_registration_tags do
      changeset
    else
      add_error(
        changeset,
        :tag_list,
        "Please enter at least %{min} different tags.",
        min: @min_registration_tags
      )
    end
  end

  # Avatar/cover uploads are validated here (size, extension, decodability) but
  # NOT written to disk: the file is stored only after the row commits, by
  # Accounts.store_pending_images/2, so a rolled-back write never orphans files
  # (issue #776, mirroring the post-image pending-row pattern). The :avatar /
  # :cover_photo column is therefore set post-commit too, not in this changeset.
  defp validate_avatar(changeset, %{avatar: avatar}),
    do: validate_avatar(changeset, %{"avatar" => avatar})

  defp validate_avatar(changeset, %{"avatar" => %Plug.Upload{} = upload}),
    do: validate_image_upload(changeset, :avatar, upload, "Avatar")

  defp validate_avatar(changeset, _params), do: changeset

  defp validate_cover_photo(changeset, %{cover_photo: cover_photo}),
    do: validate_cover_photo(changeset, %{"cover_photo" => cover_photo})

  defp validate_cover_photo(changeset, %{"cover_photo" => %Plug.Upload{} = upload}),
    do: validate_image_upload(changeset, :cover_photo, upload, "Cover photo")

  defp validate_cover_photo(changeset, _params), do: changeset

  defp validate_image_upload(changeset, field, %Plug.Upload{} = upload, label) do
    cond do
      File.stat!(upload.path).size > @max_image_filesize ->
        add_error(
          changeset,
          field,
          "#{label} filesize is greater than 2MB. Please upload a smaller image."
        )

      not Vutuv.Uploads.valid_upload?(upload) ->
        add_error(changeset, field, "is not a valid image")

      true ->
        changeset
    end
  end

  defp validate_first_name_or_last_name_or_nickname(changeset, %{}) do
    first_name = get_field(changeset, :first_name)
    last_name = get_field(changeset, :last_name)
    nickname = get_field(changeset, :nickname)

    if first_name || last_name || nickname do
      changeset
    else
      message = "First name or last name or nickname must be present"

      changeset
      |> add_error(:first_name, message)
      |> add_error(:last_name, message)
      |> add_error(:nickname, message)
    end
  end

  @doc """
  The human, translated label for an employment status, or nil for the unset
  default (nil / any unknown value renders no badge). Mirrors
  `gender_gettext/1`: a schema-level gettext helper the profile badge, the
  edit form and the agent documents all read, so the wording lives in one
  place. "open" = employed but listening, "looking" = actively job-hunting.
  """
  def employment_status_label("open"), do: Gettext.gettext(VutuvWeb.Gettext, "Open to offers")

  def employment_status_label("looking"),
    do: Gettext.gettext(VutuvWeb.Gettext, "Looking for a job")

  def employment_status_label(_), do: nil

  @doc """
  The translated label for a visibility choice (issue #928), shared by both
  Basics-form visibility selects (employment status + salary expectation).
  "everyone" / "members" / "hidden" — the "members" copy is deliberately honest
  that it reduces but cannot guarantee who sees the value (a member's employer
  can create an account too).
  """
  def visibility_label("everyone"),
    do: Gettext.gettext(VutuvWeb.Gettext, "Everyone, including logged-out visitors")

  def visibility_label("members"),
    do: Gettext.gettext(VutuvWeb.Gettext, "Signed-in members only")

  def visibility_label("hidden"), do: Gettext.gettext(VutuvWeb.Gettext, "No one")

  def visibility_label(_), do: nil

  # The shared three-way visibility gate (issue #928): "everyone" shows to all
  # (incl. the anonymous public view crawlers/extension URLs get, `viewer`
  # nil); "members" shows only to a signed-in member (any non-nil `viewer`, the
  # owner included); "hidden" shows to nobody. A nil/legacy value falls back to
  # the "members" rule. The two public predicates below add the "is the value
  # set at all" guard so a call site can gate the whole row on one call.
  defp visibility_allows?("everyone", _viewer), do: true
  defp visibility_allows?("hidden", _viewer), do: false
  defp visibility_allows?(_members_or_nil, viewer), do: not is_nil(viewer)

  @doc """
  Whether `user`'s employment-status badge is visible to `viewer` (issue #928),
  the single seam the profile pill and the agent-format `ProfileDoc` both read.
  False when no status is set, else the shared visibility rule decides.
  """
  def employment_status_visible?(%__MODULE__{employment_status: nil}, _viewer), do: false

  def employment_status_visible?(%__MODULE__{} = user, viewer),
    do: visibility_allows?(user.employment_status_visibility, viewer)

  @doc """
  Whether `user`'s salary expectation is visible to `viewer` (issue #928), the
  single seam the profile line and `ProfileDoc` both read. False when no amount
  is set, else the shared visibility rule decides (default "hidden", so the
  value stays a private matching signal unless the member opens it up).
  """
  def desired_salary_visible?(%__MODULE__{desired_salary_min: nil}, _viewer), do: false

  def desired_salary_visible?(%__MODULE__{} = user, viewer),
    do: visibility_allows?(user.desired_salary_visibility, viewer)

  @doc """
  The translated period noun for a salary expectation (issue #928): "year",
  "month", "week", "day", "hour" — used both in the Basics-form period select
  and the rendered "… per <period>" line on the profile and in the agent docs.
  """
  def desired_salary_period_label("hour"), do: Gettext.gettext(VutuvWeb.Gettext, "hour")
  def desired_salary_period_label("day"), do: Gettext.gettext(VutuvWeb.Gettext, "day")
  def desired_salary_period_label("week"), do: Gettext.gettext(VutuvWeb.Gettext, "week")
  def desired_salary_period_label("month"), do: Gettext.gettext(VutuvWeb.Gettext, "month")
  def desired_salary_period_label("year"), do: Gettext.gettext(VutuvWeb.Gettext, "year")
  def desired_salary_period_label(other), do: other

  @doc """
  The display symbol for a whitelisted salary currency (issue #928); falls back
  to the code itself for anything unknown. Not translated — currency symbols
  are locale-independent.
  """
  def desired_salary_currency_symbol("EUR"), do: "€"
  def desired_salary_currency_symbol("USD"), do: "$"
  def desired_salary_currency_symbol("GBP"), do: "£"
  def desired_salary_currency_symbol(code), do: code

  @doc """
  The one-line salary-expectation summary the md/txt agent docs render (issue
  #928): the raw amount, the currency code (parseable for agents) and the
  translated period. Shares the msgid with the profile line (which instead
  shows the grouped amount + currency symbol), so the wording stays in one
  place. Takes the `%{min, currency, period}` map `ProfileDoc` builds.
  """
  def desired_salary_agent_line(%{min: min, currency: currency, period: period}) do
    Gettext.gettext(
      VutuvWeb.Gettext,
      "Salary expectation from %{amount} %{currency} per %{period}",
      amount: min,
      currency: currency,
      period: desired_salary_period_label(period)
    )
  end

  def gender_gettext("male"), do: Gettext.gettext(VutuvWeb.Gettext, "Male")
  def gender_gettext("female"), do: Gettext.gettext(VutuvWeb.Gettext, "Female")
  # The third gender ("other") displays as "divers" - its own label, decoupled
  # from the email-type "Other"/"Andere" string they used to share.
  def gender_gettext(_), do: Gettext.gettext(VutuvWeb.Gettext, "Diverse")

  defp nullify_default_birthdate(changeset) do
    case get_field(changeset, :birthdate) do
      ~D[1900-01-01] -> put_change(changeset, :birthdate, nil)
      _ -> changeset
    end
  end

  # A birthdate can't be in the future and can't be implausibly old (more than
  # 120 years back). validate_change only fires when :birthdate actually changes
  # — and nullify_default_birthdate/1 runs first — so the 1900-01-01 "unset"
  # sentinel (already nilled) never trips this, and a legacy row with a bad date
  # isn't blocked from unrelated edits. "Today" is the German calendar day
  # (Vutuv.BerlinTime), the same clock the profile age display rolls over on.
  defp validate_birthdate(changeset) do
    validate_change(changeset, :birthdate, fn :birthdate, birthdate ->
      today = Vutuv.BerlinTime.today()

      cond do
        Date.compare(birthdate, today) == :gt -> [birthdate: "can't be in the future"]
        today.year - birthdate.year > 120 -> [birthdate: "is not a valid birthdate"]
        true -> []
      end
    end)
  end

  defimpl String.Chars, for: Vutuv.Accounts.User do
    def to_string(user), do: "#{user.first_name} #{user.last_name}"
  end

  defimpl List.Chars, for: Vutuv.Accounts.User do
    def to_charlist(user), do: ~c"#{user.first_name} #{user.last_name}"
  end
end
