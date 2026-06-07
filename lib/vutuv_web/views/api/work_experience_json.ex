defmodule VutuvWeb.Api.WorkExperienceJSON do
  @moduledoc false
  import VutuvWeb.Api.ApiHelpers

  @attributes ~w(organization title description start_month start_year end_month end_year)a

  def render("index.json", %{work_experiences: work_experiences}) do
    %{data: Enum.map(work_experiences, &work_experience/1)}
  end

  def render("show.json", %{work_experience: work_experience}) do
    %{data: work_experience(work_experience)}
  end

  def work_experience(work_experience) do
    %{id: work_experience.id, type: "work_experience"}
    |> put_attributes(work_experience, @attributes)
  end
end
