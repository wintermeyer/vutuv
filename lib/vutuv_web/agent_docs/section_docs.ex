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

  alias Vutuv.Profiles.SocialMediaAccount
  alias Vutuv.Tags.UserTag
  alias VutuvWeb.AgentDocs
  alias VutuvWeb.UserHelpers

  # section (= URL segment = index doc type) => show doc type. The doc maps
  # carry the section under :section, so the renderers dispatch on the doc
  # itself and hold no copy of this inventory.
  @sections %{
    work_experiences: "work_experience",
    educations: "education",
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
    entries = Enum.map(entries, &entry(section, &1))

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

  defp entry_title(:links, entry), do: entry.description || entry.url
  defp entry_title(:social_media_accounts, entry), do: entry.provider
  defp entry_title(:addresses, entry), do: entry.description || entry.city || gettext("Address")
  defp entry_title(:phone_numbers, entry), do: entry.value
  defp entry_title(:emails, entry), do: entry.value
  defp entry_title(:tags, entry), do: entry.name

  defp entry(:work_experiences, record), do: work_entry(record)
  defp entry(:educations, record), do: education_entry(record)
  defp entry(:links, record), do: link_entry(record)
  defp entry(:social_media_accounts, record), do: social_entry(record)
  defp entry(:addresses, record), do: address_entry(record)
  defp entry(:phone_numbers, record), do: phone_entry(record)
  defp entry(:emails, record), do: email_entry(record)
  defp entry(:tags, record), do: tag_entry(record)

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
      # The CV category (issue #840): employment | internship | volunteer.
      kind: work.kind,
      start: year_month(work.start_year, work.start_month),
      end: year_month(work.end_year, work.end_month)
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
      start: year_month(edu.start_year, edu.start_month),
      end: year_month(edu.end_year, edu.end_month)
    }
  end

  defp year_month(nil, _month), do: nil
  defp year_month(year, nil), do: Integer.to_string(year)

  defp year_month(year, month),
    do: "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}"

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
  def phone_entry(phone), do: %{id: phone.id, type: phone.number_type, value: phone.value}

  @doc false
  def email_entry(email), do: %{id: email.id, type: email.email_type, value: email.value}

  @doc false
  def tag_entry(user_tag) do
    %{
      id: user_tag.id,
      name: UserTag.name(user_tag),
      slug: user_tag.tag.slug,
      endorsements: endorsement_count(user_tag),
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
