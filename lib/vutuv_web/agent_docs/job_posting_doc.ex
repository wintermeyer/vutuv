defmodule VutuvWeb.AgentDocs.JobPostingDoc do
  @moduledoc """
  The agent-format doc builder for a job posting (issue #932): the anonymous
  public view of `/jobs/:slug` as Markdown / plain text / JSON / XML. Every
  public fact the HTML detail page shows must appear here too
  (`agent_docs_drift_test.exs` enforces it). Only a live, `geo?` posting reaches
  this builder — the controller 404s the rest.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Countries
  alias Vutuv.Jobs
  alias Vutuv.Jobs.JobPosting
  alias Vutuv.Organizations
  alias Vutuv.Salary
  alias VutuvWeb.AgentDocs

  def build_show(%JobPosting{} = posting) do
    AgentDocs.doc_meta("job_posting", "/jobs/#{posting.slug}",
      noindex: not posting.seo?,
      noai: not posting.geo?
    )
    |> Map.merge(%{
      title: posting.title,
      description: posting.description,
      employer: employer(posting),
      employment_type: JobPosting.employment_type_label(posting.employment_type),
      workplace_type: JobPosting.workplace_type_label(posting.workplace_type),
      location: location(posting),
      remote_countries: remote_countries(posting),
      salary_line: salary_line(posting),
      salary: JobPosting.salary_fields(posting),
      language: posting.language,
      posted_on: AgentDocs.iso_date(posting.first_published_at),
      expires_on: posting.expires_on && Date.to_iso8601(posting.expires_on),
      required_tags: tag_entries(posting, :required),
      nice_to_have_tags: tag_entries(posting, :nice_to_have),
      apply: apply_entry(posting)
    })
  end

  @doc """
  The authenticated `/api/2.0/jobs/:id` detail doc: the public show doc plus the
  fields an owner's tooling needs — the id, the effective lifecycle status and
  its dates, the raw visibility, the street address and resolved coordinates.
  Reuses `build_show/1` so the shared fields never drift from the public page.
  """
  def api_show(%JobPosting{} = posting) do
    build_show(posting)
    |> Map.merge(%{
      id: posting.id,
      status: Atom.to_string(Jobs.effective_status(posting)),
      visibility: Atom.to_string(posting.visibility),
      street_address: posting.street_address,
      coordinates: coordinates(posting),
      closed_at: AgentDocs.iso_date(posting.closed_at),
      close_reason: posting.close_reason && Atom.to_string(posting.close_reason)
    })
  end

  @doc "A board listing entry for the API — `summary/1` plus the posting id."
  def api_summary(%JobPosting{} = posting) do
    Map.put(summary(posting), :id, posting.id)
  end

  defp coordinates(%JobPosting{lat: lat, lon: lon}) when is_float(lat) and is_float(lon),
    do: %{lat: lat, lon: lon}

  defp coordinates(_), do: nil

  @doc """
  The compact card entry of a posting for a **listing** doc — the board
  (`/jobs`) and the organization / tag "Offene Stellen" sections. Carries the
  same structured location, salary and tag fields as the detail doc so agents
  can filter client-side, minus the description / apply target.
  """
  def summary(%JobPosting{} = posting) do
    %{
      title: posting.title,
      url: AgentDocs.abs_url("/jobs/#{posting.slug}"),
      employer: employer(posting),
      employment_type: JobPosting.employment_type_label(posting.employment_type),
      workplace_type: JobPosting.workplace_type_label(posting.workplace_type),
      location: location(posting),
      remote_countries: remote_countries(posting),
      salary_line: salary_line(posting),
      salary: JobPosting.salary_fields(posting),
      posted_on: AgentDocs.iso_date(posting.first_published_at),
      tags: tag_entries(posting, :required) ++ tag_entries(posting, :nice_to_have)
    }
  end

  defp employer(%JobPosting{organization: %Organizations.Organization{} = org}) do
    %{
      name: org.name,
      verified: true,
      url: AgentDocs.abs_url(Organizations.canonical_path(org))
    }
  end

  defp employer(%JobPosting{} = posting) do
    %{name: JobPosting.employer_name(posting), verified: false, url: poster_url(posting)}
  end

  defp poster_url(%JobPosting{user: user}), do: AgentDocs.abs_url("/" <> user.username)

  defp location(%JobPosting{workplace_type: :remote}), do: nil

  defp location(%JobPosting{} = posting) do
    %{
      zip_code: posting.zip_code,
      city: posting.city,
      country: posting.country,
      country_name: Countries.name(posting.country)
    }
  end

  defp remote_countries(%JobPosting{workplace_type: :remote} = posting) do
    Enum.map(posting.remote_countries, &%{code: &1, name: Countries.name(&1)})
  end

  defp remote_countries(_), do: []

  # A ready-to-print human line, so the md/txt renderers stay simple.
  defp salary_line(%JobPosting{employment_type: :volunteer}), do: gettext("Voluntary")
  defp salary_line(%JobPosting{salary_min: nil}), do: nil

  defp salary_line(%JobPosting{} = posting) do
    Salary.range_label(
      posting.salary_min,
      posting.salary_max,
      posting.salary_currency,
      posting.salary_period
    )
  end

  defp tag_entries(%JobPosting{} = posting, priority) do
    posting
    |> Jobs.tags_of(priority)
    |> Enum.map(&%{name: &1.name, slug: &1.slug, url: AgentDocs.abs_url("/tags/" <> &1.slug)})
  end

  defp apply_entry(%JobPosting{apply_kind: :url, apply_url: url}),
    do: %{kind: "url", target: url}

  defp apply_entry(%JobPosting{apply_kind: :email, apply_email: email}),
    do: %{kind: "email", target: email}

  defp apply_entry(%JobPosting{apply_kind: :message}),
    do: %{kind: "message", target: nil}
end
