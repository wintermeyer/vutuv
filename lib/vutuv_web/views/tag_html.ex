defmodule VutuvWeb.TagHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers
  import VutuvWeb.JobComponents, only: [job_card: 1]
  import VutuvWeb.PostComponents, only: [post_card: 1]
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
    |> Map.put(:work_string_length, 45)
    |> Map.put(:work_info_by_id, work_information_map(users, 45))
    |> Map.put(:following_by_id, following_map(assigns[:current_user], users))
  end

  embed_templates("../templates/tag/*")
end
