defmodule Vutuv.Accounts.User do
  @moduledoc false

  use VutuvWeb, :model
  # Enables the bare `gettext/1` macro (and extraction), like the sibling schemas.
  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Handles
  alias Vutuv.Mentions
  alias Vutuv.Prefs
  alias Vutuv.Tags.Tag
  alias Vutuv.WebAddress
  @derive {Phoenix.Param, key: :username}

  schema "users" do
    field(:first_name, :string)
    field(:last_name, :string)
    field(:middle_name, :string)
    field(:nickname, :string)
    field(:honorific_prefix, :string)
    field(:honorific_suffix, :string)
    # How to say the name out loud (issue #1112), free text stored in the square
    # brackets a transcription is written in (the changeset adds them):
    # "[SHTEH-fahn VIN-ter-my-er]", "[rhymes with 'a fan']", IPA for those who
    # write it. It is a deliberately quiet field — set on the profile basics
    # form, never asked for at sign-up — and nil on nearly every account, which
    # is why the profile renders the line only when it is present
    # (`name_pronunciation/1`).
    field(:name_pronunciation, :string)
    # "female" / "male" / "diverse", or nil for "keine Angabe", which is both
    # the default and what `cast/3` folds the form's blank choice back to.
    #
    # It is asked for as the membership statistic at /admin, and it has exactly
    # one other consumer: the German email greeting
    # (`UserHelpers.email_greeting/1`), which opens "Liebe Frau Meier" / "Lieber
    # Herr Meier" and otherwise names the member just as warmly with "Hallo Max
    # Meier". A separate `salutation` preference used to own that greeting; it
    # was dropped because on a rendered sign-up form the two questions read as
    # one field asked twice.
    #
    # That merge has a known cost, and it is the reason the neutral greeting
    # must never read as a downgrade: an answer that changes how the site
    # addresses you is no longer purely an answer, so someone who wants the
    # classic form has a reason to pick a value rather than state one. Keep
    # every branch of `email_greeting/1` equally warm and the incentive stays
    # negligible.
    #
    # Beyond that greeting it drives NOTHING a member or a visitor sees: not
    # public, not in the agent formats, not on the CV, and deliberately not in
    # `@identity_fields` — an admin's ID check is about who someone is, and a
    # voluntary answer is not evidence about that, so changing it must not cost
    # the verified badge.
    #
    # Read the values as approximate. The sign-up form preselected "männlich"
    # until v7.229.0, so a "male" seeded from that era may equally be an
    # untouched default, while the other two were only ever reached by
    # overriding it (see the seeding migration).
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
    # When the member last changed their availability status or its visibility
    # (issue #935): the freshness signal a saved recruiter "people" search reads,
    # so a member who newly becomes "open"/"looking" (or opens up a hidden
    # status) surfaces in the next alert sweep, not only brand-new registrations.
    # Stamped by changeset/2 whenever employment_status or its visibility
    # changes; never cast from user input.
    field(:employment_status_set_at, :naive_datetime)
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
    # How the member wants to work: any combination of "onsite", "hybrid" and
    # "remote" — the same vocabulary a job posting's workplace_type uses, so a
    # preference maps straight onto the board's workplace chips. A **list**,
    # because the three are not mutually exclusive: plenty of people take
    # hybrid or remote but not a five-day office. `[]` = no preference (the
    # default; NOT NULL in the DB, so no call site has to tell nil and [] apart).
    # It is part of the availability signal, not a separate secret: it shows
    # beside the status badge under employment_status_visibility and is cleared
    # whenever the status goes back to "not open to work".
    field(:desired_workplace_types, {:array, :string}, default: [])
    field(:birthdate, :date)
    # How much of the birthday the public profile (and its agent-format
    # siblings + the public CV) reveal: "full" (date + age, the historical
    # default), "age" (only the age in years), "day_month" (day and month
    # without the year, so no age can be derived) or "hidden" (stored but never
    # shown publicly). The granularity applies to every viewer alike — unlike
    # the three-way audience visibilities above it is not an everyone/members
    # gate. Resolved for display through birthdate_mode/1. Members set it beside
    # the birthday field on the Basics form.
    field(:birthdate_visibility, :string, default: "full")
    field(:locale, :string)
    # How this member wants dates written and which clock they run on (issue
    # #1502) — `Vutuv.Prefs` knobs, so nil means "inherit the installation
    # default" rather than "unset". The interface language above says nothing
    # about either: an English-speaking member in Berlin still wants the
    # 24-hour clock. A new account gets both from its browser at sign-up;
    # `Vutuv.ViewerClock` resolves them for rendering.
    field(:date_region, :string)
    field(:time_zone, :string)
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

    # AI image moderation state (Vutuv.Moderation.ImageScans): nil = no image
    # or grandfathered, "pending" = limbo (owner-only), "approved" = released.
    # Set programmatically with the image columns, never cast from params.
    field(:avatar_moderation, :string)
    field(:cover_moderation, :string)
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
    # The one notification email that is on by default: it answers a question
    # the member asked and waited minutes for, and it is what lets them close
    # the tab. See the migration for the reasoning.
    field(:email_on_reference_check?, :boolean, default: true)
    field(:email_on_follower?, :boolean, default: false)
    # The admin newsletter ("Rundbrief", Vutuv.Newsletters). Unlike the event
    # notices above this is an opt-OUT (default true): existing members are
    # subscribed and every newsletter carries a one-click unsubscribe that flips
    # this off. Settable on the notifications settings page or that link.
    field(:newsletter_emails?, :boolean, default: true)
    # The saved-search alert digest (issue #935, Vutuv.SavedSearches). Opt-OUT
    # (default true): a member who never saves a search or keeps every one at
    # cadence "none" is never mailed anyway, and the digest carries a one-click
    # List-Unsubscribe that flips this off (killing *all* their alert mail,
    # while the per-search links in the body switch off a single search).
    field(:saved_search_emails?, :boolean, default: true)
    # The reader's switch for the in-app "someone I follow added a new CV
    # entry" notification (issue #980, Vutuv.Profiles.CvUpdates). Opt-OUT
    # (default true): it only ever fires for people this member deliberately
    # follows and never sends email, but it can get noisy, so the notification
    # settings page turns the whole kind off. Off, the events vanish from the
    # feed and the unread count retroactively — the feed is derived, not stored.
    field(:cv_update_notifications?, :boolean, default: true)
    # The reader's switch for the in-app "someone replied elsewhere in a thread
    # I wrote in" notification (issue #1025, the "thread" kind from #1010).
    # Opt-OUT (default true): it is what makes a live discussion reach every
    # participant, but a busy thread can get loud, so the notification settings
    # page turns the whole kind off. Off, the events vanish from the feed and
    # the unread count (derived, not stored) and the live push stops too. Direct
    # answers to your own post (the "reply" kind) are unaffected and stay on.
    field(:thread_notifications?, :boolean, default: true)
    # Whether the member's open tabs may raise a **browser** notification (the
    # Notifications API, issue #1249) when something arrives while they are not
    # looking at vutuv. Opt-IN (default false), unlike the two switches above: a
    # popup over whatever they are doing is the loudest thing vutuv can do, and
    # flipping this on is also what makes their browsers ask for permission, so
    # nobody who did not ask for it is ever prompted. The switch is the
    # member's, the permission is each browser's — see VutuvWeb.ShellLive.
    field(:browser_notifications?, :boolean, default: false)
    # Whether this member's avatar shows the real-time "online" green dot while
    # they have the site open. Default on; opting out (Privacy settings) means
    # VutuvWeb.Presence never tracks them, so they show as online to no one.
    field(:show_online_status?, :boolean, default: true)
    # Whether the profile's "Social media posts" card shows the latest public
    # posts of the listed feed-capable accounts (Vutuv.SocialFeed: Mastodon +
    # Bluesky — the column name predates Bluesky and gates the whole card).
    # Default on; the opt-out lives on the Privacy settings page.
    field(:show_mastodon_feed?, :boolean, default: true)
    field(:mastodon_clients?, :boolean, default: false)
    # Whether the profile's "Code" card shows the cached public statistics of
    # the listed code-forge accounts (Vutuv.CodeStats: GitHub, GitLab,
    # Codeberg). Default on; the opt-out lives on the Privacy settings page.
    # Off, the accounts still render as plain links on the Social Media card.
    field(:show_code_stats?, :boolean, default: true)
    # The Fediverse opt-in (the /settings/fediverse page, default off). Gates
    # follow-only ActivityPub federation (Vutuv.Fediverse): with it on, remote
    # servers can follow the member and receive their public posts. Opt-in
    # because deleting federated copies on remote servers is unenforceable, so
    # per-member consent is the only lawful default.
    field(:fediverse_followers?, :boolean, default: false)
    # Whether favourites and re-shares that come back from other networks are
    # counted under the member's posts (issue #1068). On by default, because a
    # member who already federates is publishing outward and this is only the
    # answer coming back; no second consent box, since consent is not the legal
    # basis for a third party's data anyway (data minimisation plus a working
    # deletion path is) and a switch nobody finds helps nobody. Switching it off
    # drops every stored row (`Vutuv.Fediverse.drop_reactions/1`).
    field(:fediverse_reactions?, :boolean, default: true)
    # Whether replies written on other networks are shown under the member's
    # posts (issues #1069 and #1071). **Off** by default, unlike the reaction
    # counts above, and that difference is the point: a counter row says nothing
    # about a person, while a reply is a stranger's words with their name on
    # them, held on our server. That is a decision the member has to take
    # deliberately, so it is its own switch on /settings/fediverse. Covers both
    # public replies and ones addressed to them alone, the way vutuv's own
    # messages work. Switching it off deletes every stored note
    # (`Vutuv.Fediverse.drop_notes/1`).
    field(:fediverse_replies?, :boolean, default: false)
    # The Fediverse account(s) the member is migrating *from* (issue #986,
    # half 1): actor URIs rendered as `alsoKnownAs` on the actor document. A
    # remote server (Mastodon) checks this before it moves a member's followers
    # *to* their vutuv account — the destination has to name the origin as an
    # alias first. Anyone can *claim* an alias, so the verification is the
    # remote server's job; vutuv only has to publish the claim honestly. Set
    # through the virtual `also_known_as_input` textarea, one URI per line.
    field(:also_known_as, {:array, :string}, default: [])
    field(:also_known_as_input, :string, virtual: true)
    # The Fediverse account the member redirected their followers *to* (issue
    # #986, half 2). When set, the actor document advertises `movedTo`, remote
    # servers re-point their follow, and vutuv stops pushing new posts to the
    # Fediverse (the account is "moved" — a redirect, not a live feed). The
    # vutuv profile itself is untouched: this is not a deletion or a logout,
    # only a Fediverse redirect. `moved_at` stamps the last Move broadcast, so a
    # cooldown can stop a member spamming their followers with moves. Both are
    # set programmatically by `Vutuv.Fediverse.move_out/2` (never cast).
    field(:moved_to, :string)
    field(:moved_at, :naive_datetime)
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
    # The feed language preference (issue #1461): what happens to feed posts
    # outside `feed_languages` — "original" / "translate" / "hide"; nil
    # inherits the installation default (a Vutuv.Prefs knob). The chips list
    # is the member's own (nil = all languages, no installation default: "all"
    # is the only sensible default everywhere). Read the chips through
    # `Vutuv.Posts.chosen_feed_languages/1` (the hide filter and the
    # translate mode both do), never raw.
    field(:feed_foreign_posts, :string)
    field(:feed_languages, {:array, :string})
    # The feed's tab ticker: when a post lands on the source tab this member is
    # not looking at, the bar quotes its first words for a few seconds beside
    # that tab instead of only growing a dot. The switch turns the quote off
    # again (the dot stays either way), the seconds say how long it stands.
    # Both nil = inherit the installation default; read through
    # `Vutuv.Prefs.get/2`, never straight off the struct.
    field(:feed_tab_ticker?, :boolean)
    field(:feed_tab_ticker_seconds, :integer)
    # The feed's remembered source tab (issue #1499): "vutuv" / "fediverse",
    # nil = All. Not a form field — `Vutuv.Posts.remember_feed_filter/2` writes
    # it from the tab click and `remembered_feed_filter/1` reads it back at
    # mount, so the vocabulary is closed at that chokepoint rather than in a
    # changeset. Only the opening value: while the feed is open the LiveView's
    # own assign is the truth.
    field(:feed_source, :string)
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
    # How many lines of a quoted post the /notifications rows show. A quote
    # there sits beside a link to the post itself, so unlike the counts above
    # it has no "0 = never shorten" mode. Read through
    # notification_post_lines/1, never straight off the struct.
    field(:notification_post_lines, :integer)
    # Whether other members may see that this member liked a post: the avatar
    # row a post permalink shows under the like count (issue #1233). Off keeps
    # the member out of that row for everybody **except the post's author**,
    # who was already told by name in the like notification at the time — see
    # `Vutuv.Posts.post_likers/2`. It never changes the count. Read through
    # `Vutuv.Prefs.get/2`, never straight off the struct.
    field(:like_attribution?, :boolean)
    # The license this member last published photos under (issue #1104),
    # offered as the pre-selection on their next photo post so a professional
    # sets it once. Written by Vutuv.Posts on save, never by a settings form —
    # it is a memory of a choice, not a setting anyone has to find. NULL = has
    # never picked one, so the shipped default (all rights reserved) applies.
    field(:default_post_license, :string)

    # Automatic deletion of the member's own posts once they pass an age they
    # set (issue #1255), the /settings/auto_post_deletion page. Off for
    # everybody until they switch it on themselves, and deliberately NOT a
    # `Vutuv.Prefs` knob: prefs fall back to an installation default, and no
    # admin may set a default that deletes other people's posts.
    field(:auto_post_deletion?, :boolean, default: false)
    # How old a post has to be, in days, from the fixed
    # `auto_post_deletion_day_options/0` list. NULL until the member picks one;
    # the switch cannot be on without it.
    field(:auto_post_deletion_after_days, :integer)
    # The exceptions, all default true = keep. Photos and reviews are the posts
    # that took work; an answered post is the root of a conversation other
    # people are still reading (deleting it degrades their thread); a
    # self-bookmarked post is the per-post "not this one", using the bookmark
    # glyph that is already on every card.
    field(:auto_post_deletion_keep_photos?, :boolean, default: true)
    field(:auto_post_deletion_keep_answered?, :boolean, default: true)
    field(:auto_post_deletion_keep_bookmarked?, :boolean, default: true)
    # Whether the member's own replies in other people's threads go too.
    # Default false, the one exception that defaults to keeping *more* by being
    # off: a reply sits inside someone else's conversation.
    field(:auto_post_deletion_delete_replies?, :boolean, default: false)
    # Engagement floors, 0 = off. Likes and reposts count what other networks
    # did too (`Vutuv.Posts.shown_counts/1`), because that is the figure the
    # member sees on their own post; bookmarks are local by nature, since a
    # bookmark is private to whoever made it and no server sends one on.
    field(:auto_post_deletion_min_likes, :integer, default: 0)
    field(:auto_post_deletion_min_bookmarks, :integer, default: 0)
    field(:auto_post_deletion_min_reposts, :integer, default: 0)
    # The Berlin day this member was last swept. Stamped by every pass,
    # including the ones that delete nothing, so a member the sweeper can do
    # nothing for cannot hold the front of the oldest-first batch forever.
    # Set programmatically by `Vutuv.Posts.AutoDeletion`, never cast.
    field(:auto_post_deletion_swept_on, :date)

    # The account owner proved control of their email by entering a login PIN
    # (set true on first successful login). The anti-spam visibility gate: while
    # false the account is hidden from search, the feed, follower lists and
    # messaging. Not to be confused with identity_verified? above.
    field(:email_confirmed?, :boolean, default: false)
    # When that first PIN was confirmed. Stamped once, by the same
    # Accounts.activate_user/1 branch that flips email_confirmed?, and never
    # cast from params. It dates the "your username is @handle" welcome note in
    # the notifications feed; NULL = no note, which is what every account
    # predating the feature keeps.
    field(:welcome_notified_at, :naive_datetime)
    # Set programmatically by Vutuv.Activity.mark_notifications_read/1; never cast.
    field(:notifications_read_at, :naive_datetime)
    # How far the digest mail has got (`Vutuv.Activity.Digest`). The feed is
    # derived, so there is no row to flag as sent — this is the high-water mark
    # that stands in for one.
    field(:notifications_notified_at, :utc_datetime_usec)
    # The owner closed the profile-completion checklist with its × (it also
    # auto-hides an hour after sign-up). Set programmatically by
    # Vutuv.Accounts.dismiss_onboarding/1; never cast from a profile form.
    field(:onboarding_dismissed?, :boolean, default: false)
    # When the member left the one-time welcome page (/system/welcome) behind —
    # by saving it or by skipping it. nil means "never seen", and that is the
    # ONLY gate: the post-registration redirect sends a member there while it is
    # nil, and the page itself sends anyone else home. Set programmatically by
    # Vutuv.Accounts.complete_welcome/2, never cast from params; the migration
    # backfilled every account that predates the page.
    field(:welcome_completed_at, :naive_datetime)
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
    has_many(:messengers, Vutuv.Profiles.Messenger)
    has_many(:languages, Vutuv.Profiles.Language)
    has_many(:qualifications, Vutuv.Profiles.Qualification)
    has_many(:job_references, Vutuv.References.JobReference)

    # The work experience the member pinned as their profile job title (issue
    # #833). nil = pick it automatically (UserHelpers.current_job/1). Set only
    # through Accounts.pin_profile_work_experience/2 / unpin_profile_work_experience/1
    # (never cast from the profile form), and nulled by the DB when the pinned
    # experience is deleted (ON DELETE SET NULL), so it can never point at a
    # gone role.
    belongs_to(:profile_work_experience, Vutuv.Profiles.WorkExperience)

    # The education the member pinned as their profile headline (issue #882).
    # nil = no education pinned, so the header falls back to the work-experience
    # resolution (UserHelpers.profile_headline/3). Mutually exclusive with
    # profile_work_experience_id above: pinning one clears the other in
    # Accounts.pin_profile_education/2 / pin_profile_work_experience/2 (never
    # cast from a form). Nulled by the DB when the pinned education is deleted
    # (ON DELETE SET NULL), so it can never point at a gone entry.
    belongs_to(:profile_education, Vutuv.Profiles.Education)

    # The post the member showcases at the top of their profile (issue #1110).
    # nil = nothing pinned. Exactly one at a time — that is what a column
    # rather than a join table buys — and set only through
    # Vutuv.Posts.pin_to_profile/2 / unpin_from_profile/1 (never cast from a
    # form). Nulled by the DB when the post is deleted (ON DELETE SET NULL),
    # so it can never point at a gone post.
    belongs_to(:pinned_post, Vutuv.Posts.Post)
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
  @optional_fields ~w(noindex? noai? notification_emails? dm_email_each_message? dm_email_delay_minutes email_on_endorsement? email_on_follower? email_on_reference_check? newsletter_emails? saved_search_emails? cv_update_notifications? thread_notifications? browser_notifications? show_online_status? show_mastodon_feed? mastodon_clients? show_code_stats? fediverse_followers? fediverse_reactions? fediverse_replies? also_known_as_input map_google? map_openstreetmap? map_apple? default_map_service post_lines_desktop post_lines_mobile post_hyphenate_desktop post_hyphenate_mobile notification_post_lines like_attribution? headline employment_status employment_status_visibility desired_salary_min desired_salary_currency desired_salary_period desired_salary_visibility desired_workplace_types first_name last_name middle_name nickname honorific_prefix honorific_suffix name_pronunciation gender birthdate birthdate_visibility locale date_region time_zone tag_list auto_post_deletion? auto_post_deletion_after_days auto_post_deletion_keep_photos? auto_post_deletion_keep_answered? auto_post_deletion_keep_bookmarked? auto_post_deletion_delete_replies? auto_post_deletion_min_likes auto_post_deletion_min_bookmarks auto_post_deletion_min_reposts feed_foreign_posts feed_languages feed_tab_ticker? feed_tab_ticker_seconds)a

  # The ages the automatic post deletion offers (issue #1255), in days. A fixed
  # list rather than a free number field on purpose: this setting deletes
  # things, and a typed "1" where "10" was meant is not recoverable. One day is
  # the floor. Single source of truth for the form's options and the
  # changeset's validate_inclusion, so no form can offer a value the changeset
  # would reject.
  @auto_post_deletion_day_options [1, 3, 7, 14, 30, 90, 180, 365, 730]

  # The integer settings of that page, which the form submits as text: a
  # cleared field arrives as "" and casts to nil, and every one of these
  # columns is NOT NULL, so nil has to become the "off" value again.
  @auto_post_deletion_counts ~w(auto_post_deletion_min_likes auto_post_deletion_min_bookmarks auto_post_deletion_min_reposts)a

  @doc "The post ages the automatic deletion offers, in days (issue #1255)."
  def auto_post_deletion_day_options, do: @auto_post_deletion_day_options

  # The answers the gender question offers, other than "keine Angabe" which is
  # stored as nil. Single source of truth for the changeset's
  # validate_inclusion and, via genders/0, for both forms' options, so no form
  # can offer a value the changeset would reject.
  @genders ~w(female male diverse)

  @doc """
  The gender values, in the order both forms offer them.

  This is the vocabulary of §22 Abs. 3 PStG (weiblich / männlich / divers), and
  it is the right one precisely because the question is statistical: every
  figure it will be compared against uses those categories. What made the old
  sign-up field read as an official classification was not these words, it was
  that the field was mandatory-looking, preselected and unexplained. It is
  asked once, optionally, with a line saying what it is for.

  "female" leads deliberately: this very field defaulted to "männlich" until
  v7.229.0, so every woman signing up had to correct an assumption about
  herself before typing her name.
  """
  def genders, do: @genders

  # The job-availability values a member can advertise (issue #870), other
  # than the "not specified" default which is stored as nil. The single source
  # of truth for the changeset's validate_inclusion and, via
  # employment_statuses/0, the edit form's select options
  # (VutuvWeb.UserHelpers.employment_status_options/0), so the form can never
  # offer a value the changeset would reject.
  @headline_max_length 255

  @doc """
  The tagline's character cap — the changeset's `validate_length` and the edit
  form's live counter (`data-max`) both read it, so they cannot disagree.
  """
  def headline_max_length, do: @headline_max_length

  @employment_statuses ~w(open looking)

  def employment_statuses, do: @employment_statuses

  # Fediverse aliases (issue #986, half 1): how many origin accounts a member
  # may list, and the per-URI length ceiling. Real actor URIs are short; the
  # cap is only there to stop a paste of nonsense reaching the array column.
  @max_also_known_as 10
  @max_also_known_as_length 500

  def max_also_known_as, do: @max_also_known_as

  # How a job-seeking member wants to work. Deliberately the same three values
  # `Vutuv.Jobs.JobPosting`'s workplace_type uses (kept as literals here rather
  # than read from that schema, so the Accounts context does not depend on the
  # Jobs one). The single source of truth for the changeset's subset check and,
  # via workplace_type_values/0, the form's checkboxes — and the canonical
  # ORDER a member's choices are stored and rendered in, so two members who
  # ticked the same boxes read alike.
  @desired_workplace_types ~w(onsite hybrid remote)

  def workplace_type_values, do: @desired_workplace_types

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

  # The birthday visibility granularity: how much of the birthday the public
  # profile (and every agent format + the public CV) reveals. "full" = the
  # date and the derived age (the historical default); "age" = only the age in
  # years; "day_month" = the day and month without the year (so no age can be
  # back-computed); "hidden" = stored but never shown publicly. The single
  # source for the changeset's validate_inclusion and, via
  # birthdate_visibility_options/0, the Basics-form select, so the form can
  # never offer a value the changeset would reject. Resolve it for a given
  # member with birthdate_mode/1 (which also folds "hidden" and "no birthday"
  # together into :none).
  @birthdate_visibilities ~w(full age day_month hidden)

  def birthdate_visibilities, do: @birthdate_visibilities

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

  # The SHIPPED default for the notification quote, mirrored by the
  # `--notif-clamp` fallback in `.notif-clamp` (components.css) — the same
  # deal `post_prefs_defaults/0` has with `.post-clamp`, so the DOM stays
  # clean for a reader who is on the shipped value.
  @notification_post_lines_default 5

  def notification_post_lines_default, do: @notification_post_lines_default

  @doc """
  How many lines of a quoted post the reader's /notifications rows show,
  resolved through `Vutuv.Prefs`: their own explicit value, else the
  installation default, else the shipped 5. The single seam
  `VutuvWeb.NotificationLive.Index` reads; never touch the raw struct field.
  """
  def notification_post_lines(user) when is_nil(user) or is_struct(user, __MODULE__),
    do: Prefs.get(user, :notification_post_lines)

  @doc "The bounds the notification-quote line count is validated against."
  def notification_post_lines_min, do: Prefs.pref!(:notification_post_lines).min
  def notification_post_lines_max, do: Prefs.pref!(:notification_post_lines).max

  @doc """
  The notification-email preference fields, by the param/column name a
  one-click unsubscribe link may switch off. Shared by `UnsubscribeToken`
  (the allowlist of fields a token may name) and `Accounts.set_email_pref/3`,
  so the unsubscribe capability can never name a non-pref column.
  """
  def email_pref_fields,
    do:
      ~w(notification_emails? email_on_endorsement? email_on_follower? email_on_reference_check? newsletter_emails? saved_search_emails?)a

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
    |> normalize_name_pronunciation()
    |> validate_length(:name_pronunciation, max: 255)
    |> validate_name_pronunciation()
    # An inclusion check, not a length cap: the gender is a closed choice of
    # three, and `cast/3` already folds the form's blank "keine Angabe" option
    # to nil (its default empty_values), which `validate_inclusion` then skips.
    |> validate_inclusion(:gender, @genders)
    |> validate_length(:headline, max: @headline_max_length)
    # The tagline may only mention handles that exist (relaxed for the import).
    |> Mentions.validate_mentions_exist(:headline)
    |> validate_headline_not_link_only()
    # locale is user-writable (profile form + PATCH /api/2.0/me) over a
    # varchar(255) column, so cap it or an oversized value raises Postgres 22001.
    |> validate_length(:locale, max: 255)
    # The date shape is a closed choice of four, owned by the Prefs registry
    # that also fills the settings select.
    |> validate_inclusion(:date_region, Prefs.pref!(:date_region).values)
    # The time zone is NOT checked against that registry's list: the settings
    # select offers the canonical civil zones, but the value a browser reports
    # at sign-up is whatever its own ICU build calls the zone, aliases included
    # (`Europe/Kiev`, `Asia/Calcutta`). The real question is whether this
    # installation can convert into it, so ask the time zone database.
    |> validate_change(:time_zone, fn :time_zone, zone ->
      if Vutuv.TimeZones.known?(zone),
        do: [],
        else: [time_zone: "is not a known time zone"]
    end)
    # The literal mirrors the canonical service list in `Vutuv.Maps`; it is kept
    # inline (not `Maps.service_strings/0`) to avoid a compile cycle, since Maps
    # pattern-matches the `User` struct.
    |> validate_inclusion(:default_map_service, ~w(google openstreetmap apple))
    # The feed's foreign-language mode (issue #1461); a tampered value must
    # not fail the whole preferences form, so unknown values are refused with
    # a field error like the map service above.
    # The closed value set has one owner: the Vutuv.Prefs registry entry that
    # also drives the settings page's select.
    |> validate_inclusion(:feed_foreign_posts, Prefs.pref!(:feed_foreign_posts).values)
    |> normalize_feed_languages()
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
    # The notification quote has no "no truncation" mode (see the schema note),
    # so its floor is 1, not 0; a cleared field stays nil = inherit.
    |> validate_number(:notification_post_lines,
      greater_than_or_equal_to: notification_post_lines_min(),
      less_than_or_equal_to: notification_post_lines_max()
    )
    |> validate_inclusion(:dm_email_delay_minutes, @dm_email_delay_values)
    |> validate_inclusion(:employment_status, @employment_statuses)
    |> validate_inclusion(:employment_status_visibility, @visibilities)
    |> stamp_employment_status_change()
    # Salary expectation (issue #928): a positive whole-unit amount, a
    # whitelisted currency + period, and the shared three-way visibility.
    # validate_number only fires on a present, non-nil change, so clearing the
    # amount (empty field → nil) is valid and simply stores "no expectation".
    # Cap at the int4 column max so an oversized amount fails as a field error
    # rather than raising Postgres 22003 (the integer analog of the varchar 22001 class).
    |> validate_number(:desired_salary_min, greater_than: 0, less_than_or_equal_to: 2_147_483_647)
    |> validate_inclusion(:desired_salary_currency, Vutuv.Salary.currencies())
    |> validate_inclusion(:desired_salary_period, Vutuv.Salary.periods())
    |> validate_inclusion(:desired_salary_visibility, @visibilities)
    |> normalize_workplace_types()
    |> validate_subset(:desired_workplace_types, @desired_workplace_types)
    |> clear_workplace_without_status()
    |> validate_auto_post_deletion()
    |> nullify_default_birthdate()
    |> validate_birthdate()
    |> validate_inclusion(:birthdate_visibility, @birthdate_visibilities)
    |> normalize_also_known_as()
    |> revoke_verification_on_identity_change()
  end

  # Automatic post deletion (issue #1255). Three things, in the order they can
  # go wrong:
  #
  #   * the age is one of the offered values, so a hand-made request cannot ask
  #     for "delete everything from the last hour";
  #   * the switch cannot be on without an age — an enabled rule with a NULL
  #     threshold would either delete nothing (silently useless) or everything,
  #     depending on how the query read it, and neither is allowed to be a
  #     question;
  #   * the engagement floors are whole, non-negative and inside int4. They are
  #     NOT NULL columns fed by text inputs, so a cleared field ("" -> nil)
  #     becomes 0 = off rather than a 23502 on save.
  defp validate_auto_post_deletion(changeset) do
    changeset
    |> zero_cleared_counts()
    |> validate_inclusion(:auto_post_deletion_after_days, @auto_post_deletion_day_options)
    |> validate_auto_post_deletion_age_present()
    |> validate_auto_post_deletion_counts()
  end

  defp zero_cleared_counts(changeset) do
    Enum.reduce(@auto_post_deletion_counts, changeset, fn field, acc ->
      case fetch_field(acc, field) do
        {:changes, nil} -> put_change(acc, field, 0)
        _ -> acc
      end
    end)
  end

  defp validate_auto_post_deletion_age_present(changeset) do
    if get_field(changeset, :auto_post_deletion?) do
      validate_required(changeset, [:auto_post_deletion_after_days])
    else
      changeset
    end
  end

  defp validate_auto_post_deletion_counts(changeset) do
    Enum.reduce(@auto_post_deletion_counts, changeset, fn field, acc ->
      validate_number(acc, field,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 2_147_483_647
      )
    end)
  end

  # The tagline is the one line under a member's name, so it has to say
  # something about them: a value that is nothing but a URL, a domain, an email
  # address or a wrapped-up link (`Vutuv.WebAddress`) is a billboard, and it is
  # what a spam sign-up puts there. A tagline that *mentions* an address inside
  # a sentence ("Co-Founder of Taxdoo (www.taxdoo.com)") is ordinary and stays
  # valid — members have the Links section for the address itself.
  # The chips list stores only known language codes, and the two spellings of
  # "all languages" — every box ticked, or none — both store as nil, so the
  # feed filter has exactly one representation of "nothing to hide".
  defp normalize_feed_languages(changeset) do
    case get_change(changeset, :feed_languages) do
      nil ->
        changeset

      list when is_list(list) ->
        known = Enum.filter(Enum.uniq(list), &Vutuv.Languages.known?/1)

        if known == [] or length(known) >= length(Vutuv.Languages.codes()) do
          put_change(changeset, :feed_languages, nil)
        else
          put_change(changeset, :feed_languages, known)
        end
    end
  end

  defp validate_headline_not_link_only(changeset) do
    validate_change(changeset, :headline, fn :headline, headline ->
      if WebAddress.link_only?(headline),
        do: [headline: "can't be only a link. Please describe yourself in a few words."],
        else: []
    end)
  end

  # A pronunciation is one spoken line, so fold every run of whitespace (a
  # pasted line break included) into a single space and trim the ends, then put
  # the value in the square brackets a transcription is written in. Both run
  # *before* the length check on purpose: a value that only overruns 255 because
  # of stray whitespace is fixed rather than refused. An emptied field folds to
  # nil, which is what "I don't want this shown" means — `cast/3`'s own
  # empty_values only catch a literal "".
  defp normalize_name_pronunciation(changeset) do
    case get_change(changeset, :name_pronunciation) do
      nil ->
        changeset

      value ->
        case value |> String.replace(~r/\s+/u, " ") |> String.trim() do
          "" -> put_change(changeset, :name_pronunciation, nil)
          normalized -> put_change(changeset, :name_pronunciation, bracket(normalized))
        end
    end
  end

  # `[…]` is how a phonetic transcription is written, and the brackets are what
  # tell a reader that the string is one rather than a nickname or a spelling —
  # which matters all the more now that the line carries no other label. So the
  # form does not *demand* them: whichever bracket is missing is simply added,
  # and a member who typed them keeps exactly what they typed (no doubling).
  # Deliberately literal about the brackets Stefan asked for: the phonemic
  # `/…/` spelling is not treated as a delimiter of its own, so `/ˈʃtɛfan/`
  # becomes `[/ˈʃtɛfan/]` rather than silently changing what the member wrote.
  defp bracket(value) do
    value = if String.starts_with?(value, "["), do: value, else: "[" <> value
    if String.ends_with?(value, "]"), do: value, else: value <> "]"
  end

  # What a pronunciation may not be. Two ways a value carries no pronunciation
  # at all, refused with the same "say the name" nudge:
  #
  #   * no letter anywhere ("---", "???", "123"). A pronunciation is written in
  #     letters — unlike a tag, where a symbol like "C#" or an emoji is a name
  #     people really use, so this is stricter than `Tag.punctuation_only?/1`.
  #   * nothing but a web or email address, the billboard a spam sign-up puts
  #     into every free-text field — the same `Vutuv.WebAddress` whole-value
  #     rule the tagline uses, so a hint that *mentions* one ("wie in
  #     example.com") stays valid.
  defp validate_name_pronunciation(changeset) do
    validate_change(changeset, :name_pronunciation, fn :name_pronunciation, value ->
      if Regex.match?(~r/\p{L}/u, value) and not WebAddress.link_only?(value),
        do: [],
        else: [name_pronunciation: "must spell out how the name sounds"]
    end)
  end

  @doc """
  The member's spoken-name hint (issue #1112), or `nil` when they never set one.

  The single seam the profile, the CV/vCard and the agent documents read, so
  "blank means the feature is simply not there" is decided in exactly one place
  — a stored `""` (an older row, an API write) reads as absent, like a `nil`.
  """
  def name_pronunciation(%__MODULE__{name_pronunciation: value}) do
    case value do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: value
    end
  end

  # Every identity detail the verified badge vouches for: the legal name parts,
  # the nickname, the honorific titles and the birthday. An admin checked these
  # against the member's ID, so changing any of them invalidates that check.
  # Deliberately broad ("sicher ist sicher") — even a nickname or title edit
  # shifts the verified identity, so it re-opens it.
  # Two fields are deliberately left out, both for the same reason: they say
  # something *about* the verified name rather than being part of it, so no ID
  # check is invalidated by changing them. `name_pronunciation` says how the
  # name sounds — a badge that dropped over a spelling hint would just teach
  # members to leave the hint wrong. `gender` is a voluntary answer kept for the
  # membership statistic, which is not a claim an ID card could confirm or
  # refute; it WAS on this list in its first incarnation, and keeping it here
  # would make correcting a wrong value cost people their badge.
  @identity_fields ~w(first_name middle_name last_name nickname
    honorific_prefix honorific_suffix birthdate)a

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
  organization handle uses, so the member and organization namespaces cannot drift apart.
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
    # A handle already linked from a post can't be claimed, or the rename would
    # hijack those existing @handle links (issue: handle-change propagation).
    |> Mentions.validate_handle_available(:username)
  end

  # Registration is the one place where an email address may ride along with
  # the user: the address is verified right afterwards by the login PIN. It is
  # also the one place that enforces the tag minimum — tags are how members
  # are found, so an account may not start without at least three distinct
  # ones (an existing member is never forced to keep three).
  def registration_changeset(model, params \\ %{}) do
    model
    |> changeset(params)
    |> validate_tag_list()
    |> cast_assoc(:emails)
  end

  # The three tag rules share one resolved list: `distinct_tag_names/1` asks the
  # database what each typed name really names, and running that per rule would
  # cost three lookups for one sign-up.
  defp validate_tag_list(changeset) do
    names = distinct_tag_names(changeset)

    changeset
    |> validate_minimum_tags(names)
    |> validate_maximum_tags(names)
    |> validate_usable_tags(names)
  end

  # How many distinct tags a sign-up must bring.
  @min_registration_tags 3

  # Counts exactly what Accounts.register_user/3 later materializes as tags:
  # the tag_list split on commas (Vutuv.Tags.parse_tag_names/1), then resolved
  # to the tags those names really name (Vutuv.Tags.canonical_tag_names/1), so
  # a padded "Go, go, GO" is one tag and so is "ROR, Ruby on Rails" — two
  # spellings of one topic (issue #1338), which the member cannot tell apart by
  # looking. Counting them separately would pass the minimum below and then
  # land an account holding one tag, the extra spellings dying silently on the
  # unique index.
  defp distinct_tag_names(changeset) do
    changeset
    |> get_field(:tag_list)
    |> Vutuv.Tags.parse_tag_names()
    |> Vutuv.Tags.canonical_tag_names()
  end

  defp validate_minimum_tags(changeset, names) do
    if length(names) >= @min_registration_tags do
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

  # The profile tag ceiling (Vutuv.Tags.max_user_tags/0) applies to new accounts
  # too: account setup only materializes tags up to the cap, so rejecting the
  # excess here keeps the form honest instead of silently dropping tags.
  defp validate_maximum_tags(changeset, names) do
    max = Vutuv.Tags.max_user_tags()

    if length(names) <= max do
      changeset
    else
      add_error(changeset, :tag_list, "Please enter at most %{max} different tags.", max: max)
    end
  end

  # `Vutuv.Tags.Tag` refuses a name that names no topic — one that is only a web
  # or email address, and one that is only punctuation — but
  # `Accounts.register_user/3` materializes the sign-up tags *after* the insert
  # and ignores per-tag failures, so without this the account would be created
  # with that tag quietly missing. Naming the offending token here lets the
  # sign-up form say what to fix instead.
  defp validate_usable_tags(changeset, names) do
    cond do
      address = Enum.find(names, &WebAddress.link_only?/1) ->
        add_error(
          changeset,
          :tag_list,
          "\"%{tag}\" is a web address, not a tag. Please describe yourself with words.",
          tag: address
        )

      punctuation = Enum.find(names, &Tag.punctuation_only?/1) ->
        add_error(
          changeset,
          :tag_list,
          "\"%{tag}\" is only punctuation, not a tag.",
          tag: punctuation
        )

      true ->
        changeset
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
  `gender_label/1`: a schema-level gettext helper the profile badge, the
  edit form and the agent documents all read, so the wording lives in one
  place. "open" = employed but listening, "looking" = actively job-hunting.
  """
  def employment_status_label("open"), do: gettext("Open to offers")

  def employment_status_label("looking"),
    do: gettext("Looking for a job")

  def employment_status_label(_), do: nil

  @doc """
  The human, translated label for one workplace value, or nil for an unknown
  one. The wording deliberately matches a job posting's workplace chip
  (`Vutuv.Jobs.JobPosting.workplace_type_label/1`) — same msgid, so a seeker's
  "Remote" and a posting's "Remote" always read alike — while the strings stay
  here, keeping Accounts free of a dependency on Jobs.
  """
  def desired_workplace_label("onsite"), do: gettext("On-site")
  def desired_workplace_label("hybrid"), do: gettext("Hybrid")
  def desired_workplace_label("remote"), do: gettext("Remote")
  def desired_workplace_label(_), do: nil

  @doc """
  A member's workplace preferences as one human line ("Hybrid, Remote"), in
  the canonical order, or nil when they stated none. The single rendering the
  profile badge and the agent documents share.
  """
  def desired_workplace_line(types) when is_list(types) do
    case Enum.map(types, &desired_workplace_label/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      labels -> Enum.join(labels, ", ")
    end
  end

  def desired_workplace_line(_types), do: nil

  @doc """
  The translated label for a visibility choice (issue #928), shared by both
  Basics-form visibility selects (employment status + salary expectation).
  "everyone" / "members" / "hidden" — the "members" copy is deliberately honest
  that it reduces but cannot guarantee who sees the value (a member's employer
  can create an account too).
  """
  def visibility_label("everyone"),
    do: gettext("Everyone, including logged-out visitors")

  def visibility_label("members"),
    do: gettext("Signed-in members only")

  def visibility_label("hidden"), do: gettext("No one")

  def visibility_label(_), do: nil

  @doc """
  The translated label for a birthday visibility choice, shared by the
  Basics-form select (via `VutuvWeb.UserHelpers.birthdate_visibility_options/0`)
  so the wording lives in one place.
  """
  def birthdate_visibility_label("full"),
    do: gettext("Full date and age")

  def birthdate_visibility_label("age"),
    do: gettext("Age only, without the date")

  def birthdate_visibility_label("day_month"),
    do: gettext("Day and month, without the year")

  def birthdate_visibility_label("hidden"),
    do: gettext("Do not show my birthday")

  def birthdate_visibility_label(_), do: nil

  @doc """
  The effective birthday display mode for `user`, the single seam the profile
  card, the agent-format `ProfileDoc` and the public CV all read:

    * `:full` — show the full date and the derived age (the default);
    * `:age` — show only the age in years, not the date;
    * `:day_month` — show the day and month, but not the year (so no age);
    * `:none` — show nothing, because the member hid it *or* has no birthday.

  Folding "hidden" and "no birthday set" into one `:none` lets a call site gate
  the whole birthday display on a single value. A nil/legacy `birthdate_visibility`
  falls back to `:full`, the historical public behaviour.
  """
  def birthdate_mode(%__MODULE__{birthdate: nil}), do: :none
  def birthdate_mode(%__MODULE__{birthdate_visibility: "hidden"}), do: :none
  def birthdate_mode(%__MODULE__{birthdate_visibility: "age"}), do: :age
  def birthdate_mode(%__MODULE__{birthdate_visibility: "day_month"}), do: :day_month
  def birthdate_mode(%__MODULE__{}), do: :full

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
  Delegates to the shared `Vutuv.Salary` model.
  """
  defdelegate desired_salary_period_label(period), to: Vutuv.Salary, as: :period_label

  @doc """
  The display symbol for a whitelisted salary currency (issue #928); falls back
  to the code itself for anything unknown. Not translated — currency symbols
  are locale-independent. Delegates to the shared `Vutuv.Salary` model.
  """
  defdelegate desired_salary_currency_symbol(code), to: Vutuv.Salary, as: :currency_symbol

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

  @doc """
  The human, translated label for a gender, or nil for "keine Angabe".

  Locale-neutral values, translated labels, so an installation outside Germany
  translates one string rather than six call sites: German renders them
  "Weiblich" / "Männlich" / "Divers". "Divers" is the §22 Abs. 3 PStG word and stays that word in German;
  the English label is "Diverse", not "Other", because the third answer names
  itself rather than being the leftover bucket the old `other` value was.
  """
  def gender_label("female"), do: gettext("Female")
  def gender_label("male"), do: gettext("Male")
  def gender_label("diverse"), do: gettext("Diverse")
  def gender_label(_), do: nil

  defp nullify_default_birthdate(changeset) do
    case get_field(changeset, :birthdate) do
      ~D[1900-01-01] -> put_change(changeset, :birthdate, nil)
      _ -> changeset
    end
  end

  # Checkbox groups post a blank "none of them" entry alongside the ticked
  # boxes, and a member can tick them in any order. Drop the blanks, drop
  # duplicates and put the survivors in the canonical order, so what is stored
  # depends on WHAT was ticked, never on the order of the clicks.
  defp normalize_workplace_types(changeset) do
    case get_change(changeset, :desired_workplace_types) do
      nil ->
        changeset

      values ->
        cleaned =
          values
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()

        put_change(
          changeset,
          :desired_workplace_types,
          Enum.filter(@desired_workplace_types, &(&1 in cleaned)) ++
            Enum.reject(cleaned, &(&1 in @desired_workplace_types))
        )
    end
  end

  # The workplace preference only makes sense beside an availability status: a
  # member back at "not open to work" advertises no workplace form either. Clear
  # it rather than leave a stale value that the next status change would
  # silently resurrect — and that the hidden form panel would keep resubmitting.
  defp clear_workplace_without_status(changeset) do
    if get_field(changeset, :employment_status) in [nil, ""] do
      put_change(changeset, :desired_workplace_types, [])
    else
      changeset
    end
  end

  # The Fediverse aliases (issue #986) come from a textarea, one account URI
  # per line. Split them, trim, drop blanks and duplicates, then store the
  # survivors in the real array column. Each entry must be an absolute https
  # URI (an ActivityPub actor id) and stay within a sane length — Postgres
  # would not reject an over-long one (the column is text[]), so a field error
  # is the guard against a member pasting nonsense. A whole-field error names
  # the first bad entry rather than silently dropping it, so the member can fix
  # it.
  #
  # Keyed off `changeset.params` (string keys after cast), not the cast change:
  # Ecto turns an empty textarea into nil, and reading `get_change` there would
  # make clearing the box a no-op — so a member could never *remove* an alias.
  # A form that omits the field entirely leaves the list untouched.
  defp normalize_also_known_as(changeset) do
    case changeset.params do
      %{"also_known_as_input" => raw} when is_binary(raw) ->
        put_also_known_as(changeset, raw)

      _ ->
        changeset
    end
  end

  defp put_also_known_as(changeset, raw) do
    entries =
      raw
      |> String.split(~r/[\r\n]+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      length(entries) > @max_also_known_as ->
        add_error(
          changeset,
          :also_known_as_input,
          "Please list at most %{max} accounts.",
          max: @max_also_known_as
        )

      bad = Enum.find(entries, &(not valid_actor_uri?(&1))) ->
        add_error(
          changeset,
          :also_known_as_input,
          "\"%{uri}\" is not a valid https account address.",
          uri: String.slice(bad, 0, 100)
        )

      true ->
        put_change(changeset, :also_known_as, entries)
    end
  end

  # An ActivityPub actor id is an absolute https URL with a real host, capped so
  # nobody stores a novel in the array.
  defp valid_actor_uri?(uri) do
    String.length(uri) <= @max_also_known_as_length and
      match?(
        %URI{scheme: "https", host: host} when is_binary(host) and host != "",
        URI.parse(uri)
      )
  end

  # Stamp employment_status_set_at whenever the member changes their
  # availability status or who may see it (issue #935): both make them newly
  # matchable (or newly hidden) to a saved recruiter search, so the alert
  # sweeper's freshness check should fire. It is never cast from user input, so
  # this put_change is the only writer.
  defp stamp_employment_status_change(changeset) do
    if changed?(changeset, :employment_status) or
         changed?(changeset, :employment_status_visibility) do
      put_change(
        changeset,
        :employment_status_set_at,
        NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
      )
    else
      changeset
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

  defimpl Vutuv.Identity, for: Vutuv.Accounts.User do
    def kind(_user), do: :user

    def id(user), do: user.id

    def display_name(user) do
      [user.honorific_prefix, user.first_name, user.last_name, user.honorific_suffix]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
    end

    def handle(user), do: user.username

    def path(user), do: "/" <> user.username

    def image(user), do: user.avatar

    def hidden?(user), do: not Vutuv.Moderation.profile_visible_to?(user, nil)

    def topic(user), do: "user:#{user.id}"

    def ap_type(_user), do: "Person"

    def ref(user) do
      %{
        name: display_name(user),
        username: user.username,
        url: VutuvWeb.Endpoint.url() <> path(user)
      }
    end
  end
end
