defmodule VutuvWeb.ConnectionHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  def time_ago_in_words(datetime) do
    now = NaiveDateTime.utc_now()
    diff = NaiveDateTime.diff(now, datetime)

    cond do
      diff < 60 -> "less than a minute"
      diff < 3600 -> "#{div(diff, 60)} minutes"
      diff < 86_400 -> "#{div(diff, 3600)} hours"
      diff < 2_592_000 -> "#{div(diff, 86_400)} days"
      diff < 31_536_000 -> "#{div(diff, 2_592_000)} months"
      true -> "#{div(diff, 31_536_000)} years"
    end
  end

  embed_templates("../templates/connection/*")
end
