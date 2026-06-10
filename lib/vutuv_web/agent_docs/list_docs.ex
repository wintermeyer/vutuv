defmodule VutuvWeb.AgentDocs.ListDocs do
  @moduledoc """
  The people-list pages as data maps for the agent formats: the follower /
  following lists (`/:slug/followers`, `/:slug/following`), the connections
  list (`/:slug/connections`), the tag page (`/tags/:slug`) and the
  most-followed listing (`/listings/most_followed_users`).

  The follow and connection lists are noindexed in HTML (the `NoIndex`
  plug + robots.txt), so their docs carry `noindex: true` and answer with
  an all-no `Content-Signal`. The connections doc is the anonymous view:
  accepted connections only, never the owner's pending requests. Changed
  what one of these pages shows? Update the matching builder — the drift
  test (`agent_docs_drift_test.exs`) reminds you.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias VutuvWeb.AgentDocs
  alias VutuvWeb.UserHelpers

  # The noindexed per-user people lists; the renderers derive their dispatch
  # from people_list_types/0, so this is the one place the set lives.
  @sides [:followers, :following, :connections]

  @doc "The doc types of the per-user people lists (for the renderers' dispatch)."
  def people_list_types, do: Enum.map(@sides, &Atom.to_string/1)

  @doc """
  One page of `/:slug/followers`, `/:slug/following` or `/:slug/connections`
  (for connections: the accepted ones — the public part of the page).
  """
  def build_follow_list(user, side, people, total, work_info_by_id) when side in @sides do
    path = "/#{user.active_slug}/#{side}"
    name = UserHelpers.full_name(user)

    label =
      case side do
        :followers -> gettext("Followers of %{name}", name: name)
        :following -> gettext("People %{name} follows", name: name)
        :connections -> gettext("Connections of %{name}", name: name)
      end

    AgentDocs.doc_meta(Atom.to_string(side), path, noindex: true)
    |> Map.merge(%{
      title: label,
      description: label,
      user: AgentDocs.person_ref(user),
      total: total,
      people: Enum.map(people, &person_entry(&1, work_info_by_id))
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

  @doc "The /listings/most_followed_users page."
  def build_most_followed(users, work_info_by_id) do
    AgentDocs.doc_meta("listing", "/listings/most_followed_users")
    |> Map.merge(%{
      title: gettext("Most followed members"),
      description: gettext("The most followed vutuv members"),
      people: Enum.map(users, &person_entry(&1, work_info_by_id))
    })
  end

  defp person_entry(user, work_info_by_id) do
    user
    |> AgentDocs.person_ref()
    |> Map.put(:work_info, presence(work_info_by_id[user.id]))
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
