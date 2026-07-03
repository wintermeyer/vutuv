defmodule VutuvWeb.AgentDocs.ListDocs do
  @moduledoc """
  The people-list pages as data maps for the agent formats: the follower /
  following lists (`/:slug/followers`, `/:slug/following`), the connections
  list (`/:slug/connections`), the tag page (`/tags/:slug`), the
  most-followed listing (`/listings/most_followed_users`) and the member
  directory (`/members` + `/members/:letter`).

  The follow and connection lists are noindexed in HTML (the `NoIndex`
  plug + robots.txt), so their docs carry `noindex: true` plus
  `noai: true` and answer with an all-no `Content-Signal`. The connections doc is the anonymous view:
  accepted connections only, never the owner's pending requests. Changed
  what one of these pages shows? Update the matching builder — the drift
  test (`agent_docs_drift_test.exs`) reminds you.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.UserHelpers

  alias Vutuv.Tags.UserTag

  # The noindexed per-user people lists; the renderers derive their dispatch
  # from people_list_types/0, so this is the one place the set lives. (The
  # per-tag endorser list is a people list too, but it carries a per-row
  # endorsement timestamp, so the Markdown / text renderers give it its own
  # clause rather than the bare follow-list one.)
  @sides [:followers, :following, :connections]

  @doc "The doc types of the per-user follow lists (for the renderers' dispatch)."
  def people_list_types, do: Enum.map(@sides, &Atom.to_string/1)

  @doc """
  One page of `/:slug/followers`, `/:slug/following` or `/:slug/connections`
  (for connections: the accepted ones — the public part of the page).
  """
  def build_follow_list(user, side, people, total) when side in @sides do
    path = "/#{user.username}/#{side}"
    name = UserHelpers.full_name(user)

    label =
      case side do
        :followers -> gettext("Followers of %{name}", name: name)
        :following -> gettext("People %{name} follows", name: name)
        :connections -> gettext("Connections of %{name}", name: name)
      end

    # Every caller built the same `work_information_map(people, 45)`, so the doc
    # owns it: one home for the list's per-row work line.
    work_info_by_id = UserHelpers.work_information_map(people, 45)

    # The follower / following lists surface each member's four most popular tags
    # (like the most-followed listing and the HTML rows); the connection list's
    # HTML shows none, so it stays tag-free here too.
    tags_by_id =
      if side in [:followers, :following],
        do: UserHelpers.tag_summary_map(people, 4),
        else: %{}

    AgentDocs.doc_meta(Atom.to_string(side), path, noindex: true, noai: true)
    |> Map.merge(%{
      title: label,
      description: label,
      user: AgentDocs.person_ref(user),
      total: total,
      people: Enum.map(people, &person_entry(&1, work_info_by_id, tags_by_id))
    })
  end

  @doc "The tag page: description plus the most endorsed members."
  def build_tag(tag, recommended_users, work_info_by_id) do
    AgentDocs.doc_meta("tag", "/tags/#{tag.slug}")
    |> Map.merge(%{
      title: tag.name,
      description: tag.description,
      name: tag.name,
      slug: tag.slug,
      most_endorsed_users: Enum.map(recommended_users, &person_entry(&1, work_info_by_id))
    })
  end

  @doc """
  The per-tag endorser list (`/:slug/tags/:tag/endorsers`): everyone who
  currently endorses `user` for `user_tag`'s tag, plus a `tag` reference for
  context. Each person entry carries `endorsed_at` (the endorsement's
  `inserted_at`, a naive UTC `NaiveDateTime`) from `endorsed_at_by_id`, so the
  agent formats show when each vote was cast — the same fact the HTML page's
  per-row timestamp shows.
  """
  def build_tag_endorsers(user, user_tag, people, total, work_info_by_id, endorsed_at_by_id) do
    name = UserHelpers.full_name(user)
    tag = user_tag.tag
    label = gettext("Members who endorsed %{name} for %{tag}", name: name, tag: tag.name)
    path = "/#{user.username}/tags/#{tag.slug}/endorsers"

    AgentDocs.doc_meta("tag_endorsers", path, noindex: true, noai: true)
    |> Map.merge(%{
      title: label,
      description: label,
      user: AgentDocs.person_ref(user),
      tag: %{
        name: UserTag.name(user_tag),
        slug: tag.slug,
        url: AgentDocs.abs_url("/tags/#{tag.slug}")
      },
      total: total,
      people:
        Enum.map(people, fn endorser ->
          endorser
          |> person_entry(work_info_by_id)
          |> Map.put(:endorsed_at, Map.get(endorsed_at_by_id, endorser.id))
        end)
    })
  end

  @doc "The /listings/most_followed_users page."
  def build_most_followed(users, work_info_by_id, tags_by_id \\ %{}) do
    AgentDocs.doc_meta("listing", "/listings/most_followed_users")
    |> Map.merge(%{
      title: gettext("Most followed members"),
      description:
        gettext(
          "We haven't yet figured out the best way to help everyone discover other interesting vutuv users. So for now, this page simply lists the 1,000 users with the most followers."
        ),
      people: Enum.map(users, &person_entry(&1, work_info_by_id, tags_by_id))
    })
  end

  @doc """
  The member-directory overview (`/members`): one entry per letter bucket
  with its member count and letter-page URL. Zero-count letters ride along
  so the doc mirrors the HTML page's full A-Z strip.
  """
  def build_directory_index(entries, total) do
    AgentDocs.doc_meta("directory", "/members")
    |> Map.merge(%{
      title: gettext("Member directory"),
      description:
        gettext(
          "All members who allow search engines to index their profile, grouped by the first letter of their last name."
        ),
      total: total,
      letters:
        Enum.map(entries, fn %{letter: letter, count: count} ->
          %{letter: letter, count: count, url: AgentDocs.abs_url("/members/#{letter}")}
        end)
    })
  end

  @doc """
  One page of a member-directory letter (`/members/:letter`). Same doc type
  as the most-followed listing — it is a plain people list; the directory
  context lives in the title and the canonical URL.
  """
  def build_directory_letter(letter, label, people, total, work_info_by_id, tags_by_id) do
    title = gettext("Members: %{letter}", letter: label)

    AgentDocs.doc_meta("listing", "/members/#{letter}")
    |> Map.merge(%{
      title: title,
      description:
        gettext("The member directory's %{letter} page, sorted by last name.", letter: label),
      letter: letter,
      total: total,
      people: Enum.map(people, &person_entry(&1, work_info_by_id, tags_by_id))
    })
  end

  defp person_entry(user, work_info_by_id, tags_by_id \\ %{}) do
    user
    |> AgentDocs.person_ref()
    |> Map.put(:work_info, presence(work_info_by_id[user.id]))
    |> maybe_put_tags(tags_by_id[user.id])
  end

  # The most-followed listing and the follower / following lists pass a tag
  # summary; the connection and tag-endorser lists leave it nil so their person
  # entries are unchanged.
  defp maybe_put_tags(person, nil), do: person
  defp maybe_put_tags(person, %{top: []}), do: person

  defp maybe_put_tags(person, %{top: top, total: total}) do
    Map.put(person, :tags, %{
      total: total,
      top:
        Enum.map(top, fn user_tag ->
          %{name: user_tag.tag.name, url: AgentDocs.abs_url("/tags/" <> user_tag.tag.slug)}
        end)
    })
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
