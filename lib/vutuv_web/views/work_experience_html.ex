defmodule VutuvWeb.WorkExperienceHTML do
  @moduledoc false
  use VutuvWeb, :html
  import VutuvWeb.UserHelpers

  def format_duration(start_month, start_year, end_month, end_year) do
    case {start_month, start_year, end_month, end_year} do
      {nil, nil, end_month, end_year} ->
        display_date(end_month, end_year)

      _ ->
        [display_date(start_month, start_year), " - ", display_date(end_month, end_year)]
    end
  end

  def display_date(month, year) do
    case {month, year} do
      {nil, year} when is_integer(year) ->
        Integer.to_string(year)

      {month, year} when is_integer(month) and is_integer(year) ->
        [Integer.to_string(month), "/", Integer.to_string(year)]

      _ ->
        gettext("Present")
    end
  end

  embed_templates("../templates/work_experience/*")
end
