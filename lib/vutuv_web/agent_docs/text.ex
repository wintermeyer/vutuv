defmodule VutuvWeb.AgentDocs.Text do
  @moduledoc """
  Renders an agent doc (see `VutuvWeb.AgentDocs`) as plain text, hard-wrapped
  at 80 columns. Bullets wrap with a hanging indent; URLs are never broken
  (a long URL may exceed the limit rather than become unclickable).
  """

  @width 80

  def render(%{type: "profile"} = doc) do
    [
      heading(doc.name),
      doc.headline_markdown,
      blank_to_nil(doc.work_info),
      profile_facts(doc),
      section(
        "Skills & endorsements",
        Enum.map(doc.tags, &"* #{&1.name} (#{&1.endorsements} endorsements)")
      ),
      section("Experience", Enum.map(doc.work_experiences, &work_line/1)),
      section("Links", Enum.map(doc.links, &link_line/1)),
      section("Contact", Enum.map(doc.emails, &("* " <> &1))),
      section("Social media", Enum.map(doc.social_media, &"* #{&1.provider}: #{&1.url}")),
      section("Phone numbers", Enum.map(doc.phone_numbers, &"* #{&1.type}: #{&1.value}")),
      section("Addresses", Enum.map(doc.addresses, &("* " <> address_line(&1)))),
      section("Posts (#{doc.counts.posts} total)", Enum.map(doc.posts, &post_lines/1)),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: "post"} = doc) do
    [
      heading("Post by #{doc.author.name} · #{doc.published_on}"),
      doc.in_reply_to && in_reply_to_line(doc.in_reply_to),
      doc.body_markdown,
      tags_line(doc.tags),
      section("Images", Enum.map(doc.images, &image_lines/1)),
      section("Replies (#{doc.reply_count})", Enum.map(doc.replies, &reply_lines/1)),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: "post_archive"} = doc) do
    [
      heading(doc.title),
      "#{doc.total} posts by #{doc.author.name} (#{doc.author.url})" <>
        if(doc.total > length(doc.posts),
          do: " — #{length(doc.posts)} on this page, use ?page=N",
          else: ""
        ),
      Enum.map(doc.posts, &post_lines/1),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: type} = doc) when type in ["followers", "following"] do
    [
      heading(doc.title),
      "#{doc.total} total" <>
        if(doc.total > length(doc.people),
          do: " — #{length(doc.people)} on this page, use ?page=N",
          else: ""
        ),
      Enum.map(doc.people, &person_line/1),
      footer(doc)
    ]
    |> join_blocks()
  end

  def render(%{type: "tag"} = doc) do
    [
      heading(doc.name),
      doc.description,
      section("Most endorsed members", Enum.map(doc.most_endorsed_users, &person_line/1)),
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

  @doc """
  Hard-wraps `text` at #{@width} columns. Existing newlines are kept;
  wrapped continuation lines get `indent`. A single word longer than the
  width (a URL) stays on its own line unbroken.
  """
  def wrap(text, indent \\ "") do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &wrap_line(&1, indent))
  end

  defp wrap_line(line, indent) do
    line
    |> String.split(" ", trim: true)
    |> Enum.reduce([], &add_word(&1, &2, indent))
    |> Enum.reverse()
    |> Enum.join("\n")
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

  defp profile_facts(doc) do
    counts = doc.counts

    [
      doc.verified && "Verified profile: yes",
      "Member since: #{doc.member_since}",
      counts.followers > 0 && "Followers: #{counts.followers}",
      counts.following > 0 && "Following: #{counts.following}",
      counts.connections > 0 && "Connections: #{counts.connections}",
      doc.gender && "Gender: #{doc.gender}",
      doc.birthdate && "Birthday: #{doc.birthdate}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp work_line(work) do
    period =
      case {work.start, work.end} do
        {nil, nil} -> nil
        {start, nil} -> "#{start} – today"
        {nil, ending} -> "until #{ending}"
        {start, ending} -> "#{start} – #{ending}"
      end

    line = Enum.join([work.title, work.organization] |> Enum.filter(& &1), " @ ")
    "* " <> line <> if period, do: " (#{period})", else: ""
  end

  defp link_line(%{description: nil, url: url}), do: "* #{url}"
  defp link_line(%{description: description, url: url}), do: "* #{description}: #{url}"

  defp address_line(address) do
    [
      address.description && "#{address.description}: ",
      [
        address.line_1,
        address.line_2,
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

  defp post_lines(post) do
    reposted = if post[:reposted_by], do: " (reposted by #{post.reposted_by})", else: ""
    "* #{post.published_on}#{reposted}: #{post.excerpt}\n  #{post.url}"
  end

  defp person_line(person, prefix \\ "* ") do
    work = if person.work_info, do: " — #{person.work_info}", else: ""
    "#{prefix}#{person.name}#{work}\n  #{person.url}"
  end

  defp in_reply_to_line(%{author: nil}), do: "In reply to a deleted post."

  defp in_reply_to_line(%{url: nil, author: author}),
    do: "In reply to a deleted post by #{author}."

  defp in_reply_to_line(%{url: url, author: author}),
    do: "In reply to a post by #{author}: #{url}"

  defp tags_line([]), do: nil
  defp tags_line(tags), do: "Tags: " <> Enum.join(tags, ", ")

  defp image_lines(image) do
    alt = image.alt || "image"
    "* #{alt}\n  #{image.urls[:feed] || image.urls |> Map.values() |> List.first()}"
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
    "--\n" <>
      "vutuv agent document · type: #{doc.type} · schema_version: #{doc.schema_version}\n" <>
      "generated_at: #{DateTime.to_iso8601(doc.generated_at)}\n" <>
      "canonical: #{doc.url}"
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp join_blocks(blocks) do
    blocks
    |> List.flatten()
    |> Enum.filter(&(&1 not in [nil, ""]))
    |> Enum.map_join("\n\n", &wrap(&1, "  "))
    |> Kernel.<>("\n")
  end
end
