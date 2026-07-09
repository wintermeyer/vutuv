defmodule VutuvWeb.AgentDocs.SectionDocs do
  @moduledoc """
  The profile's public sub-pages as data maps for the agent formats: the
  section indexes (`/:slug/work_experiences`, `/links`,
  `/social_media_accounts`, `/addresses`, `/phone_numbers`, `/emails`,
  `/tags`) and their single-entry show pages (same path plus the entry's
  id or slug).

  Anonymous view only — the email pages carry just the public addresses.
  All these pages run through the `NoIndex` pipeline in HTML, so their
  docs are `noindex: true` (and `noai: true` — the page-level restriction
  covers both axes) and answer with an all-no `Content-Signal`.

  This module also owns the **entry vocabulary**: the per-entry maps
  (`work_entry/1`, `tag_entry/1`, …) are shared with
  `VutuvWeb.AgentDocs.ProfileDoc`, so a section page and the profile page
  can never describe the same record differently.
  """

  use Gettext, backend: VutuvWeb.Gettext

  alias Vutuv.Languages
  alias Vutuv.Phone
  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.CV
  alias VutuvWeb.LanguageHTML
  alias VutuvWeb.UserHelpers

  # section (= URL segment = index doc type) => show doc type. The doc maps
  # carry the section under :section, so the renderers dispatch on the doc
  # itself and hold no copy of this inventory.
  @sections %{
    work_experiences: "work_experience",
    educations: "education",
    qualifications: "qualification",
    languages: "language",
    links: "link",
    social_media_accounts: "social_media_account",
    addresses: "address",
    phone_numbers: "phone_number",
    emails: "email",
    tags: "user_tag"
  }

  @doc "Every profile section (the drift test derives its coverage from this)."
  def sections, do: Map.keys(@sections)

  @doc "The section index page: all of `user`'s entries of one kind."
  def build_index(user, section, entries) when is_map_key(@sections, section) do
    segment = Atom.to_string(section)
    title = index_title(section, UserHelpers.full_name(user))
    entries = index_entries(section, entries)

    AgentDocs.doc_meta(segment, "/#{user.username}/#{segment}", noindex: true, noai: true)
    |> Map.merge(%{
      section: segment,
      title: title,
      description: title,
      user: AgentDocs.person_ref(user),
      total: length(entries),
      entries: entries
    })
  end

  @doc "A single entry's show page (`/:slug/<section>/<id-or-slug>`)."
  def build_show(user, section, record) when is_map_key(@sections, section) do
    segment = Atom.to_string(section)
    path = "/#{user.username}/#{segment}/#{Phoenix.Param.to_param(record)}"
    entry = entry(section, record)

    AgentDocs.doc_meta(@sections[section], path, noindex: true, noai: true)
    |> Map.merge(%{
      section: segment,
      title: "#{entry_title(section, entry)} · #{UserHelpers.full_name(user)}",
      description: nil,
      user: AgentDocs.person_ref(user),
      entry: entry
    })
  end

  defp index_title(:work_experiences, name), do: gettext("Work experience of %{name}", name: name)
  defp index_title(:educations, name), do: gettext("Education of %{name}", name: name)

  defp index_title(:qualifications, name),
    do: gettext("Certificates & licenses of %{name}", name: name)

  defp index_title(:languages, name), do: gettext("Languages of %{name}", name: name)
  defp index_title(:links, name), do: gettext("Links of %{name}", name: name)

  defp index_title(:social_media_accounts, name),
    do: gettext("Social media accounts of %{name}", name: name)

  defp index_title(:addresses, name), do: gettext("Addresses of %{name}", name: name)
  defp index_title(:phone_numbers, name), do: gettext("Phone numbers of %{name}", name: name)
  defp index_title(:emails, name), do: gettext("Email addresses of %{name}", name: name)
  defp index_title(:tags, name), do: gettext("Tags of %{name}", name: name)

  defp entry_title(:work_experiences, entry),
    do: Enum.join(Enum.filter([entry.title, entry.organization], & &1), " @ ")

  defp entry_title(:educations, entry),
    do: Enum.join(Enum.filter([entry.degree, entry.school], & &1), " · ")

  defp entry_title(:qualifications, entry), do: entry.name

  defp entry_title(:languages, entry), do: entry.name

  defp entry_title(:links, entry), do: entry.description || entry.url
  defp entry_title(:social_media_accounts, entry), do: entry.provider
  defp entry_title(:addresses, entry), do: entry.description || entry.city || gettext("Address")
  defp entry_title(:phone_numbers, entry), do: entry.value
  defp entry_title(:emails, entry), do: entry.value
  defp entry_title(:tags, entry), do: entry.name

  defp entry(:work_experiences, record), do: work_entry(record)
  defp entry(:educations, record), do: education_entry(record)
  defp entry(:qualifications, record), do: qualification_entry(record)
  defp entry(:languages, record), do: language_entry(record)
  defp entry(:links, record), do: link_entry(record)
  defp entry(:social_media_accounts, record), do: social_entry(record)
  defp entry(:addresses, record), do: address_entry(record)
  defp entry(:phone_numbers, record), do: phone_entry(record)
  defp entry(:emails, record), do: email_entry(record)
  defp entry(:tags, record), do: tag_entry(record)

  # An index's whole entry list. Languages need the list (not per-record `entry/2`)
  # to flag the preferred head, so they route through `language_entries/1`.
  defp index_entries(:languages, records), do: language_entries(records)
  defp index_entries(section, records), do: Enum.map(records, &entry(section, &1))

  # The shared entry vocabulary (also used by ProfileDoc).

  # Every entry map carries the record's id: the public docs gain a stable
  # reference (additive, schema_version stays 1) and the /api/2.0 CRUD
  # endpoints need it to address entries.

  @doc false
  def work_entry(work) do
    %{
      id: work.id,
      title: work.title,
      organization: work.organization,
      description: work.description,
      # The CV category (issue #840): employment | self_employed | internship |
      # volunteer | other.
      kind: work.kind,
      start: CV.year_month(work.start_year, work.start_month),
      end: CV.year_month(work.end_year, work.end_month)
    }
  end

  @doc false
  def education_entry(edu) do
    %{
      id: edu.id,
      school: edu.school,
      degree: edu.degree,
      field_of_study: edu.field_of_study,
      description: edu.description,
      # The CV category (issue #849): university | apprenticeship | school.
      kind: edu.kind,
      start: CV.year_month(edu.start_year, edu.start_month),
      end: CV.year_month(edu.end_year, edu.end_month)
    }
  end

  @doc false
  def qualification_entry(qualification) do
    %{
      id: qualification.id,
      name: qualification.name,
      # certification | license.
      kind: qualification.kind,
      issuer: qualification.issuer,
      credential_id: qualification.credential_id,
      url: qualification.url,
      awarded: CV.year_month(qualification.awarded_year, qualification.awarded_month),
      expires: CV.year_month(qualification.expires_year, qualification.expires_month)
    }
  end

  @doc """
  A member's language entries, mapped to doc maps and — once there is a choice
  (2+ languages) — with the head flagged `preferred: true` (issue #894). The
  entries arrive in the member's own order (`Language.ordered/1`), so the first
  is the language they prefer to be contacted in. Shared by the profile doc and
  the `/:slug/languages` index doc so both mark it identically.
  """
  def language_entries(languages) do
    case Enum.map(languages, &language_entry/1) do
      [first | [_ | _] = rest] -> [Map.put(first, :preferred, true) | rest]
      entries -> entries
    end
  end

  @doc false
  def language_entry(language) do
    %{
      id: language.id,
      # The stored ISO 639-1 code (a BCP 47 primary subtag) for machines, the
      # localized name for humans, and the raw proficiency level (native /
      # a1..c2) — the same facts the profile card shows.
      code: language.language_code,
      name: Languages.name(language.language_code),
      proficiency: language.proficiency,
      level: LanguageHTML.proficiency_badge(language.proficiency)
    }
  end

  @doc false
  def link_entry(url), do: %{id: url.id, url: url.value, description: url.description}

  @doc false
  def social_entry(account),
    do: %{id: account.id, provider: account.provider, url: SocialMediaAccount.url(account)}

  @doc false
  def address_entry(address) do
    %{
      id: address.id,
      description: address.description,
      line_1: address.line_1,
      line_2: address.line_2,
      line_3: address.line_3,
      line_4: address.line_4,
      city: address.city,
      state: address.state,
      zip_code: address.zip_code,
      country: address.country
    }
  end

  @doc false
  # `Phone.display/1` renders the number in readable international form, matching
  # the HTML section/show pages and spacing any legacy run-together value.
  def phone_entry(phone),
    do: %{id: phone.id, type: phone.number_type, value: Phone.display(phone.value)}

  @doc false
  def email_entry(email), do: %{id: email.id, type: email.email_type, value: email.value}

  @doc false
  def tag_entry(user_tag) do
    %{
      id: user_tag.id,
      name: UserTag.name(user_tag),
      slug: user_tag.tag.slug,
      endorsements: endorsement_count(user_tag),
      # An honor tag is an admin-granted badge (not self-assigned, not
      # endorsable). Carried so every format can mark it.
      honor: user_tag.tag.honor?,
      url: AgentDocs.abs_url("/tags/#{user_tag.tag.slug}")
    }
  end

  # ordered_by_endorsements/0 select_merges the count; a user_tag loaded
  # another way (the show page) counts its loaded rows. Both mechanisms drop
  # hidden/unactivated endorsers (issue #783): the query filters in its ON
  # clause, and every :endorsements preload that reaches here goes through
  # UserTagEndorsement.visible/1, so length/1 counts only visible endorsers.
  defp endorsement_count(%UserTag{endorsement_count: count}) when is_integer(count), do: count
  defp endorsement_count(user_tag), do: length(user_tag.endorsements)
end
