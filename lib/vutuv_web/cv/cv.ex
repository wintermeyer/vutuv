defmodule VutuvWeb.CV do
  @moduledoc """
  The member's profile as one CV (Lebenslauf) data map — the single source
  the download renderers share (`VutuvWeb.CV.Html`, `.Latex`, `.Docx`,
  `.Odt`, `.JsonResume`), the way `VutuvWeb.AgentDocs.ProfileDoc` feeds the
  agent formats (issue #841).

  Built through a viewer's eyes: anyone may download the CV of data they can
  already see — work, education, tags, links, phone numbers and addresses
  are public profile sections, and the email resolves per viewer
  (`UserHelpers.emails_for_display/2`), so a private address only ever
  appears in the owner's own download. Pass the `:viewer` option; nil is
  the anonymous public view.

  The body is a list of uniform `sections` (heading + entries of
  `%{period, title, organization, description}`): the issue #840
  work-experience categories in their fixed order (employment, internships,
  volunteering), then education in its issue #849 categories (university,
  apprenticeship, school — collapsed to one "Education" section for the
  common degrees-only member, like the profile). `work_groups`/`educations`
  additionally carry the raw fields for the JSON Resume renderer, which
  needs the category and the year/month parts rather than display strings.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.EducationHTML
  alias VutuvWeb.UserHelpers
  alias VutuvWeb.WorkExperienceHTML

  @doc """
  Options:

    * `:viewer` — the user whose eyes the CV is built through (default nil,
      the anonymous public view). Only the email is viewer-sensitive.
    * `:photo` — also derive the avatar as a JPEG data URI (used by the
      HTML/print rendering only, so the text formats skip the image work).
  """
  def build(user, opts \\ []) do
    user = preload(user)
    emails = UserHelpers.emails_for_display(user, Keyword.get(opts, :viewer))

    %{
      name: UserHelpers.full_name(user),
      headline: presence(user.headline),
      username: user.username,
      profile_url: VutuvWeb.Endpoint.url() <> "/" <> user.username,
      email: first_value(emails),
      phone: first_value(user.phone_numbers),
      address_lines: address_lines(List.first(user.addresses)),
      links: Enum.map(user.urls, &%{label: presence(&1.description), url: &1.value}),
      sections: sections(user),
      skills: Enum.map(user.user_tags, &UserTag.name/1),
      photo: photo(user, opts),
      work_groups: work_groups(user),
      educations: Enum.map(user.educations, &education_raw/1)
    }
  end

  @doc """
  A `YYYY` / `YYYY-MM` date for the machine-readable formats (the shape
  JSON Resume expects), nil when the year is unknown.
  """
  def year_month(nil, _month), do: nil
  def year_month(year, nil), do: Integer.to_string(year)

  def year_month(year, month),
    do: "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}"

  # The same ordered associations the profile page shows, so the CV can
  # never disagree with the profile about order.
  defp preload(user) do
    Repo.preload(user,
      user_tags: UserTag.ordered_by_endorsements(),
      work_experiences: WorkExperience.order_by_date(WorkExperience),
      educations: Education.order_by_date(Education),
      phone_numbers: PhoneNumber.ordered(),
      urls: Url.ordered(),
      addresses: Address.ordered()
    )
  end

  defp sections(user) do
    work =
      for {kind, entries} <- WorkExperience.group_by_kind(user.work_experiences) do
        %{
          heading: WorkExperienceHTML.kind_label(kind),
          entries: Enum.map(entries, &work_entry/1)
        }
      end

    work ++ education_sections(user.educations)
  end

  defp work_entry(work) do
    %{
      period: period(work),
      title: work.title,
      organization: work.organization,
      description: presence(work.description)
    }
  end

  defp education_sections([]), do: []

  # The issue #849 education categories, mirroring the profile's rule: the
  # common degrees-only member keeps one plain "Education" section, and the
  # Studium / Berufsausbildung / Schulbildung headings appear only once a
  # non-university entry exists.
  defp education_sections(educations) do
    if EducationHTML.show_kind_headings?(educations) do
      for {kind, entries} <- Education.group_by_kind(educations) do
        %{
          heading: EducationHTML.kind_label(kind),
          entries: Enum.map(entries, &education_entry/1)
        }
      end
    else
      [%{heading: gettext("Education"), entries: Enum.map(educations, &education_entry/1)}]
    end
  end

  # A degree line ("BSc, Informatik") reads as the role, the school as the
  # organization; a school-only entry promotes the school to the role line.
  defp education_entry(edu) do
    degree_line =
      [edu.degree, edu.field_of_study]
      |> Enum.filter(&presence/1)
      |> Enum.join(", ")

    {title, organization} =
      if degree_line == "", do: {edu.school, nil}, else: {degree_line, edu.school}

    %{
      period: period(edu),
      title: title,
      organization: organization,
      description: presence(edu.description)
    }
  end

  # An entirely undated entry shows no period (format_duration/4 would call
  # the missing end date "Present", which is only right when a start exists).
  defp period(%{start_year: nil, end_year: nil}), do: nil

  defp period(entry) do
    IO.iodata_to_binary(
      WorkExperienceHTML.format_duration(
        entry.start_month,
        entry.start_year,
        entry.end_month,
        entry.end_year
      )
    )
  end

  defp work_groups(user) do
    for {kind, entries} <- WorkExperience.group_by_kind(user.work_experiences) do
      {kind, Enum.map(entries, &work_raw/1)}
    end
  end

  defp work_raw(work) do
    %{
      title: work.title,
      organization: work.organization,
      description: presence(work.description),
      start: year_month(work.start_year, work.start_month),
      end: year_month(work.end_year, work.end_month)
    }
  end

  defp education_raw(edu) do
    %{
      school: edu.school,
      degree: presence(edu.degree),
      field_of_study: presence(edu.field_of_study),
      description: presence(edu.description),
      start: year_month(edu.start_year, edu.start_month),
      end: year_month(edu.end_year, edu.end_month)
    }
  end

  defp first_value([%{value: value} | _rest]), do: presence(value)
  defp first_value(_none), do: nil

  defp address_lines(nil), do: []

  defp address_lines(address) do
    city_line =
      [address.zip_code, address.city]
      |> Enum.filter(&presence/1)
      |> Enum.join(" ")

    [
      address.line_1,
      address.line_2,
      address.line_3,
      address.line_4,
      city_line,
      address.state,
      address.country
    ]
    |> Enum.map(&presence/1)
    |> Enum.filter(& &1)
  end

  # Only a real derived JPEG makes it into the CV — the silhouette
  # placeholder Avatar.binary/2 falls back to has no place on a Lebenslauf.
  defp photo(%{avatar: nil}, _opts), do: nil

  defp photo(user, opts) do
    if Keyword.get(opts, :photo, false) do
      case Vutuv.Avatar.binary(user, :medium) do
        "data:image/jpeg" <> _rest = data_uri -> data_uri
        _placeholder -> nil
      end
    end
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end
end
