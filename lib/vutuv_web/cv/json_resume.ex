defmodule VutuvWeb.CV.JsonResume do
  @moduledoc """
  The CV in the JSON Resume schema (<https://jsonresume.org>) — the open,
  machine-readable résumé format, so members can feed their vutuv profile
  into the JSON Resume theme/tooling ecosystem.

  Category mapping: employment **and** internships become `work` entries
  (the schema has no internship section), volunteering becomes `volunteer`,
  tags become `skills`. Keys with no value are dropped, as the schema
  expects.
  """

  @schema_url "https://raw.githubusercontent.com/jsonresume/resume-schema/v1.0.0/schema.json"

  def render(cv) do
    %{
      "$schema" => @schema_url,
      "basics" =>
        compact(%{
          "name" => cv.name,
          "label" => cv.headline,
          "email" => cv.email,
          "phone" => cv.phone,
          "url" => cv.profile_url
        }),
      "work" => work(cv.work_groups),
      "volunteer" => volunteer(cv.work_groups),
      "education" => Enum.map(cv.educations, &education/1),
      "skills" => Enum.map(cv.skills, &%{"name" => &1})
    }
    |> Enum.reject(fn {_key, value} -> value == [] end)
    |> Map.new()
    |> Jason.encode!(pretty: true)
  end

  defp work(work_groups) do
    for {kind, entries} <- work_groups, kind in ["employment", "internship"], entry <- entries do
      compact(%{
        "name" => entry.organization,
        "position" => entry.title,
        "startDate" => entry.start,
        "endDate" => entry.end,
        "summary" => entry.description
      })
    end
  end

  defp volunteer(work_groups) do
    for {kind, entries} <- work_groups, kind == "volunteer", entry <- entries do
      compact(%{
        "organization" => entry.organization,
        "position" => entry.title,
        "startDate" => entry.start,
        "endDate" => entry.end,
        "summary" => entry.description
      })
    end
  end

  defp education(entry) do
    compact(%{
      "institution" => entry.school,
      "studyType" => entry.degree,
      "area" => entry.field_of_study,
      "startDate" => entry.start,
      "endDate" => entry.end
    })
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
