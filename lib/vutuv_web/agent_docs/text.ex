defmodule VutuvWeb.AgentDocs.Text do
  @moduledoc """
  Renders an agent doc (see `VutuvWeb.AgentDocs`) as plain text, hard-wrapped
  at 80 columns. Bullets wrap with a hanging indent; URLs are never broken
  (a long URL may exceed the limit rather than become unclickable).

  Labels render through Gettext in the process locale, which
  `VutuvWeb.AgentDocs.negotiate/2` sets from the `?lang=` query parameter
  (default English). The metadata footer stays English in every language.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias VutuvWeb.AgentDocs.Markdown

  @width 80

  # The per-user people lists (followers/following/connections) share one
  # clause; the set lives in ListDocs.
  @people_lists VutuvWeb.AgentDocs.ListDocs.people_list_types()

  def render(%{type: "profile"} = doc) do
    [
      heading(doc.name),
      doc.headline_markdown,
      Markdown.blank_to_nil(doc.work_info),
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
      section(gettext("Code"), Enum.flat_map(doc.code_stats, &code_stats_lines/1)),
      section(
        gettext("Phone Numbers"),
        Enum.map(doc.phone_numbers, &entry_line("phone_numbers", &1))
      ),
      section(gettext("Addresses"), Enum.map(doc.addresses, &entry_line("addresses", &1))),
      section(
        gettext("Posts (%{count} total)", count: doc.counts.posts),
        Enum.map(doc.posts, &post_lines/1)
      ),
      footer(doc)
    ]
    |> join_blocks()
  end

  # The profile section pages (VutuvWeb.AgentDocs.SectionDocs) carry their
  # section in the doc map, so no inventory is kept here.
  def render(%{section: section, entries: entries} = doc) do
    [
      heading(doc.title),
      gettext("%{count} total", count: doc.total),
      Enum.map(entries, &entry_line(section, &1)),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{section: section, entry: entry} = doc) do
    [
      heading(doc.title),
      entry_line(section, entry),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: "post"} = doc) do
    [
      heading("#{gettext("Post by %{name}", name: doc.author.name)} · #{doc.published_on}"),
      doc.in_reply_to && in_reply_to_line(doc.in_reply_to),
      doc.body_markdown,
      tags_line(doc.tags),
      Markdown.engagement_line(doc),
      section(gettext("Images"), Enum.map(doc.images, &image_lines/1)),
      section(
        "#{gettext("Replies")} (#{doc.reply_count})",
        Enum.map(doc.replies, &reply_lines/1)
      ),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: "post_archive"} = doc) do
    [
      heading(doc.title),
      gettext("%{count} posts by %{name}", count: doc.total, name: doc.author.name) <>
        " (#{doc.author.url})" <> Markdown.page_hint(doc.total, doc.posts, &dash_hint/1),
      Enum.map(doc.posts, &post_lines/1),
      footer(doc)
    ]
    |> join_blocks()
  end

  # The signed-in member's personalized feed (VutuvWeb.AgentDocs.FeedDoc): a
  # page of timeline posts, same line shape as the archive (post_lines/1).
  def render(%{type: "feed"} = doc) do
    [
      heading(doc.title),
      Markdown.feed_summary(doc, &dash_hint/1),
      Enum.map(doc.posts, &post_lines/1),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: type} = doc) when type in @people_lists do
    [
      heading(doc.title),
      gettext("%{count} total", count: doc.total) <>
        Markdown.page_hint(doc.total, doc.people, &dash_hint/1),
      Enum.map(doc.people, &person_line/1),
      footer(doc)
    ]
    |> join_blocks()
  end

  # The per-tag endorser list: a people list whose rows also carry the
  # endorsement timestamp (ListDocs.build_tag_endorsers).
  def render(%{type: "tag_endorsers"} = doc) do
    [
      heading(doc.title),
      gettext("%{count} total", count: doc.total) <>
        Markdown.page_hint(doc.total, doc.people, &dash_hint/1),
      Enum.map(doc.people, &endorser_lines/1),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: "tag"} = doc) do
    [
      heading(doc.name),
      doc.description,
      section(
        gettext("Most endorsed members"),
        Enum.map(doc.most_endorsed_users, &person_line/1)
      ),
      tag_open_positions(doc),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: "listing"} = doc) do
    [
      heading(doc.title),
      doc.people
      |> Enum.with_index(1)
      |> Enum.map(fn {person, rank} -> person_line(person, "#{rank}. ") end),
      footer(doc)
    ]
    |> join_blocks()
  end

  # A verified organization page (issue #929).
  def render(%{type: "organization"} = doc) do
    [
      heading(doc.name),
      doc.description,
      [
        doc.kind && "- #{gettext("Kind")}: #{doc.kind}",
        doc.primary_domain && "- #{gettext("Verified via")}: #{doc.primary_domain}",
        also_known_as(doc),
        doc.website_url && "- #{gettext("Website")}: #{doc.website_url}",
        "- #{gettext("Address")}: #{doc.address_line}"
      ]
      |> Enum.filter(&is_binary/1),
      organization_people(doc),
      organization_open_positions(doc),
      footer(doc)
    ]
    |> join_blocks()
  end

  # A job posting (/jobs/:slug).
  def render(%{type: "job_posting"} = doc) do
    [
      heading(doc.title),
      [
        "- #{gettext("Employer")}: #{job_employer(doc.employer)}",
        "- #{gettext("Employment type")}: #{doc.employment_type}",
        "- #{gettext("Workplace")}: #{doc.workplace_type}",
        job_location(doc),
        doc.salary_line && "- #{gettext("Salary")}: #{doc.salary_line}",
        doc.posted_on && "- #{gettext("Posted")}: #{doc.posted_on}",
        doc.expires_on && "- #{gettext("Expires")}: #{doc.expires_on}"
      ]
      |> Enum.filter(&is_binary/1),
      doc.description,
      job_tags(gettext("Required"), doc.required_tags),
      job_tags(gettext("Nice to have"), doc.nice_to_have_tags),
      footer(doc)
    ]
    |> join_blocks()
  end

  # The public job board (/jobs) — a listing of posting summaries.
  def render(%{type: "job_board"} = doc) do
    [
      heading(doc.title),
      doc.description,
      Enum.map_join(doc.postings, "\n\n", &job_summary/1),
      doc.next && gettext("Next page: %{url}", url: doc.next),
      footer(doc)
    ]
    |> join_blocks()
  end

  # The verified-organization directory (/organizations).
  def render(%{type: "organizations"} = doc) do
    [
      heading(doc.title),
      doc.description,
      Enum.map(doc.organizations, fn organization ->
        "- #{organization.name} (#{organization.kind}, #{organization.city}, #{organization.country}): #{organization.url}"
      end),
      footer(doc)
    ]
    |> join_blocks()
  end

  # The member directory overview (/members): the letter buckets with their
  # member counts and letter-page URLs.
  def render(%{type: "directory"} = doc) do
    [
      heading(doc.title),
      doc.description,
      Enum.map(doc.letters, fn entry -> "- #{entry.letter} (#{entry.count}): #{entry.url}" end),
      footer(doc)
    ]
    |> join_blocks()
  end

  # The /ads offer page (VutuvWeb.AgentDocs.AdsDoc).
  def render(%{type: "advertising"} = doc) do
    [
      heading(doc.title),
      doc.description,
      Enum.map(doc.rules, &("- " <> &1)),
      "- #{gettext("Community guidelines")}: #{doc.community_guidelines_url}",
      "- #{gettext("Price")}: #{doc.price.display}",
      "- #{gettext("Booking window")}: #{doc.booking_window.from} – #{doc.booking_window.to}",
      doc.next_available_day &&
        "- #{gettext("Next available day")}: #{doc.next_available_day}",
      if(doc.booked_days != [],
        do: "- #{gettext("Already booked")}: #{Enum.join(doc.booked_days, ", ")}"
      ),
      gettext("Book online (login required): %{url}", url: doc.booking_url),
      footer(doc)
    ]
    |> join_blocks()
  end

  # Hard-wraps `text` at @width columns. Existing newlines are kept;
  # wrapped continuation lines get `indent`. A single word longer than the
  # width (a URL) stays on its own line unbroken.
  defp wrap(text, indent) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &wrap_line(&1, indent))
  end

  # A line that already fits is returned verbatim, so the renderer's own
  # 2-space continuation indents (and any meaningful whitespace in post
  # bodies) survive. Only over-long lines are reflowed, and the first
  # wrapped segment keeps the line's original leading indentation.
  defp wrap_line(line, indent) do
    if String.length(line) <= @width do
      line
    else
      leading = leading_whitespace(line)

      line
      |> String.split(" ", trim: true)
      |> Enum.reduce([], &add_word(&1, &2, indent))
      |> Enum.reverse()
      |> List.update_at(0, &(leading <> &1))
      |> Enum.join("\n")
    end
  end

  defp leading_whitespace(line) do
    trimmed = String.trim_leading(line)
    String.slice(line, 0, String.length(line) - String.length(trimmed))
  end

  defp add_word(word, [], _indent), do: [word]

  defp add_word(word, [current | done], indent) do
    if String.length(current) + 1 + String.length(word) <= @width do
      [current <> " " <> word | done]
    else
      [indent <> word, current | done]
    end
  end

  defp heading(text) do
    text <> "\n" <> String.duplicate("=", min(String.length(text), @width))
  end

  # An organization's alternative names (issue #930), or nil when it has none.
  defp also_known_as(%{also_known_as: [_ | _] = names}),
    do: "- #{gettext("Also known as")}: #{Enum.join(names, ", ")}"

  defp also_known_as(_doc), do: nil

  # The People section (issue #931): the linked members the HTML page lists.
  defp organization_people(%{people: [_ | _] = people}) do
    [
      gettext("People") <> ":"
      | Enum.map(people, fn person ->
          "- #{person.name} (#{person.url})" <>
            if(person.title, do: " · #{person.title}", else: "") <>
            if(person.current, do: "", else: " (#{gettext("former")})")
        end)
    ]
    |> Enum.join("\n")
  end

  defp organization_people(_doc), do: nil

  defp job_employer(%{name: name, verified: verified, url: url}) do
    verified_mark = if verified, do: " (#{gettext("verified")})", else: ""
    if url, do: "#{name}#{verified_mark} — #{url}", else: "#{name}#{verified_mark}"
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
    ["#{label}:", Enum.map(tags, &"- #{&1.name} (#{&1.url})")]
  end

  # One posting summary block on the board (/jobs) or an "Offene Stellen" section.
  defp job_summary(entry) do
    [
      "#{entry.title} (#{entry.url})",
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
    do: "- #{gettext("Tags")}: " <> Enum.map_join(tags, ", ", &"#{&1.name} (#{&1.url})")

  # The tag page's "Offene Stellen" section (#933).
  defp tag_open_positions(%{open_positions: [_ | _] = postings} = doc) do
    [
      String.upcase(gettext("Open positions")),
      Enum.map_join(postings, "\n\n", &job_summary/1),
      doc[:jobs_url] && gettext("All jobs with this tag: %{url}", url: doc.jobs_url)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  defp tag_open_positions(_doc), do: nil

  # An organization's "Offene Stellen" section (#933), or nil when it has none.
  defp organization_open_positions(%{open_positions: [_ | _] = postings}) do
    String.upcase(gettext("Open positions")) <>
      "\n\n" <> Enum.map_join(postings, "\n\n", &job_summary/1)
  end

  defp organization_open_positions(_doc), do: nil

  defp profile_facts(doc) do
    [
      doc.verified && gettext("Verified profile: yes"),
      doc.employment_status &&
        "#{gettext("Employment status")}: #{User.employment_status_label(doc.employment_status)}",
      doc.desired_salary && User.desired_salary_agent_line(doc.desired_salary),
      "#{gettext("Member since")}: #{doc.member_since}",
      count_facts(doc.counts),
      doc.gender && "#{gettext("Gender")}: #{User.gender_gettext(doc.gender)}",
      doc.birthdate && "#{gettext("Birthday")}: #{doc.birthdate}",
      doc.age && "#{gettext("Age")}: #{doc.age}"
    ]
    |> List.flatten()
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  # The follower / following / connection counts, each shown only when non-zero.
  defp count_facts(counts) do
    [
      counts.followers > 0 && "#{gettext("Followers")}: #{counts.followers}",
      counts.following > 0 && "#{gettext("Following")}: #{counts.following}",
      counts.connections > 0 && "#{gettext("Connections")}: #{counts.connections}"
    ]
  end

  # One entry of a profile section — the same line on the profile page and
  # on the section's own index / show pages.
  defp entry_line("tags", %{honor: true} = tag),
    do: "* #{tag.name} (#{gettext("honor tag")})"

  defp entry_line("tags", tag), do: "* #{tag.name} (#{Markdown.endorsements_label(tag)})"
  defp entry_line("work_experiences", work), do: work_line(work)
  defp entry_line("educations", edu), do: education_line(edu)
  defp entry_line("qualifications", qualification), do: qualification_line(qualification)

  defp entry_line("languages", language),
    do: "* #{language.name}: #{language.level}#{Markdown.language_preferred_gloss(language)}"

  defp entry_line("links", link), do: link_line(link)
  defp entry_line("emails", email), do: "* #{email.type}: #{email.value}"
  defp entry_line("social_media_accounts", account), do: "* #{account.provider}: #{account.url}"
  defp entry_line("phone_numbers", phone), do: "* #{phone.type}: #{phone.value}"
  defp entry_line("addresses", address), do: "* " <> Markdown.address_line(address)

  # One code-forge account of the profile's "Code" section (Vutuv.CodeStats):
  # the account line with its facts (shared wording with the Markdown
  # renderer), then one indented line per top repository.
  defp code_stats_lines(account) do
    ["* #{account.provider}: #{account.url} (#{Markdown.code_stats_facts(account)})"] ++
      Enum.map(account.top_repos, &code_repo_line/1)
  end

  defp code_repo_line(repo) do
    details =
      [
        repo.url,
        repo.stars && "★ #{repo.stars}",
        repo.language,
        repo.description
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" · ")

    if details == "", do: "  * #{repo.name}", else: "  * #{repo.name}: #{details}"
  end

  defp work_line(work) do
    period = Markdown.work_period(work)
    kind_note = Markdown.work_kind_note(work)
    line = Enum.join([work.title, work.organization] |> Enum.filter(& &1), " @ ")
    description = Map.get(work, :description)
    page = Map.get(work, :organization_page)

    "* " <>
      line <>
      if(page, do: " (#{page.name}: #{page.url})", else: "") <>
      if(kind_note, do: " [#{kind_note}]", else: "") <>
      if(period, do: " (#{period})", else: "") <>
      if description, do: ": #{description}", else: ""
  end

  defp education_line(edu) do
    period = Markdown.work_period(edu)
    kind_note = Markdown.education_kind_note(edu)
    title = Enum.join(Enum.filter([edu.degree, edu.school], & &1), ", ")
    detail = [edu.field_of_study, edu.description] |> Enum.filter(& &1) |> Enum.join(" — ")

    "* " <>
      title <>
      if(kind_note, do: " [#{kind_note}]", else: "") <>
      if(period, do: " (#{period})", else: "") <>
      if(detail != "", do: ": #{detail}", else: "")
  end

  defp qualification_line(qualification) do
    facts = Markdown.qualification_facts(qualification)

    "* " <>
      qualification.name <>
      if(facts == "", do: "", else: ": #{facts}") <>
      if(qualification.url, do: " #{qualification.url}", else: "")
  end

  defp link_line(%{description: nil, url: url} = link), do: "* #{url}" <> verified_suffix(link)

  defp link_line(%{description: description, url: url} = link),
    do: "* #{description}: #{url}" <> verified_suffix(link)

  defp verified_suffix(%{verified: true}), do: " (#{gettext("verified webpage")})"
  defp verified_suffix(_link), do: ""

  defp post_lines(post) do
    "* #{post.published_on}#{Markdown.repost_suffix(post)}: #{post.excerpt}\n  #{post.url}"
  end

  defp person_line(person, prefix \\ "* ") do
    work = if person.work_info, do: " — #{person.work_info}", else: ""
    "#{prefix}#{person.name}#{work}#{tags_suffix(Map.get(person, :tags))}\n  #{person.url}"
  end

  # The most-followed listing and the follower / following lists carry a
  # per-person tag summary; the plain names go inline (the structured links live
  # in the JSON/XML formats). The connection and tag-endorser lists leave it nil.
  defp tags_suffix(nil), do: ""

  defp tags_suffix(%{top: top, total: total}) do
    names = Enum.map_join(top, ", ", & &1.name)
    " · #{gettext("Tags")}: #{names} (#{gettext("%{count} total", count: total)})"
  end

  defp endorser_lines(person) do
    work = if person.work_info, do: " — #{person.work_info}", else: ""
    "* #{person.name}#{work}#{Markdown.endorsed_suffix(person.endorsed_at)}\n  #{person.url}"
  end

  defp in_reply_to_line(%{author: nil}), do: gettext("In reply to a deleted post.")

  defp in_reply_to_line(%{url: nil, author: author}),
    do: gettext("In reply to a deleted post by %{name}.", name: author)

  defp in_reply_to_line(%{url: url, author: author}),
    do: gettext("In reply to a post by %{name}.", name: author) <> " #{url}"

  defp tags_line([]), do: nil
  defp tags_line(tags), do: "Tags: " <> Enum.join(tags, ", ")

  # The pager / feed-summary / cursor hints live once in the Markdown renderer
  # (shared like work_period/1 etc.); plain text differs only in the separator,
  # a leading " — " with no closing bracket, passed in as `wrap`.
  defp dash_hint(inner), do: " — " <> inner

  defp image_lines(image) do
    alt = image.alt || "image"
    "* #{alt}\n  #{Markdown.image_url(image)}"
  end

  defp reply_lines(reply) do
    "* #{reply.author} · #{reply.published_on} · #{reply.url}\n" <>
      indent_block(reply.body_markdown)
  end

  defp indent_block(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("  " <> &1))
  end

  defp section(_title, []), do: nil

  defp section(title, lines) do
    upcased = String.upcase(title)

    upcased <>
      "\n" <>
      String.duplicate("-", min(String.length(upcased), @width)) <>
      "\n" <> Enum.join(lines, "\n")
  end

  defp footer(doc) do
    # Mirrors the Markdown frontmatter: the handle and avatar live only in the
    # structured formats otherwise, so the text footer (this format's metadata
    # zone) surfaces them for the doc types that carry them (the profile).
    [
      "--",
      "vutuv agent document · type: #{doc.type} · schema_version: #{doc.schema_version}",
      doc[:username] && "username: #{doc.username}",
      doc[:avatar_url] && "avatar_url: #{doc.avatar_url}",
      "generated_at: #{DateTime.to_iso8601(doc.generated_at)}",
      "canonical: #{doc.url}",
      # The page's opt-outs, embedded like the Markdown frontmatter does, so
      # a saved copy still carries the member's choice without the headers.
      doc.noindex && "noindex: true",
      doc.noai && "noai: true"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp join_blocks(blocks) do
    blocks
    |> List.flatten()
    |> Enum.filter(&(&1 not in [nil, ""]))
    |> Enum.map_join("\n\n", &wrap(&1, "  "))
    |> Kernel.<>("\n")
  end
end
