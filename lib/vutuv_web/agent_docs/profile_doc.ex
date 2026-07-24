defmodule VutuvWeb.AgentDocs.ProfileDoc do
  @moduledoc """
  The profile page (`/:slug`) as one data map — the single source the
  Markdown / text / JSON / vCard renderers share. Mirrors the **anonymous
  public view** of `user/show.html.heex`; unlike the page it does not cut
  the lists off after a few entries (the full lists are public on the
  sub-pages anyway, and the vCard always exported them all).

  Changed what the profile page shows? Update this builder too — the drift
  test (`agent_docs_drift_test.exs`) will remind you.
  """

  alias Vutuv.Accounts
  alias Vutuv.Accounts.User
  alias Vutuv.CodeStats
  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.Language
  alias Vutuv.Profiles.Messenger
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.AgentDocs.SectionDocs
  alias VutuvWeb.UserHelpers

  @doc """
  Options:

    * `:viewer` — the user whose eyes the doc is built through (the
      authenticated `/api/2.0` reads). Default `nil` = the anonymous public
      view the extension URLs serve; never pass a viewer for those, they
      must stay cache-safe.
    * `:emails` — override the email list (the legacy session-aware vCard
      route passes the viewer-visible set; default is what `:viewer` sees).
    * `:include_photo` — embed the avatar as a base64 data URI for the
      vCard renderer (skipped for md/txt/json, where it would be dead weight).
  """
  def build(user, opts \\ []) do
    user = preload(user)
    viewer = Keyword.get(opts, :viewer)
    path = "/" <> user.username
    # The header job, resolved against the already-preloaded experiences
    # (current_job_in_memory mirrors the page's DB-backed current_job/1 on
    # an id-ordered list — UUID v7 ids sort by creation time). A pinned role
    # (issue #833) wins over the heuristic, matching the HTML header.
    job =
      UserHelpers.current_job_in_memory(
        Enum.sort_by(user.work_experiences, & &1.id),
        user.profile_work_experience_id
      )

    # The header line: a pinned education (issue #882) leads with its
    # "Degree, School", else the job's "Title @ Org" — the same resolution the
    # HTML header uses, so the doc's description/work_info can never drift from
    # the page. `user` has :educations preloaded here, so it resolves in memory.
    work_info = UserHelpers.profile_headline(user, job, 256)
    posts = Vutuv.Posts.profile_posts(user, viewer)

    # The #928 base gate AND the #938 exclusion, resolved together (one query):
    # a signed-in /api/2.0 viewer on the owner's exclusion list (by member or
    # by confirmed-email domain) loses both fields, exactly like the profile.
    # For the anonymous extension URLs (`viewer` nil) the exclusion never
    # applies, so those formats stay the plain public view.
    job_search = Accounts.job_search_visibility(user, viewer)

    # Without a viewer: the anonymous public view, the same addresses the
    # page shows a logged-out visitor.
    emails =
      Keyword.get_lazy(opts, :emails, fn -> UserHelpers.emails_for_display(user, viewer) end)

    AgentDocs.doc_meta("profile", path,
      noindex: user.noindex?,
      noai: user.noai?,
      formats: AgentDocs.formats()
    )
    |> Map.merge(%{
      title: UserHelpers.full_name(user),
      description: work_info,
      name: UserHelpers.full_name(user),
      first_name: user.first_name,
      middle_name: user.middle_name,
      last_name: user.last_name,
      nickname: user.nickname,
      honorific_prefix: user.honorific_prefix,
      honorific_suffix: user.honorific_suffix,
      username: user.username,
      verified: user.identity_verified?,
      # The job-availability signal (issue #870), the machine value nil /
      # "open" / "looking". The md/txt renderers turn it into the same human
      # label the profile badge shows; JSON/XML keep the raw value. Viewer-
      # scoped by the visibility setting (issue #928): for the anonymous public
      # view the extension URLs serve (`viewer` nil) only an "everyone" status
      # appears; the authenticated /api/2.0 read passes its token's member as
      # `viewer`, so a "members" status shows there too. nil when not visible.
      employment_status: if(job_search.employment_status, do: user.employment_status),
      # The preferred workplace forms, any of "onsite" / "hybrid" / "remote"
      # (empty = no preference). Part of the availability signal, so it shares
      # the status's visibility exactly as the profile pill does — it never
      # appears without one.
      desired_workplace_types:
        if(job_search.employment_status, do: user.desired_workplace_types, else: []),
      # The salary expectation (issue #928), same viewer-scoping as the status
      # via its own visibility (default "hidden"). A structured map {min,
      # currency, period} so JSON/XML stay machine-readable; the md/txt
      # renderers format the same "… per <period>" line the profile shows. nil
      # (absent) when not visible to this viewer.
      desired_salary:
        if job_search.salary do
          %{
            min: user.desired_salary_min,
            currency: user.desired_salary_currency,
            period: user.desired_salary_period
          }
        end,
      headline_markdown: user.headline,
      work_info: work_info,
      current_position: current_position(job),
      gender: public_gender(user),
      member_since: NaiveDateTime.to_date(user.inserted_at),
      avatar_url: avatar_url(user),
      counts: %{
        followers: Vutuv.Social.follower_count(user),
        following: Vutuv.Social.followee_count(user),
        connections: Vutuv.Social.connection_count(user),
        posts: Vutuv.Posts.count_author_posts(user, viewer)
      },
      tags: Enum.map(user.user_tags, &SectionDocs.tag_entry/1),
      work_experiences: Enum.map(user.work_experiences, &SectionDocs.work_entry/1),
      educations: Enum.map(user.educations, &SectionDocs.education_entry/1),
      qualifications: Enum.map(user.qualifications, &SectionDocs.qualification_entry(&1, user)),
      languages: SectionDocs.language_entries(user.languages),
      links: Enum.map(user.urls, &SectionDocs.link_entry/1),
      emails: Enum.map(emails, &SectionDocs.email_entry/1),
      phone_numbers: Enum.map(user.phone_numbers, &SectionDocs.phone_entry/1),
      addresses: Enum.map(user.addresses, &SectionDocs.address_entry/1),
      # The inline Mastodon/Bluesky posts (Vutuv.SocialFeed) are deliberately
      # absent: they are connected-only dynamic external content, fetched
      # after the LiveView connects, so neither the crawler-visible
      # disconnected HTML nor these documents include them — the formats stay
      # consistent.
      social_media: Enum.map(user.social_media_accounts, &SectionDocs.social_entry/1),
      # The online messengers (issue #949), each with its deep link so an agent
      # can hand a human a one-click "start a chat" target.
      messengers: Enum.map(user.messengers, &SectionDocs.messenger_entry/1),
      # The "Code" card's cached forge statistics (Vutuv.CodeStats). Unlike
      # the inline social posts these are stored snapshots rendered into the
      # crawler-visible HTML, so the docs carry them too. Empty when the
      # :fetch_code_stats flag is off or the member opted out — consistent
      # with the page.
      code_stats: Enum.map(CodeStats.visible_accounts(user), &code_stats_entry/1),
      posts: Enum.map(posts, &post_entry/1)
    })
    |> Map.merge(birthday_fields(user))
    |> maybe_include_photo(user, opts)
  end

  # The birthday facts, gated by the member's birthdate_visibility setting so
  # the anonymous documents reveal exactly what the profile card (and the public
  # CV) do: :full → the ISO date + derived age; :age → the age only; :day_month
  # → the month-day without the year (a stable "MM-DD", so the year and thus the
  # age can't be back-computed); :none (the member hid it, or has no birthday) →
  # nothing. Kept in one place so md/txt/json/xml and the vCard (which keys BDAY
  # on `birthdate`, hence absent unless the full date is public) stay in sync.
  defp birthday_fields(user) do
    base = %{birthdate: nil, birthday_month_day: nil, age: nil}

    case User.birthdate_mode(user) do
      :full -> %{base | birthdate: user.birthdate, age: UserHelpers.age(user)}
      :age -> %{base | age: UserHelpers.age(user)}
      :day_month -> %{base | birthday_month_day: Calendar.strftime(user.birthdate, "%m-%d")}
      :none -> base
    end
  end

  # The same associations the profile page preloads (user_controller.ex),
  # without the page's preview limits.
  defp preload(user) do
    Repo.preload(user,
      social_media_accounts: SocialMediaAccount.ordered(),
      user_tags: UserTag.ordered_by_endorsements(),
      # display_preloads: the verified organization page (issue #931) and the
      # cited credential (issue #858), so the doc's work entries match the
      # profile card.
      work_experiences:
        {WorkExperience.order_by_date(WorkExperience), WorkExperience.display_preloads()},
      educations: Education.order_by_date(Education),
      # The anonymous public view hides expired credentials (issue #859); the
      # citing jobs ride along for the usage facts (issue #1005).
      qualifications:
        {Qualification.visible_to(false) |> Qualification.ordered(),
         Qualification.citing_jobs_preload()},
      languages: Language.ordered(),
      # The owner's chosen order (see Vutuv.Ordering), so the profile's agent
      # documents list these contact sections the same way the HTML pages do.
      phone_numbers: PhoneNumber.ordered(),
      messengers: Messenger.ordered(),
      urls: Url.ordered(),
      addresses: Address.ordered()
    )
  end

  defp current_position(nil), do: nil

  defp current_position(job) do
    %{
      title: UserHelpers.current_title(job),
      organization: UserHelpers.current_organization(job)
    }
  end

  # The page hides "other" (the unspecified default); the docs do the same.
  defp public_gender(%{gender: gender}) when gender in [nil, "other"], do: nil
  defp public_gender(%{gender: gender}), do: gender

  @doc """
  The member's absolute avatar URL, or nil when only the inline-data
  placeholder exists. Public because the JSON-LD Person (`VutuvWeb.JsonLd`)
  shares it — the markup must mirror the doc.
  """
  def avatar_url(user) do
    case Vutuv.Avatar.display_url(user, :medium) do
      "data:" <> _ -> nil
      "/" <> _ = path -> AgentDocs.abs_url(path)
      url -> url
    end
  end

  # One code-forge account's snapshot, straight off the stored map (string
  # keys → the doc's atom vocabulary). Facts a forge doesn't expose (GitLab:
  # followers, languages) stay nil/empty.
  defp code_stats_entry(account) do
    stats = account.code_stats

    %{
      id: account.id,
      provider: account.provider,
      url: SocialMediaAccount.url(account),
      total_stars: stats["total_stars"],
      public_repos: stats["public_repos"],
      followers: stats["followers"],
      member_since: stats["member_since"],
      last_active_at: stats["last_active_at"],
      recent_repos: stats["recent_repos"],
      languages: List.wrap(stats["languages"]),
      top_repos:
        for repo <- List.wrap(stats["top_repos"]) do
          %{
            name: repo["name"],
            url: repo["url"],
            description: repo["description"],
            language: repo["language"],
            stars: repo["stars"]
          }
        end,
      fetched_at: account.code_stats_fetched_at
    }
  end

  defp post_entry(entry) do
    %{
      url: AgentDocs.abs_url(Vutuv.Posts.path(entry.post)),
      published_on: entry.post.published_on,
      excerpt: AgentDocs.excerpt(entry.post.body),
      reposted_by: entry.reposted_by && UserHelpers.full_name(entry.reposted_by)
    }
  end

  defp maybe_include_photo(doc, user, opts) do
    if Keyword.get(opts, :include_photo, false) do
      case Vutuv.Avatar.binary(user, :thumb) do
        "data:image/" <> _ = data_uri -> Map.put(doc, :vcard_photo, data_uri)
        _ -> doc
      end
    else
      doc
    end
  end
end
