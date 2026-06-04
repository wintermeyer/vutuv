defmodule VutuvWeb.TagHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers
  alias Vutuv.Tags.Tag

  defp update_assigns(assigns) do
    assigns
    |> Map.put(
      :related_users,
      Tag.related_users(assigns[:tag], assigns[:current_user])
    )
    |> Map.put(:recommended_users, Tag.recommended_users(assigns[:tag]))
    |> Map.put(:work_string_length, 45)
  end

  embed_templates("../templates/tag/*")
end
