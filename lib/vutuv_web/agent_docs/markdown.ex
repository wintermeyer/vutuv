defmodule VutuvWeb.AgentDocs.Markdown do
  @moduledoc """
  Renders an agent doc (see `VutuvWeb.AgentDocs`) as Markdown: YAML
  frontmatter (the Cloudflare "markdown for agents" shape) plus a body per
  doc type. User-authored Markdown (headlines, post bodies) is passed
  through verbatim — it already is Markdown.

  Labels render through Gettext in the process locale, which
  `VutuvWeb.AgentDocs.negotiate/2` sets from the `?lang=` query parameter
  (default English). Structural metadata (frontmatter keys, the type
  names) stays English in every language.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.CodeStats
  alias VutuvWeb.PostComponents

  # The per-user people lists (followers/following/connections) share one
  # clause; the set lives in ListDocs.
  @people_lists VutuvWeb.AgentDocs.ListDocs.people_list_types()

  def render(%{type: "profile"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.name}",
      doc.headline_markdown,
      blank_to_nil(doc.work_info),
      profile_facts(doc),
      section(
        gettext("Tags"),
        Enum.map(doc.tags, &entry_line("tags", &1))
      ),
      section(
        gettext("Experience"),
        Enum.map(doc.work_experiences, &entry_line("work_experiences", &1))
      ),
      section(
        gettext("Education"),
        Enum.map(doc.educations, &entry_line("educations", &1))
      ),
      section(
        gettext("Certificates & licenses"),
        Enum.map(doc.qualifications, &entry_line("qualifications", &1))
      ),
      section(
        gettext("Languages"),
        Enum.map(doc.languages, &entry_line("languages", &1))
      ),
      section(gettext("Links"), Enum.map(doc.links, &entry_line("links", &1))),
      section(gettext("Contact"), Enum.map(doc.emails, &entry_line("emails", &1))),
      section(
        gettext("Profiles"),
        Enum.map(doc.social_media, &entry_line("social_media_accounts", &1))
      ),
      section(
        gettext("Messengers"),
        Enum.map(doc.messengers, &entry_line("messengers", &1))
      ),
      section(gettext("Code"), Enum.map(doc.code_stats, &code_stats_block/1)),
      section(
        gettext("Phone Numbers"),
        Enum.map(doc.phone_numbers, &entry_line("phone_numbers", &1))
      ),
      section(gettext("Addresses"), Enum.map(doc.addresses, &entry_line("addresses", &1))),
      section(
        gettext("Posts (%{count} total)", count: doc.counts.posts),
        Enum.map(doc.posts, &post_line/1)
      )
    ]
    |> join_blocks()
  end

  # The profile section pages (VutuvWeb.AgentDocs.SectionDocs) carry their
  # section in the doc map, so no inventory is kept here.
  def render(%{section: section, entries: entries} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      gettext("%{count} total", count: doc.total),
      Enum.map_join(entries, "\n\n", &entry_line(section, &1))
    ]
    |> join_blocks()
  end

  def render(%{section: section, entry: entry} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      entry_line(section, entry)
    ]
    |> join_blocks()
  end

  def render(%{type: "post"} = doc) do
    author_link = "[#{md_text(doc.author.name)}](#{doc.author.url})"

    [
      frontmatter(doc),
      "# #{gettext("Post by %{name}", name: author_link)} · #{doc.published_on}",
      doc.in_reply_to && in_reply_to_line(doc.in_reply_to),
      doc.body_markdown,
      review_line(doc.review),
      tags_line(doc.tags),
      engagement_line(doc),
      section(gettext("Images"), Enum.map(doc.images, &image_line/1)),
      section("#{gettext("Replies")} (#{doc.reply_count})", Enum.map(doc.replies, &reply_block/1))
    ]
    |> join_blocks()
  end

  def render(%{type: "post_archive"} = doc) do
    author_link = "[#{md_text(doc.author.name)}](#{doc.author.url})"

    [
      frontmatter(doc),
      # doc.title already carries the period (PostDoc's period_suffix/1).
      "# #{doc.title}",
      gettext("%{count} posts by %{name}", count: doc.total, name: author_link) <>
        page_hint(doc.total, doc.posts, &paren_hint/1),
      Enum.map_join(doc.posts, "\n\n", &post_line/1)
    ]
    |> join_blocks()
  end

  # The signed-in member's personalized feed (VutuvWeb.AgentDocs.FeedDoc): a
  # page of timeline posts, same line shape as the archive (post_line/1).
  def render(%{type: "feed"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      feed_summary(doc, &paren_hint/1),
      Enum.map_join(doc.posts, "\n\n", &post_line/1)
    ]
    |> join_blocks()
  end

  def render(%{type: type} = doc) when type in @people_lists do
    [
      frontmatter(doc),
      "# #{doc.title}",
      gettext("%{count} total", count: doc.total) <>
        page_hint(doc.total, doc.people, &paren_hint/1),
      Enum.map_join(doc.people, "\n\n", &person_line/1)
    ]
    |> join_blocks()
  end

  # The per-tag endorser list is a people list with one extra fact per row:
  # when the endorsement was cast (ListDocs.build_tag_endorsers).
  def render(%{type: "tag_endorsers"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      gettext("%{count} total", count: doc.total) <>
        page_hint(doc.total, doc.people, &paren_hint/1),
      Enum.map_join(doc.people, "\n\n", &endorser_line/1)
    ]
    |> join_blocks()
  end

  def render(%{type: "tag"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.name}",
      doc.description,
      section(
        gettext("Most endorsed members"),
        Enum.map(doc.most_endorsed_users, &person_line/1)
      ),
      section(gettext("Posts with this tag"), Enum.map(doc.posts, &post_line/1)),
      tag_open_positions(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: "listing"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      doc.people
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {person, rank} -> "#{rank}. #{person_text(person)}" end)
    ]
    |> join_blocks()
  end

  # A verified organization page (issue #929).
  def render(%{type: "organization"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.name}",
      doc.description,
      [
        doc.kind && "- #{gettext("Kind")}: #{doc.kind}",
        doc.primary_domain && "- #{gettext("Verified via")}: #{doc.primary_domain}",
        also_known_as(doc),
        doc.website_url && "- #{gettext("Website")}: #{doc.website_url}",
        "- #{gettext("Address")}: #{doc.address_line}"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n"),
      organization_people(doc),
      organization_open_positions(doc)
    ]
    |> join_blocks()
  end

  # A job posting (/jobs/:slug).
  def render(%{type: "job_posting"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      [
        "- #{gettext("Employer")}: #{job_employer(doc.employer)}",
        "- #{gettext("Employment type")}: #{doc.employment_type}",
        "- #{gettext("Workplace")}: #{doc.workplace_type}",
        job_location(doc),
        doc.salary_line && "- #{gettext("Salary")}: #{doc.salary_line}",
        doc.posted_on && "- #{gettext("Posted")}: #{doc.posted_on}",
        doc.expires_on && "- #{gettext("Expires")}: #{doc.expires_on}"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n"),
      doc.description,
      job_tags(gettext("Required"), doc.required_tags),
      job_tags(gettext("Nice to have"), doc.nice_to_have_tags)
    ]
    |> join_blocks()
  end

  # The public job board (/jobs) — a listing of posting summaries.
  def render(%{type: "job_board"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      doc.description,
      Enum.map_join(doc.postings, "\n\n", &job_summary/1),
      doc.next && "[#{gettext("Next page")}](#{doc.next})"
    ]
    |> join_blocks()
  end

  # The verified-organization directory (/organizations).
  def render(%{type: "organizations"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      doc.description,
      Enum.map_join(doc.organizations, "\n", fn organization ->
        "- #{organization.name} (#{organization.kind}, #{organization.city}, #{organization.country}): #{organization.url}"
      end)
    ]
    |> join_blocks()
  end

  # The member directory overview (/members): the letter buckets with their
  # member counts and letter-page URLs.
  def render(%{type: "directory"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      doc.description,
      Enum.map_join(doc.letters, "\n\n", fn entry ->
        "- #{entry.letter} (#{entry.count}): #{entry.url}"
      end)
    ]
    |> join_blocks()
  end

  # The /ads offer page (VutuvWeb.AgentDocs.AdsDoc). The rules and the facts
  # form one loose bullet list (blank-line separated, like every other list),
  # not several one-item lists.
  def render(%{type: "advertising"} = doc) do
    bullets =
      doc.rules ++
        [
          "#{gettext("Community guidelines")}: #{doc.community_guidelines_url}",
          "#{gettext("Price")}: #{doc.price.display}",
          "#{gettext("Booking window")}: #{doc.booking_window.from} – #{doc.booking_window.to}",
          doc.next_available_day &&
            "#{gettext("Next available day")}: #{doc.next_available_day}",
          doc.booked_days != [] &&
            "#{gettext("Already booked")}: #{Enum.join(doc.booked_days, ", ")}"
        ]

    [
      frontmatter(doc),
      "# #{doc.title}",
      doc.description,
      bullets |> Enum.filter(&is_binary/1) |> Enum.map_join("\n\n", &("- " <> &1)),
      gettext("Book online (login required): %{url}", url: doc.booking_url)
    ]
    |> join_blocks()
  end

  # An organization's alternative names (issue #930), or nil when it has none.
  defp also_known_as(%{also_known_as: [_ | _] = names}),
    do: "- #{gettext("Also known as")}: #{Enum.join(names, ", ")}"

  defp also_known_as(_doc), do: nil

  # The People section (issue #931): members whose linked work experience is at
  # this organization, current members first, a "(former)" note on past ones.
  defp organization_people(%{people: [_ | _] = people}) do
    [
      "## #{gettext("People")}",
      Enum.map_join(people, "\n", fn person ->
        "- [#{person.name}](#{person.url})" <>
          if(person.title, do: " · #{person.title}", else: "") <>
          if(person.current, do: "", else: " (#{gettext("former")})")
      end)
    ]
    |> Enum.join("\n")
  end

  defp organization_people(_doc), do: nil

  defp job_employer(%{name: name, verified: verified, url: url}) do
    verified_mark = if verified, do: " (#{gettext("verified")})", else: ""
    if url, do: "[#{name}](#{url})#{verified_mark}", else: "#{name}#{verified_mark}"
  end

  defp job_location(%{location: %{city: city, country_name: country}}),
    do:
      "- #{gettext("Location")}: #{[city, country] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(", ")}"

  defp job_location(%{remote_countries: [_ | _] = countries}),
    do:
      "- #{gettext("Location")}: #{gettext("Remote")} (#{Enum.map_join(countries, ", ", & &1.name)})"

  defp job_location(_doc), do: "- #{gettext("Location")}: #{gettext("Remote")}"

  defp job_tags(_label, []), do: nil

  defp job_tags(label, tags) do
    "## #{label}\n" <> Enum.map_join(tags, "\n", &"- [#{&1.name}](#{&1.url})")
  end

  # One posting summary block on the board (/jobs) or an "Offene Stellen" section.
  defp job_summary(entry) do
    [
      "## [#{md_text(entry.title)}](#{entry.url})",
      "- #{gettext("Employer")}: #{job_employer(entry.employer)}",
      "- #{gettext("Employment type")}: #{entry.employment_type}",
      "- #{gettext("Workplace")}: #{entry.workplace_type}",
      job_location(entry),
      entry.salary_line && "- #{gettext("Salary")}: #{entry.salary_line}",
      entry.posted_on && "- #{gettext("Posted")}: #{entry.posted_on}",
      job_summary_tags(entry.tags)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp job_summary_tags([]), do: nil

  defp job_summary_tags(tags),
    do: "- #{gettext("Tags")}: " <> Enum.map_join(tags, ", ", &"[#{&1.name}](#{&1.url})")

  # The tag page's "Offene Stellen" section (#933): the postings carrying the
  # tag, then a link into the pre-filtered board.
  defp tag_open_positions(%{open_positions: [_ | _] = postings} = doc) do
    [
      "## #{gettext("Open positions")}",
      Enum.map_join(postings, "\n\n", &job_summary/1),
      doc[:jobs_url] && "[#{gettext("All jobs with this tag")}](#{doc.jobs_url})"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  defp tag_open_positions(_doc), do: nil

  # An organization's "Offene Stellen" section (#933), or nil when it has none.
  defp organization_open_positions(%{open_positions: [_ | _] = postings}) do
    "## #{gettext("Open positions")}\n\n" <> Enum.map_join(postings, "\n\n", &job_summary/1)
  end

  defp organization_open_positions(_doc), do: nil

  # The YAML frontmatter every Markdown doc starts with.
  defp frontmatter(doc) do
    [
      "---",
      "title: #{yaml(doc.title)}",
      doc.description && "description: #{yaml(doc.description)}",
      "url: #{doc.url}",
      # Identity/media metadata for the doc types that carry it (the profile):
      # the handle and avatar live only in the structured formats otherwise, so
      # the frontmatter is where the human formats surface them.
      doc[:username] && "username: #{yaml(doc.username)}",
      doc[:avatar_url] && "avatar_url: #{doc.avatar_url}",
      "type: #{doc.type}",
      "schema_version: #{doc.schema_version}",
      "generated_at: #{DateTime.to_iso8601(doc.generated_at)}",
      # The page's opt-outs, embedded in the document body itself so a reader
      # that never sees the Content-Signal / X-Robots-Tag headers (a saved
      # file, a pasted snippet) still carries the member's choice.
      doc.noindex && "noindex: true",
      doc.noai && "noai: true",
      "---"
    ]
    # Keep only the emitted lines: a conditional whose flag is off is `nil`
    # *or* `false` (`false && "noindex: true"`), and a bare `false` would
    # otherwise stringify into the YAML as a keyless value (issue #924).
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp profile_facts(doc) do
    [
      doc.verified && "- " <> gettext("Verified profile: yes"),
      doc.employment_status &&
        "- #{gettext("Employment status")}: #{User.employment_status_label(doc.employment_status)}",
      doc.desired_salary && "- " <> User.desired_salary_agent_line(doc.desired_salary),
      "- #{gettext("Member since")}: #{doc.member_since}",
      count_facts(doc.counts),
      doc.gender && "- #{gettext("Gender")}: #{User.gender_gettext(doc.gender)}",
      doc.birthdate && "- #{gettext("Birthday")}: #{doc.birthdate}",
      doc.birthday_month_day && "- #{gettext("Birthday")}: #{doc.birthday_month_day}",
      doc.age && "- #{gettext("Age")}: #{doc.age}"
    ]
    |> List.flatten()
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  # The follower / following / connection counts, each shown only when non-zero.
  defp count_facts(counts) do
    [
      counts.followers > 0 && "- #{gettext("Followers")}: #{counts.followers}",
      counts.following > 0 && "- #{gettext("Following")}: #{counts.following}",
      counts.connections > 0 && "- #{gettext("Connections")}: #{counts.connections}"
    ]
  end

  # One entry of a profile section — the same line on the profile page and
  # on the section's own index / show pages.
  # An honor tag is an admin-granted badge, not a peer-vouched skill, so it shows
  # the "honor tag" marker in place of the endorsement count.
  defp entry_line("tags", %{honor: true} = tag),
    do: "- [#{tag.name}](#{tag.url}) (#{gettext("honor tag")})"

  defp entry_line("tags", tag), do: "- [#{tag.name}](#{tag.url}) (#{endorsements_label(tag)})"
  defp entry_line("work_experiences", work), do: work_line(work)
  defp entry_line("educations", edu), do: education_line(edu)
  defp entry_line("qualifications", qualification), do: qualification_line(qualification)

  defp entry_line("languages", language),
    do: "- #{md_text(language.name)}: #{language.level}#{language_preferred_gloss(language)}"

  defp entry_line("links", link), do: link_line(link)
  defp entry_line("emails", email), do: "- #{email.type}: <#{email.value}>"
  defp entry_line("social_media_accounts", account), do: social_line(account)
  defp entry_line("messengers", messenger), do: messenger_line(messenger)
  defp entry_line("phone_numbers", phone), do: "- #{phone.type}: #{phone.value}"
  defp entry_line("addresses", address), do: "- " <> address_line(address)

  # One code-forge account of the profile's "Code" section (Vutuv.CodeStats):
  # the account line with its glanceable facts, then one indented line per top
  # repository. Returned as a single block (account line + tight nested repo
  # list) so the loose section join separates accounts, not an account from its
  # own repos.
  defp code_stats_block(account) do
    ["- #{account.provider}: #{account.url} (#{code_stats_facts(account)})"]
    |> Kernel.++(Enum.map(account.top_repos, &code_repo_line/1))
    |> Enum.join("\n")
  end

  defp code_repo_line(repo) do
    name = md_text(repo.name || "")
    linked = if repo.url, do: "[#{name}](#{repo.url})", else: name

    details =
      [
        repo.stars && "★ #{repo.stars}",
        repo.language,
        repo.description && md_text(repo.description)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" · ")

    if details == "", do: "  - #{linked}", else: "  - #{linked}: #{details}"
  end

  @doc """
  The facts inside a code-forge account line's parentheses — every fact the
  forge exposed, dot-separated. Shared with the text renderer so the two
  human-readable formats read the same.
  """
  def code_stats_facts(account) do
    [
      account.total_stars &&
        ngettext("%{count} star", "%{count} stars", account.total_stars),
      account.public_repos &&
        ngettext("%{count} repository", "%{count} repositories", account.public_repos),
      account.followers &&
        ngettext("%{count} follower", "%{count} followers", account.followers),
      account.member_since && gettext("since %{date}", date: account.member_since),
      code_dormant_fact(account),
      account.languages != [] && Enum.join(account.languages, ", ")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  # Mirrors the card: the last-activity date only appears once the account
  # has been quiet for over four weeks (a dormancy signal); JSON/XML always
  # carry the raw last_active_at.
  defp code_dormant_fact(account) do
    case CodeStats.dormant_since(account.last_active_at) do
      %Date{} = date -> gettext("last active %{date}", date: date)
      _ -> nil
    end
  end

  # Format-independent line content, shared with the text renderer (like
  # work_period/1 below).
  @doc false
  def endorsements_label(tag) do
    gettext("%{count} endorsements", count: tag.endorsements)
  end

  @doc """
  The trailing " (Preferred contact language)" gloss on the member's first
  language (issue #894), or `""` for the rest. Shared by both text renderers so
  the machine-readable intent reads the same in Markdown and plain text.
  """
  def language_preferred_gloss(%{preferred: true}),
    do: " (" <> gettext("Preferred contact language") <> ")"

  def language_preferred_gloss(_language), do: ""

  defp work_line(work) do
    period = work_period(work)
    kind_note = work_kind_note(work)
    description = Map.get(work, :description)
    page = Map.get(work, :organization_page)

    ["- ", Enum.join([work.title, work.organization] |> Enum.filter(& &1), " @ ")]
    |> Kernel.++(if page, do: [" ([#{page.name}](#{page.url}))"], else: [])
    |> Kernel.++(if kind_note, do: [" [#{kind_note}]"], else: [])
    |> Kernel.++(if period, do: [" (#{period})"], else: [])
    # The description is authored Markdown (#905), so it is emitted raw like the
    # title/organization above and a post's body — never md_text-escaped, which
    # would backslash a member's own `[label](url)` link into literal text (#927).
    |> Kernel.++(if description, do: [": #{description}"], else: [])
    |> Enum.join()
    |> indent_item_body()
  end

  # The non-default CV categories (issue #840) are called out on the entry
  # line, mirroring the HTML pages' category headings; a plain job stays
  # unmarked, like the page's jobs-only timeline. Shared with the text
  # renderer. Singular wording (one entry), the same msgids as the form's
  # category picker.
  @doc false
  def work_kind_note(work) do
    case Map.get(work, :kind) do
      "self_employed" -> gettext("Freelance / Self-employed")
      "internship" -> gettext("Internship")
      "volunteer" -> gettext("Volunteering & hobbies")
      "other" -> gettext("Other activities")
      _employment -> nil
    end
  end

  # Shares work_period/1 (the education entry carries the same :start / :end
  # keys). Degree + school lead, then the period, then field of study and
  # notes — both, like the HTML page shows them.
  defp education_line(edu) do
    period = work_period(edu)
    kind_note = education_kind_note(edu)
    title = Enum.join(Enum.filter([edu.degree, edu.school], & &1), ", ")

    # Field of study is a plain label emitted raw (like the title above); the
    # description is authored Markdown (#905), also raw, so a member's own
    # `[label](url)` link is not backslash-escaped into literal text (#927).
    detail =
      [edu.field_of_study, edu.description]
      |> Enum.filter(& &1)
      |> Enum.join(" — ")

    ["- ", title]
    |> Kernel.++(if kind_note, do: [" [#{kind_note}]"], else: [])
    |> Kernel.++(if period, do: [" (#{period})"], else: [])
    |> Kernel.++(if detail != "", do: [": #{detail}"], else: [])
    |> Enum.join()
    |> indent_item_body()
  end

  # The non-default education categories (issue #849) are called out on the
  # entry line, like work_kind_note/1 does for work experiences; a plain
  # degree stays unmarked. Shared with the text renderer.
  @doc false
  def education_kind_note(edu) do
    case Map.get(edu, :kind) do
      "apprenticeship" -> gettext("Vocational Training")
      "school" -> gettext("School Education")
      _university -> nil
    end
  end

  # A credential line: the name, then its facts, then the verification link as
  # an autolink. Blank facts drop out, so a bare-name entry is just "- Name".
  defp qualification_line(qualification) do
    facts = qualification_facts(qualification)

    base =
      if facts == "",
        do: "- #{md_text(qualification.name)}",
        else: "- #{md_text(qualification.name)}: #{md_text(facts)}"

    if qualification.url, do: base <> " <#{md_url(qualification.url)}>", else: base
  end

  # The credential's facts joined with middots — shared with the plain-text
  # renderer (like work_period/1) so the wording stays in one place. Returns
  # plain text; each renderer applies its own escaping. Kind, issuer, the
  # awarded and "valid until" dates and the credential id.
  @doc false
  def qualification_facts(qualification) do
    [
      qualification_kind_label(qualification.kind),
      qualification.issuer,
      qualification.awarded && gettext("awarded %{date}", date: qualification.awarded),
      qualification.expires && gettext("valid until %{date}", date: qualification.expires),
      qualification.credential_id && gettext("ID: %{id}", id: qualification.credential_id)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  @doc false
  def qualification_kind_label("license"), do: gettext("License")
  def qualification_kind_label(_certification), do: gettext("Certificate")

  @doc false
  def work_period(work) do
    case {work.start, work.end} do
      {nil, nil} -> nil
      {start, nil} -> "#{start} – #{gettext("today")}"
      {nil, ending} -> gettext("until %{date}", date: ending)
      {start, ending} -> "#{start} – #{ending}"
    end
  end

  defp link_line(%{description: nil, url: url} = link),
    do: "- <#{md_url(url)}>" <> verified_suffix(link)

  defp link_line(%{description: description, url: url} = link),
    do: "- [#{md_text(description)}](#{md_url(url)})" <> verified_suffix(link)

  # A verified link (proved to be the member's own webpage) carries the same
  # marker the profile's verified mark shows.
  defp verified_suffix(%{verified: true}), do: " (#{gettext("verified webpage")})"
  defp verified_suffix(_link), do: ""

  # The provider labels the link — the same [label](url) form as the Links
  # section. A provider without a canonical URL scheme (Snapchat) carries
  # only the account name, so there is no link to offer.
  defp social_line(%{provider: provider, url: "http" <> _ = url}),
    do: "- [#{provider}](#{md_url(url)})"

  defp social_line(%{provider: provider, url: value}), do: "- #{provider}: #{value}"

  # A messenger: the provider, its contact (a phone number or handle), and the
  # deep link that opens the app at that contact. Session has no web link, so it
  # shows the bare contact.
  defp messenger_line(%{provider: provider, contact: contact, url: "http" <> _ = url}),
    do: "- #{provider}: [#{contact}](#{md_url(url)})"

  defp messenger_line(%{provider: provider, contact: contact}),
    do: "- #{provider}: #{contact}"

  @doc false
  def address_line(address) do
    [
      address.description && "#{address.description}: ",
      [
        address.line_1,
        address.line_2,
        address.line_3,
        address.line_4,
        address.zip_code,
        address.city,
        address.state,
        address.country
      ]
      |> Enum.filter(&(&1 not in [nil, ""]))
      |> Enum.join(", ")
    ]
    |> Enum.filter(& &1)
    |> Enum.join()
  end

  defp post_line(post) do
    "- #{post.published_on}#{repost_suffix(post)}: [#{md_text(post.excerpt)}](#{post.url})"
  end

  # "(reposted by A)" for a lone reposter, "(reposted by A and 3 more)" once a
  # post carries a whole roster (the feed's follow-scoped reposters, newest
  # first). Falls back to the single `reposted_by` name for docs that carry
  # only that (the profile posts section).
  @doc false
  def repost_suffix(post) do
    case repost_names(post) do
      [] ->
        ""

      [name] ->
        " (#{gettext("reposted by %{name}", name: name)})"

      [name | rest] ->
        " (#{gettext("reposted by %{name} and %{count} more", name: name, count: length(rest))})"
    end
  end

  @doc false
  def repost_names(post) do
    cond do
      is_list(post[:reposters]) and post[:reposters] != [] -> post[:reposters]
      post[:reposted_by] -> [post[:reposted_by]]
      true -> []
    end
  end

  defp person_line(person), do: "- #{person_text(person)}"

  defp person_text(person) do
    "[#{md_text(person.name)}](#{person.url})" <>
      if(person.work_info, do: " — #{person.work_info}", else: "") <>
      tags_suffix(Map.get(person, :tags))
  end

  # The most-followed listing and the follower / following lists carry a
  # per-person tag summary; the connection and tag-endorser lists leave it nil
  # and the suffix is empty.
  defp tags_suffix(nil), do: ""

  defp tags_suffix(%{top: top, total: total}) do
    links = Enum.map_join(top, ", ", fn tag -> "[#{md_text(tag.name)}](#{tag.url})" end)
    " · #{gettext("Tags")}: #{links} (#{gettext("%{count} total", count: total)})"
  end

  defp endorser_line(person),
    do: "- #{person_text(person)}" <> endorsed_suffix(person.endorsed_at)

  @doc false
  # Shared with the plain-text renderer (VutuvWeb.AgentDocs.Text), like
  # work_period/1, address_line/1 and endorsements_label/1, so the translated
  # label and date format stay in one place.
  def endorsed_suffix(nil), do: ""

  def endorsed_suffix(at),
    do: " (" <> gettext("endorsed %{date}", date: Calendar.strftime(at, "%Y-%m-%d %H:%M")) <> ")"

  defp in_reply_to_line(%{author: nil}), do: "> " <> gettext("In reply to a deleted post.")

  defp in_reply_to_line(%{url: nil, author: author}),
    do: "> " <> gettext("In reply to a deleted post by %{name}.", name: author)

  defp in_reply_to_line(%{url: url, author: author}) do
    author_link = "[#{md_text(author)}](#{url})"
    "> " <> gettext("In reply to a post by %{name}.", name: author_link)
  end

  defp tags_line([]), do: nil
  defp tags_line(tags), do: "Tags: " <> Enum.map_join(tags, ", ", &"##{&1}")

  # The public engagement counters, mirroring the HTML action bar.
  @doc false
  def engagement_line(doc) do
    "#{gettext("Likes")}: #{doc.like_count} · #{gettext("Reposts")}: #{doc.repost_count} · " <>
      "#{gettext("Bookmarks")}: #{doc.bookmark_count}"
  end

  @doc """
  The post's review sidecar as one fact line (what the HTML review card
  shows), nil when the post carries none. Shared with the text renderer.
  """
  def review_line(nil), do: nil

  def review_line(review) do
    label =
      if review.kind == "movie", do: gettext("Film review"), else: gettext("Book review")

    isbn = if review.kind == "book" and review.identifier, do: "ISBN #{review.identifier}"

    details =
      [
        review.title,
        review.creator,
        review.year,
        PostComponents.review_medium_label(review.medium),
        isbn,
        review.link
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    "#{label}: #{details}"
  end

  # The pager / feed-summary / cursor hints are shared with the plain-text
  # renderer (VutuvWeb.AgentDocs.Text) like the other helpers above; only the
  # separator wrapping differs per format, so it is passed in as `wrap` (like
  # endorsed_suffix/1's fixed form): Markdown parenthesizes " (…)", plain text
  # dash-prefixes " — …". Keep both outputs byte-identical (a drift test guards them).
  defp paren_hint(inner), do: " (" <> inner <> ")"

  @doc false
  def page_hint(total, listed, wrap) when total > length(listed),
    do: wrap.(gettext("%{count} on this page, use ?page=N", count: length(listed)))

  def page_hint(_total, _listed, _wrap), do: ""

  @doc false
  def feed_summary(%{posts: []}, _wrap), do: gettext("Your feed is empty.")

  def feed_summary(doc, wrap) do
    gettext("%{count} posts on this page", count: length(doc.posts)) <> cursor_hint(doc, wrap)
  end

  # The feed is cursor-paginated: when older posts remain, point at the next
  # page via the signed, opaque `?cursor=` token (FeedDoc carries next_cursor).
  @doc false
  def cursor_hint(%{more: true, next_cursor: cursor}, wrap) when is_binary(cursor),
    do: wrap.(gettext("more posts available, append ?cursor=%{cursor}", cursor: cursor))

  def cursor_hint(_doc, _wrap), do: ""

  defp image_line(image) do
    alt = image.alt || "image"
    "- ![#{alt}](#{image_url(image)})"
  end

  # Shared with the plain-text renderer: prefer the feed-size variant, else any.
  @doc false
  def image_url(image), do: image.urls[:feed] || image.urls |> Map.values() |> List.first()

  defp reply_block(reply) do
    "### [#{md_text(reply.author)}](#{reply.url}) · #{reply.published_on}\n\n#{reply.body_markdown}"
  end

  defp section(_title, []), do: nil
  # A blank line between items (a "loose" CommonMark list) so every entry gets
  # the same vertical rhythm — the one a multi-paragraph entry already forces
  # anyway (issues #925/#926). Each `line` may itself be a multi-line block (a
  # code account with its nested repos, a reply with its body); those join in
  # tight internally and only the blocks are blank-line separated.
  defp section(title, lines), do: "## #{title}\n\n" <> Enum.join(lines, "\n\n")

  @doc false
  # Shared with the plain-text renderer, like the other helpers above.
  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value

  # A `- ` list item whose content (a work/education description) runs to
  # several paragraphs: the first line rides the marker, every later line is
  # indented two columns (the marker width) so the whole thing stays one list
  # item instead of the continuation paragraphs breaking out to the left margin
  # (issue #926). Blank lines stay truly empty (no trailing spaces), and CRLF /
  # CR line endings normalize to LF so the indent lands on real line breaks.
  defp indent_item_body(text) do
    case text
         |> String.replace("\r\n", "\n")
         |> String.replace("\r", "\n")
         |> String.split("\n") do
      [single] -> single
      [first | rest] -> Enum.join([first | Enum.map(rest, &indent_line/1)], "\n")
    end
  end

  defp indent_line(""), do: ""
  defp indent_line(line), do: "  " <> line

  # A YAML double-quoted scalar: escape backslash and double-quote, fold
  # newlines/tabs to spaces. (inspect/1 was wrong here — it emits `\#{` for a
  # literal `#{`, which is not a legal YAML escape, and truncates at 4096.)
  defp yaml(nil), do: ~s("")

  defp yaml(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace(["\n", "\r", "\t"], " ")

    ~s(") <> escaped <> ~s(")
  end

  # Escape the Markdown link-syntax characters in user-controlled link *text*
  # (names, excerpts), so a value like `x](http://evil)` cannot break out of
  # `[text](url)` and forge a link.
  defp md_text(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
  end

  # Percent-encode the characters that delimit a Markdown link *destination*
  # in a user-controlled URL, so a value like `http://x/) [evil](http://evil`
  # cannot close the `(...)` (or the `<...>` autolink) and forge a second link.
  # Real URLs survive — these chars are URL-encodable without changing meaning.
  defp md_url(value) do
    value
    |> to_string()
    |> String.replace("\\", "%5C")
    |> String.replace(" ", "%20")
    |> String.replace("\t", "%09")
    |> String.replace("\n", "%0A")
    |> String.replace("\r", "%0D")
    |> String.replace("(", "%28")
    |> String.replace(")", "%29")
    |> String.replace("<", "%3C")
    |> String.replace(">", "%3E")
    |> String.replace("\"", "%22")
  end

  defp join_blocks(blocks) do
    blocks
    |> List.flatten()
    |> Enum.filter(&(&1 not in [nil, ""]))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end
end
