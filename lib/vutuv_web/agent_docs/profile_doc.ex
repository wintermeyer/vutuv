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

  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.Language
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

    work_info = UserHelpers.work_information_string_for_job(job, 256)
    posts = Vutuv.Posts.profile_posts(user, viewer)

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
      # label the profile badge shows; JSON/XML keep the raw value.
      employment_status: user.employment_status,
      headline_markdown: user.headline,
      work_info: work_info,
      current_position: current_position(job),
      gender: public_gender(user),
      birthdate: user.birthdate,
      age: UserHelpers.age(user),
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
      qualifications: Enum.map(user.qualifications, &SectionDocs.qualification_entry/1),
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
      posts: Enum.map(posts, &post_entry/1)
    })
    |> maybe_include_photo(user, opts)
  end

  # The same associations the profile page preloads (user_controller.ex),
  # without the page's preview limits.
  defp preload(user) do
    Repo.preload(user,
      social_media_accounts: SocialMediaAccount.ordered(),
      user_tags: UserTag.ordered_by_endorsements(),
      work_experiences: WorkExperience.order_by_date(WorkExperience),
      educations: Education.order_by_date(Education),
      # The anonymous public view hides expired credentials (issue #859).
      qualifications: Qualification.visible_to(false) |> Qualification.ordered(),
      languages: Language.ordered(),
      # The owner's chosen order (see Vutuv.Ordering), so the profile's agent
      # documents list these contact sections the same way the HTML pages do.
      phone_numbers: PhoneNumber.ordered(),
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
