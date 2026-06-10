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

  def render(%{type: "profile"} = doc) do
    [
      frontmatter(doc),
      "# #{doc.name}#{if doc.verified, do: " ✓"}",
      doc.headline_markdown,
      blank_to_nil(doc.work_info),
      profile_facts(doc),
      section(
        gettext("Skills & endorsements"),
        Enum.map(doc.tags, &"- [#{&1.name}](#{&1.url}) (#{endorsements_label(&1)})")
      ),
      section(gettext("Experience"), Enum.map(doc.work_experiences, &work_line/1)),
      section(gettext("Links"), Enum.map(doc.links, &link_line/1)),
      section(gettext("Contact"), Enum.map(doc.emails, &"- <#{&1}>")),
      section(
        gettext("Social Media"),
        Enum.map(doc.social_media, &"- #{&1.provider}: #{&1.url}")
      ),
      section(
        gettext("Phone Numbers"),
        Enum.map(doc.phone_numbers, &"- #{&1.type}: #{&1.value}")
      ),
      section(gettext("Addresses"), Enum.map(doc.addresses, &("- " <> address_line(&1)))),
      section(
        gettext("Posts (%{count} total)", count: doc.counts.posts),
        Enum.map(doc.posts, &post_line/1)
      )
    ]
    |> join_blocks()
  end

  def render(%{type: "post"} = doc) do
    author_link = "[#{doc.author.name}](#{doc.author.url})"

    [
      frontmatter(doc),
      "# #{gettext("Post by %{name}", name: author_link)} · #{doc.published_on}",
      doc.in_reply_to && in_reply_to_line(doc.in_reply_to),
      doc.body_markdown,
      tags_line(doc.tags),
      section(gettext("Images"), Enum.map(doc.images, &image_line/1)),
      section("#{gettext("Replies")} (#{doc.reply_count})", Enum.map(doc.replies, &reply_block/1))
    ]
    |> join_blocks()
  end

  def render(%{type: "post_archive"} = doc) do
    author_link = "[#{doc.author.name}](#{doc.author.url})"

    [
      frontmatter(doc),
      "# #{doc.title}",
      gettext("%{count} posts by %{name}", count: doc.total, name: author_link) <>
        if(doc.period, do: " · #{doc.period}", else: "") <>
        page_hint(doc.total, doc.posts),
      Enum.map_join(doc.posts, "\n", &post_line/1)
    ]
    |> join_blocks()
  end

  def render(%{type: type} = doc) when type in ["followers", "following"] do
    [
      frontmatter(doc),
      "# #{doc.title}",
      gettext("%{count} total", count: doc.total) <> page_hint(doc.total, doc.people),
      Enum.map_join(doc.people, "\n", &person_line/1)
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

  # The YAML frontmatter every Markdown doc starts with.
  defp frontmatter(doc) do
    [
      "---",
      "title: #{yaml(doc.title)}",
      doc.description && "description: #{yaml(doc.description)}",
      "url: #{doc.url}",
      "type: #{doc.type}",
      "schema_version: #{doc.schema_version}",
      "generated_at: #{DateTime.to_iso8601(doc.generated_at)}",
      "---"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp profile_facts(doc) do
    counts = doc.counts

    [
      "- #{gettext("Member since")}: #{doc.member_since}",
      counts.followers > 0 && "- #{gettext("Followers")}: #{counts.followers}",
      counts.following > 0 && "- #{gettext("Following")}: #{counts.following}",
      counts.connections > 0 && "- #{gettext("Connections")}: #{counts.connections}",
      doc.gender && "- #{gettext("Gender")}: #{User.gender_gettext(doc.gender)}",
      doc.birthdate && "- #{gettext("Birthday")}: #{doc.birthdate}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  # Format-independent line content, shared with the text renderer (like
  # work_period/1 below).
  @doc false
  def endorsements_label(tag) do
    gettext("%{count} endorsements", count: tag.endorsements)
  end

  defp work_line(work) do
    period = work_period(work)

    ["- ", Enum.join([work.title, work.organization] |> Enum.filter(& &1), " @ ")]
    |> Kernel.++(if period, do: [" (#{period})"], else: [])
    |> Enum.join()
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

  defp link_line(%{description: nil, url: url}), do: "- <#{url}>"
  defp link_line(%{description: description, url: url}), do: "- [#{description}](#{url})"

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
    reposted =
      if post[:reposted_by],
        do: " (#{gettext("reposted by %{name}", name: post.reposted_by)})",
        else: ""

    "- #{post.published_on}#{reposted}: [#{post.excerpt}](#{post.url})"
  end

  defp person_line(person), do: "- #{person_text(person)}"

  defp person_text(person) do
    "[#{person.name}](#{person.url})" <>
      if person.work_info, do: " — #{person.work_info}", else: ""
  end

  defp in_reply_to_line(%{author: nil}), do: "> " <> gettext("In reply to a deleted post.")

  defp in_reply_to_line(%{url: nil, author: author}),
    do: "> " <> gettext("In reply to a deleted post by %{name}.", name: author)

  defp in_reply_to_line(%{url: url, author: author}) do
    author_link = "[#{author}](#{url})"
    "> " <> gettext("In reply to a post by %{name}.", name: author_link)
  end

  defp tags_line([]), do: nil
  defp tags_line(tags), do: "Tags: " <> Enum.map_join(tags, ", ", &"##{&1}")

  defp page_hint(total, listed) when total > length(listed) do
    " (" <> gettext("%{count} on this page, use ?page=N", count: length(listed)) <> ")"
  end

  defp page_hint(_total, _listed), do: ""

  defp image_line(image) do
    alt = image.alt || "image"
    "- ![#{alt}](#{image.urls[:feed] || image.urls |> Map.values() |> List.first()})"
  end

  defp reply_block(reply) do
    "### [#{reply.author}](#{reply.url}) · #{reply.published_on}\n\n#{reply.body_markdown}"
  end

  defp section(_title, []), do: nil
  defp section(title, lines), do: "## #{title}\n\n" <> Enum.join(lines, "\n")

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Strings that may contain anything go into YAML double-quoted; Elixir's
  # inspect produces a compatible escape set for the characters we meet here.
  defp yaml(nil), do: ~s("")
  defp yaml(value), do: value |> to_string() |> String.replace("\n", " ") |> inspect()

  defp join_blocks(blocks) do
    blocks
    |> List.flatten()
    |> Enum.filter(&(&1 not in [nil, ""]))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end
end
