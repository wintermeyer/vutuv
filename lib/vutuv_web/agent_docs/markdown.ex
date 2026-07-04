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
      section(gettext("Links"), Enum.map(doc.links, &entry_line("links", &1))),
      section(gettext("Contact"), Enum.map(doc.emails, &entry_line("emails", &1))),
      section(
        gettext("Social Media"),
        Enum.map(doc.social_media, &entry_line("social_media_accounts", &1))
      ),
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
      Enum.map_join(entries, "\n", &entry_line(section, &1))
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
        page_hint(doc.total, doc.posts),
      Enum.map_join(doc.posts, "\n", &post_line/1)
    ]
    |> join_blocks()
  end

  # The signed-in member's personalized feed (VutuvWeb.AgentDocs.FeedDoc): a
  # page of timeline posts, same line shape as the archive (post_line/1).
  def render(%{type: "feed"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      feed_summary(doc),
      Enum.map_join(doc.posts, "\n", &post_line/1)
    ]
    |> join_blocks()
  end

  def render(%{type: type} = doc) when type in @people_lists do
    [
      frontmatter(doc),
      "# #{doc.title}",
      gettext("%{count} total", count: doc.total) <> page_hint(doc.total, doc.people),
      Enum.map_join(doc.people, "\n", &person_line/1)
    ]
    |> join_blocks()
  end

  # The per-tag endorser list is a people list with one extra fact per row:
  # when the endorsement was cast (ListDocs.build_tag_endorsers).
  def render(%{type: "tag_endorsers"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      gettext("%{count} total", count: doc.total) <> page_hint(doc.total, doc.people),
      Enum.map_join(doc.people, "\n", &endorser_line/1)
    ]
    |> join_blocks()
  end

  def render(%{type: "tag"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.name}",
      doc.description,
      section(gettext("Most endorsed members"), Enum.map(doc.most_endorsed_users, &person_line/1))
    ]
    |> join_blocks()
  end

  def render(%{type: "listing"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      doc.people
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {person, rank} -> "#{rank}. #{person_text(person)}" end)
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
      Enum.map_join(doc.letters, "\n", fn entry ->
        "- #{entry.letter} (#{entry.count}): #{entry.url}"
      end)
    ]
    |> join_blocks()
  end

  # The /ads offer page (VutuvWeb.AgentDocs.AdsDoc).
  def render(%{type: "advertising"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.title}",
      doc.description,
      Enum.map_join(doc.rules, "\n", &("- " <> &1)),
      "- #{gettext("Price")}: #{doc.price.display}",
      "- #{gettext("Booking window")}: #{doc.booking_window.from} – #{doc.booking_window.to}",
      doc.next_available_day &&
        "- #{gettext("Next available day")}: #{doc.next_available_day}",
      if(doc.booked_days != [],
        do: "- #{gettext("Already booked")}: #{Enum.join(doc.booked_days, ", ")}"
      ),
      gettext("Book online (login required): %{url}", url: doc.booking_url)
    ]
    |> join_blocks()
  end

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
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp profile_facts(doc) do
    counts = doc.counts

    [
      doc.verified && "- " <> gettext("Verified profile: yes"),
      "- #{gettext("Member since")}: #{doc.member_since}",
      counts.followers > 0 && "- #{gettext("Followers")}: #{counts.followers}",
      counts.following > 0 && "- #{gettext("Following")}: #{counts.following}",
      counts.connections > 0 && "- #{gettext("Connections")}: #{counts.connections}",
      doc.gender && "- #{gettext("Gender")}: #{User.gender_gettext(doc.gender)}",
      doc.birthdate && "- #{gettext("Birthday")}: #{doc.birthdate}",
      doc.age && "- #{gettext("Age")}: #{doc.age}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  # One entry of a profile section — the same line on the profile page and
  # on the section's own index / show pages.
  defp entry_line("tags", tag), do: "- [#{tag.name}](#{tag.url}) (#{endorsements_label(tag)})"
  defp entry_line("work_experiences", work), do: work_line(work)
  defp entry_line("educations", edu), do: education_line(edu)
  defp entry_line("links", link), do: link_line(link)
  defp entry_line("emails", email), do: "- #{email.type}: <#{email.value}>"
  defp entry_line("social_media_accounts", account), do: social_line(account)
  defp entry_line("phone_numbers", phone), do: "- #{phone.type}: #{phone.value}"
  defp entry_line("addresses", address), do: "- " <> address_line(address)

  # Format-independent line content, shared with the text renderer (like
  # work_period/1 below).
  @doc false
  def endorsements_label(tag) do
    gettext("%{count} endorsements", count: tag.endorsements)
  end

  defp work_line(work) do
    period = work_period(work)
    kind_note = work_kind_note(work)
    description = Map.get(work, :description)

    ["- ", Enum.join([work.title, work.organization] |> Enum.filter(& &1), " @ ")]
    |> Kernel.++(if kind_note, do: [" [#{kind_note}]"], else: [])
    |> Kernel.++(if period, do: [" (#{period})"], else: [])
    |> Kernel.++(if description, do: [": #{md_text(description)}"], else: [])
    |> Enum.join()
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
      "volunteer" -> gettext("Volunteer position")
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

    detail =
      [edu.field_of_study, edu.description]
      |> Enum.filter(& &1)
      |> Enum.map_join(" — ", &md_text/1)

    ["- ", title]
    |> Kernel.++(if kind_note, do: [" [#{kind_note}]"], else: [])
    |> Kernel.++(if period, do: [" (#{period})"], else: [])
    |> Kernel.++(if detail != "", do: [": #{detail}"], else: [])
    |> Enum.join()
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

  @doc false
  def work_period(work) do
    case {work.start, work.end} do
      {nil, nil} -> nil
      {start, nil} -> "#{start} – #{gettext("today")}"
      {nil, ending} -> gettext("until %{date}", date: ending)
      {start, ending} -> "#{start} – #{ending}"
    end
  end

  defp link_line(%{description: nil, url: url}), do: "- <#{md_url(url)}>"

  defp link_line(%{description: description, url: url}),
    do: "- [#{md_text(description)}](#{md_url(url)})"

  # The provider labels the link — the same [label](url) form as the Links
  # section. A provider without a canonical URL scheme (Snapchat) carries
  # only the account name, so there is no link to offer.
  defp social_line(%{provider: provider, url: "http" <> _ = url}),
    do: "- [#{provider}](#{md_url(url)})"

  defp social_line(%{provider: provider, url: value}), do: "- #{provider}: #{value}"

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
  defp repost_suffix(post) do
    case repost_names(post) do
      [] ->
        ""

      [name] ->
        " (#{gettext("reposted by %{name}", name: name)})"

      [name | rest] ->
        " (#{gettext("reposted by %{name} and %{count} more", name: name, count: length(rest))})"
    end
  end

  defp repost_names(post) do
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
  defp engagement_line(doc) do
    "#{gettext("Likes")}: #{doc.like_count} · #{gettext("Reposts")}: #{doc.repost_count} · " <>
      "#{gettext("Bookmarks")}: #{doc.bookmark_count}"
  end

  defp page_hint(total, listed) when total > length(listed) do
    " (" <> gettext("%{count} on this page, use ?page=N", count: length(listed)) <> ")"
  end

  defp page_hint(_total, _listed), do: ""

  defp feed_summary(%{posts: []}), do: gettext("Your feed is empty.")

  defp feed_summary(doc) do
    gettext("%{count} posts on this page", count: length(doc.posts)) <> cursor_hint(doc)
  end

  # The feed is cursor-paginated: when older posts remain, point at the next
  # page via the signed, opaque `?cursor=` token (FeedDoc carries next_cursor).
  defp cursor_hint(%{more: true, next_cursor: cursor}) when is_binary(cursor) do
    " (" <> gettext("more posts available, append ?cursor=%{cursor}", cursor: cursor) <> ")"
  end

  defp cursor_hint(_doc), do: ""

  defp image_line(image) do
    alt = image.alt || "image"
    "- ![#{alt}](#{image.urls[:feed] || image.urls |> Map.values() |> List.first()})"
  end

  defp reply_block(reply) do
    "### [#{md_text(reply.author)}](#{reply.url}) · #{reply.published_on}\n\n#{reply.body_markdown}"
  end

  defp section(_title, []), do: nil
  defp section(title, lines), do: "## #{title}\n\n" <> Enum.join(lines, "\n")

  @doc false
  # Shared with the plain-text renderer, like the other helpers above.
  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value

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
