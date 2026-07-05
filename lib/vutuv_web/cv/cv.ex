defmodule VutuvWeb.CV do
  @moduledoc """
  The member's profile as one CV (Lebenslauf) data map — the single source
  the download renderers share (`VutuvWeb.CV.Html`, `.Latex`, `.Docx`,
  `.Odt`, `.JsonResume`) and the interactive builder `VutuvWeb.CVLive`
  (issue #841).

  Built through a viewer's eyes: anyone may download the CV of data they can
  already see — work, education, tags, links, phone numbers and addresses
  are public profile sections, and the email resolves per viewer
  (`UserHelpers.emails_for_display/2`), so a private address only ever
  appears in the owner's own download. Pass the `:viewer` option; nil is
  the anonymous public view.

  **Every part carries a stable key** so the builder can offer per-item
  include/exclude and encode the choice in the download URLs — a recruiter
  can drop sections, single entries, or the identifying fields (name, photo,
  contact) to forward an anonymized CV. `apply_hide/2` takes a `MapSet` of
  those keys and returns the trimmed map the renderers consume:

    * identity fields — `"name"`, `"photo"`, `"headline"`, `"email"`,
      `"phone"`, `"address"`, `"url"` (the profile link), `"birthdate"` and
      `"gender"` (the personal details)
    * whole sections — a work/education category key (`"employment"`,
      `"self_employed"`, `"internship"`, `"volunteer"`, `"other"`,
      `"university"`, `"apprenticeship"`, `"school"`, or `"education"` when
      the categories are collapsed), plus `"tags"`, `"qualifications"`,
      `"languages"`, `"links"` and `"social_media"`
    * single entries — the record's UUID

  The body is a list of uniform `sections` (`%{key, heading, entries}`, each
  entry `%{id, period, title, organization, description}`): the issue #840
  work categories in fixed order, then education in its issue #849 categories
  (collapsed to one "Education" section for the common degrees-only member,
  like the profile). `work_groups`/`educations` additionally carry the raw
  fields for the JSON Resume renderer.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Accounts.User
  alias Vutuv.Languages
  alias Vutuv.Phone
  alias Vutuv.Profiles.Address
  alias Vutuv.Profiles.Education
  alias Vutuv.Profiles.Language
  alias Vutuv.Profiles.PhoneNumber
  alias Vutuv.Profiles.Qualification
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Profiles.Url
  alias Vutuv.Profiles.WorkExperience
  alias Vutuv.Repo
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.EducationHTML
  alias VutuvWeb.LanguageHTML
  alias VutuvWeb.UserHelpers
  alias VutuvWeb.WorkExperienceHTML

  # The identity fields, in header order, as `{hide-key, cv-map field}`. The
  # builder renders a toggle per field that has a value; the "Anonymize"
  # preset hides all but the headline (a job title, not a name). Date of birth
  # and gender are personal details that ride here too, so a member can drop
  # them (and the Anonymize preset does, since they are bias-prone).
  @identity_fields [
    {"name", :name},
    {"photo", :photo},
    {"headline", :headline},
    {"email", :email},
    {"phone", :phone},
    {"address", :address_lines},
    {"url", :profile_url},
    {"birthdate", :birthdate},
    {"gender", :gender}
  ]

  @anonymize ~w(name photo email phone address url birthdate gender social_media)

  @doc "The identity fields as `{key, cv-field}`, in header order."
  def identity_fields, do: @identity_fields

  @doc "The keys the Anonymize preset hides (name, photo, contact, profile link)."
  def anonymize_keys, do: @anonymize

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
      phone: phone_display(first_value(user.phone_numbers)),
      address_lines: address_lines(List.first(user.addresses)),
      birthdate: birthdate(user),
      gender: gender(user),
      links: Enum.map(user.urls, &%{id: &1.id, label: presence(&1.description), url: &1.value}),
      social_media: Enum.map(user.social_media_accounts, &social_media_entry/1),
      sections: sections(user),
      skills: Enum.map(user.user_tags, &%{id: &1.id, name: UserTag.name(&1)}),
      qualifications: Enum.map(user.qualifications, &qualification_entry/1),
      languages: Enum.map(user.languages, &language_entry/1),
      photo: photo(user, opts),
      work_groups: work_groups(user),
      educations: Enum.map(user.educations, &education_raw/1)
    }
  end

  @doc """
  Trim a built CV to the viewer's selection: drop every identity field,
  section and entry whose key is in `hide` (a `MapSet` of strings), and any
  section left empty. `MapSet.new()` is a no-op that returns the full CV.
  """
  def apply_hide(cv, %MapSet{} = hide) do
    %{
      cv
      | name: hidden(cv.name, "name", hide),
        photo: hidden(cv.photo, "photo", hide),
        headline: hidden(cv.headline, "headline", hide),
        email: hidden(cv.email, "email", hide),
        phone: hidden(cv.phone, "phone", hide),
        profile_url: hidden(cv.profile_url, "url", hide),
        birthdate: hidden(cv.birthdate, "birthdate", hide),
        gender: hidden(cv.gender, "gender", hide),
        address_lines: if(MapSet.member?(hide, "address"), do: [], else: cv.address_lines),
        sections: filter_sections(cv.sections, hide),
        skills: filter_by_id(cv.skills, "tags", hide),
        qualifications: filter_by_id(cv.qualifications, "qualifications", hide),
        languages: filter_by_id(cv.languages, "languages", hide),
        links: filter_by_id(cv.links, "links", hide),
        social_media: filter_by_id(cv.social_media, "social_media", hide),
        work_groups: filter_work_groups(cv.work_groups, hide),
        educations: filter_educations(cv.educations, hide)
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

  defp hidden(value, key, hide), do: if(MapSet.member?(hide, key), do: nil, else: value)

  defp filter_sections(sections, hide) do
    sections
    |> Enum.reject(&MapSet.member?(hide, &1.key))
    |> Enum.map(fn section ->
      %{section | entries: Enum.reject(section.entries, &MapSet.member?(hide, &1.id))}
    end)
    |> Enum.reject(&(&1.entries == []))
  end

  defp filter_by_id(list, section_key, hide) do
    if MapSet.member?(hide, section_key),
      do: [],
      else: Enum.reject(list, &MapSet.member?(hide, &1.id))
  end

  defp filter_work_groups(groups, hide) do
    groups
    |> Enum.reject(fn {kind, _entries} -> MapSet.member?(hide, kind) end)
    |> Enum.map(fn {kind, entries} ->
      {kind, Enum.reject(entries, &MapSet.member?(hide, &1.id))}
    end)
    |> Enum.reject(fn {_kind, entries} -> entries == [] end)
  end

  defp filter_educations(educations, hide) do
    if MapSet.member?(hide, "education") do
      []
    else
      Enum.reject(educations, fn edu ->
        MapSet.member?(hide, edu.kind) or MapSet.member?(hide, edu.id)
      end)
    end
  end

  # The same ordered associations the profile page shows, so the CV can
  # never disagree with the profile about order.
  defp preload(user) do
    Repo.preload(user,
      user_tags: UserTag.ordered_by_endorsements(),
      work_experiences: WorkExperience.order_by_date(WorkExperience),
      educations: Education.order_by_date(Education),
      # A CV is a public document, so it hides expired credentials too (#859).
      qualifications: Qualification.visible_to(false) |> Qualification.ordered(),
      languages: Language.ordered(),
      social_media_accounts: SocialMediaAccount.ordered(),
      phone_numbers: PhoneNumber.ordered(),
      urls: Url.ordered(),
      addresses: Address.ordered()
    )
  end

  defp sections(user) do
    work =
      for {kind, entries} <- WorkExperience.group_by_kind(user.work_experiences) do
        %{
          key: kind,
          heading: WorkExperienceHTML.kind_label(kind),
          entries: Enum.map(entries, &work_entry/1)
        }
      end

    work ++ education_sections(user.educations)
  end

  defp work_entry(work) do
    %{
      id: work.id,
      period: period(work),
      title: work.title,
      organization: work.organization,
      description: presence(work.description)
    }
  end

  defp education_sections([]), do: []

  # The issue #849 education categories, mirroring the profile's rule: the
  # common degrees-only member keeps one plain "Education" section (key
  # "education"), and the Studium / Berufsausbildung / Schulbildung headings
  # (keyed by kind) appear only once a non-university entry exists.
  defp education_sections(educations) do
    if EducationHTML.show_kind_headings?(educations) do
      for {kind, entries} <- Education.group_by_kind(educations) do
        %{
          key: kind,
          heading: EducationHTML.kind_label(kind),
          entries: Enum.map(entries, &education_entry/1)
        }
      end
    else
      [
        %{
          key: "education",
          heading: gettext("Education"),
          entries: Enum.map(educations, &education_entry/1)
        }
      ]
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
      id: edu.id,
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
      id: work.id,
      title: work.title,
      organization: work.organization,
      description: presence(work.description),
      start: year_month(work.start_year, work.start_month),
      end: year_month(work.end_year, work.end_month)
    }
  end

  defp education_raw(edu) do
    %{
      id: edu.id,
      kind: edu.kind,
      school: edu.school,
      degree: presence(edu.degree),
      field_of_study: presence(edu.field_of_study),
      description: presence(edu.description),
      start: year_month(edu.start_year, edu.start_month),
      end: year_month(edu.end_year, edu.end_month)
    }
  end

  # A language line ("German — Native speaker"): the localized name plus the
  # descriptive proficiency label, so a Lebenslauf reads the level in words.
  defp language_entry(language) do
    %{
      id: language.id,
      name: Languages.name(language.language_code),
      fluency: LanguageHTML.proficiency_label(language.proficiency)
    }
  end

  # A credential line for the CV (issue #859): the structured facts for the
  # JSON Resume shape (`name` / `issuer` / `date` / `url`) plus a ready-made
  # `label` ("AWS Solutions Architect (Amazon Web Services, 2023)") the text
  # formats print, so the joining logic lives here once, not in each renderer.
  defp qualification_entry(qualification) do
    issuer = presence(qualification.issuer)
    date = year_month(qualification.awarded_year, qualification.awarded_month)

    %{
      id: qualification.id,
      name: qualification.name,
      issuer: issuer,
      date: date,
      url: presence(qualification.url),
      label: qualification_label(qualification.name, [issuer, date])
    }
  end

  defp qualification_label(name, details) do
    case Enum.reject(details, &is_nil/1) do
      [] -> name
      present -> "#{name} (#{Enum.join(present, ", ")})"
    end
  end

  # A social media account for the CV: the provider name, the visitor-facing
  # handle and the public profile URL (nil for a provider with no canonical
  # URL scheme, e.g. Snapchat — then the renderers fall back to the handle).
  defp social_media_entry(account) do
    url = SocialMediaAccount.url(account)

    %{
      id: account.id,
      provider: account.provider,
      handle: social_handle(account),
      url: if(String.starts_with?(url, "http"), do: url, else: nil)
    }
  end

  # Mirrors VutuvWeb.UserHTML.social_handle/1: the Twitter/Mastodon/Instagram
  # handles read with a leading "@", every other provider bare.
  defp social_handle(%{provider: provider, value: value})
       when provider in ~w(Twitter Mastodon Instagram),
       do: "@" <> value

  defp social_handle(%{value: value}), do: value

  # The member's date of birth as the formatted string the profile shows
  # (locale-aware via UserHelpers.format_birthdate/1), nil when unset.
  defp birthdate(user), do: presence(UserHelpers.format_birthdate(user))

  # The gender label, following the profile's rule: shown only for a concrete
  # value, hidden for the unset default ("other"/nil).
  defp gender(%{gender: value}) when is_binary(value) and value != "other",
    do: User.gender_gettext(value)

  defp gender(_user), do: nil

  defp first_value([%{value: value} | _rest]), do: presence(value)
  defp first_value(_none), do: nil

  # Readable international grouping for the CV's contact line (Vutuv.Phone.display/1),
  # matching the profile and spacing a legacy run-together value.
  defp phone_display(nil), do: nil
  defp phone_display(value), do: Phone.display(value)

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
