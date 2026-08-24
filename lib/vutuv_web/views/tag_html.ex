defmodule VutuvWeb.TagHTML do
  @moduledoc false
  use VutuvWeb, :html

  import VutuvWeb.FediverseComponents, only: [follow_us_from_elsewhere: 1]
  import VutuvWeb.UserHelpers
  import VutuvWeb.JobComponents, only: [job_card: 1]
  alias Vutuv.Tags.Tag

  defp update_assigns(assigns) do
    related_users = Tag.related_users(assigns[:tag], assigns[:current_user])
    recommended_users = Tag.recommended_users(assigns[:tag])

    # Batch the per-row work-info / follow lookups for both lists (one query
    # each), so card_list runs no per-user queries — same scheme as the
    # listing pages and the profile rail.
    users = related_users ++ recommended_users

    assigns
    |> Map.put(:related_users, related_users)
    |> Map.put(:recommended_users, recommended_users)
    |> Map.put(:tag_aliases, Tag.aliases_of(assigns[:tag]))
    # One reading of "has a description", so the card's heading and the test
    # that decides whether the card exists at all cannot disagree over a blank
    # string somebody saved in the admin form.
    |> Map.put(:tag_description, presence(assigns[:tag].description))
    |> Map.put(:work_string_length, 45)
    |> Map.put(:work_info_by_id, work_information_map(users, 45))
    |> Map.put(:following_by_id, following_map(assigns[:current_user], users))
  end

  defp presence(nil), do: nil

  defp presence(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      _ -> text
    end
  end

  # Whether the front-matter card has anything in it at all: the admin-written
  # description, the alternative names, and the two people lists. `description`
  # is editable only under `/admin/tags/:slug`, and most tags carry none and no
  # endorsed members either — so on most tag pages all four are empty and the
  # card would be a white box saying nothing, directly above the posts the
  # reader came for. Then it does not render.
  defp tag_front_matter?(assigns) do
    not is_nil(assigns.tag_description) or assigns.tag_aliases != [] or
      assigns.related_users != [] or assigns.recommended_users != []
  end

  @doc """
  The other names this topic answers to, as one comma-separated line.

  A reader who typed `ROR` and landed on Ruby on Rails has to be able to see
  why, so the page says so plainly (issue #1338) rather than leaving the
  redirect unexplained. The names are the alias rows' own, in the casing their
  first writer used.
  """
  def alias_names(aliases), do: Enum.map_join(aliases, ", ", & &1.name)

  embed_templates("../templates/tag/*")
end
