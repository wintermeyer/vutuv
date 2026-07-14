defmodule VutuvWeb.SavedSearchAlertHTML do
  @moduledoc false
  use VutuvWeb, :html

  embed_templates("../templates/saved_search_alert/*")

  @doc "A short label for the saved search on the confirm/done pages."
  def search_label(saved_search) do
    case Vutuv.SavedSearches.summary_segments(saved_search) do
      [] -> kind_label(saved_search.kind)
      segments -> kind_label(saved_search.kind) <> ": " <> Enum.join(segments, " · ")
    end
  end

  defp kind_label(:jobs), do: gettext("job search")
  defp kind_label(:people), do: gettext("people search")
end
