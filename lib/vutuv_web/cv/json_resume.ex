defmodule VutuvWeb.CV.JsonResume do
  @moduledoc """
  The CV in the JSON Resume schema (<https://jsonresume.org>) — the open,
  machine-readable résumé format, so members can feed their vutuv profile
  into the JSON Resume theme/tooling ecosystem.

  Category mapping: employment, self-employment, internships **and** other
  activities become `work` entries (the schema has no separate section for
  them), volunteering becomes `volunteer`, tags become `skills`, spoken
  languages become `languages`, the profile links become `basics.profiles`
  and the address becomes `basics.location`. Keys with no value are dropped,
  as the schema expects.
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
          "url" => cv.profile_url,
          "location" => location(cv.address_lines),
          "profiles" => profiles(cv.links)
        }),
      "work" => work(cv.work_groups),
      "volunteer" => volunteer(cv.work_groups),
      "education" => Enum.map(cv.educations, &education/1),
      "skills" => Enum.map(cv.skills, &%{"name" => &1.name}),
      "languages" => Enum.map(cv.languages, &%{"language" => &1.name, "fluency" => &1.fluency})
    }
    |> Enum.reject(fn {_key, value} -> value == [] end)
    |> Map.new()
    |> Jason.encode!(pretty: true)
  end

  defp work(work_groups) do
    for {kind, entries} <- work_groups,
        kind in ["employment", "self_employed", "internship", "other"],
        entry <- entries do
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

  # The CV carries the address only as ready-to-print lines, so the whole
  # address lands in the schema's single `location.address` string rather
  # than being split back into city/region/postalCode fields.
  defp location([]), do: nil
  defp location(lines), do: %{"address" => Enum.join(lines, ", ")}

  # Each profile link becomes a `profiles` entry (the link's description is
  # its network name); a link without a URL is dropped, and no links at all
  # drops the whole key.
  defp profiles(links) do
    entries =
      for %{url: url} = link <- links, is_binary(url) and url != "" do
        compact(%{"network" => link.label, "url" => url})
      end

    if entries == [], do: nil, else: entries
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
