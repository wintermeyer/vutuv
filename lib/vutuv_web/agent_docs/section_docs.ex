defmodule VutuvWeb.AgentDocs.SectionDocs do
  @moduledoc """
  The profile's public sub-pages as data maps for the agent formats: the
  section indexes (`/:slug/work_experiences`, `/links`,
  `/social_media_accounts`, `/addresses`, `/phone_numbers`, `/emails`,
  `/tags`) and their single-entry show pages (same path plus the entry's
  id or slug).

  Anonymous view only — the email pages carry just the public addresses.
  All these pages run through the `NoIndex` pipeline in HTML, so their
  docs are `noindex: true` and answer with an all-no `Content-Signal`.

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

  # section key => {path segment / index doc type, show doc type}
  @sections %{
    work_experiences: {"work_experiences", "work_experience"},
    links: {"links", "link"},
    social_media_accounts: {"social_media_accounts", "social_media_account"},
    addresses: {"addresses", "address"},
    phone_numbers: {"phone_numbers", "phone_number"},
    emails: {"emails", "email"},
    tags: {"tags", "user_tag"}
  }

  @doc "The section index page: all of `user`'s entries of one kind."
  def build_index(user, section, entries) when is_map_key(@sections, section) do
    {segment, _singular} = @sections[section]
    title = index_title(section, UserHelpers.full_name(user))
    entries = Enum.map(entries, &entry(section, &1))

    AgentDocs.doc_meta(segment, "/#{user.active_slug}/#{segment}", noindex: true)
    |> Map.merge(%{
      title: title,
      description: title,
      user: AgentDocs.person_ref(user),
      total: length(entries),
      entries: entries
    })
  end

  @doc "A single entry's show page (`/:slug/<section>/<id-or-slug>`)."
  def build_show(user, section, record) when is_map_key(@sections, section) do
    {segment, singular} = @sections[section]
    path = "/#{user.active_slug}/#{segment}/#{Phoenix.Param.to_param(record)}"
    entry = entry(section, record)

    AgentDocs.doc_meta(singular, path, noindex: true)
    |> Map.merge(%{
      title: "#{entry_title(section, entry)} · #{UserHelpers.full_name(user)}",
      description: nil,
      user: AgentDocs.person_ref(user),
      entry: entry
    })
  end

  defp index_title(:work_experiences, name), do: gettext("Work experience of %{name}", name: name)
  defp index_title(:links, name), do: gettext("Links of %{name}", name: name)

  defp index_title(:social_media_accounts, name),
    do: gettext("Social media accounts of %{name}", name: name)

  defp index_title(:addresses, name), do: gettext("Addresses of %{name}", name: name)
  defp index_title(:phone_numbers, name), do: gettext("Phone numbers of %{name}", name: name)
  defp index_title(:emails, name), do: gettext("Email addresses of %{name}", name: name)
  defp index_title(:tags, name), do: gettext("Tags of %{name}", name: name)

  defp entry_title(:work_experiences, entry),
    do: Enum.join(Enum.filter([entry.title, entry.organization], & &1), " @ ")

  defp entry_title(:links, entry), do: entry.description || entry.url
  defp entry_title(:social_media_accounts, entry), do: entry.provider
  defp entry_title(:addresses, entry), do: entry.description || entry.city || gettext("Address")
  defp entry_title(:phone_numbers, entry), do: entry.value
  defp entry_title(:emails, entry), do: entry
  defp entry_title(:tags, entry), do: entry.name

  defp entry(:work_experiences, record), do: work_entry(record)
  defp entry(:links, record), do: link_entry(record)
  defp entry(:social_media_accounts, record), do: social_entry(record)
  defp entry(:addresses, record), do: address_entry(record)
  defp entry(:phone_numbers, record), do: phone_entry(record)
  defp entry(:emails, record), do: record.value
  defp entry(:tags, record), do: tag_entry(record)

  # The shared entry vocabulary (also used by ProfileDoc).

  @doc false
  def work_entry(work) do
    %{
      title: work.title,
      organization: work.organization,
      start: year_month(work.start_year, work.start_month),
      end: year_month(work.end_year, work.end_month)
    }
  end

  defp year_month(nil, _month), do: nil
  defp year_month(year, nil), do: Integer.to_string(year)

  defp year_month(year, month),
    do: "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}"

  @doc false
  def link_entry(url), do: %{url: url.value, description: url.description}

  @doc false
  def social_entry(account),
    do: %{provider: account.provider, url: SocialMediaAccount.url(account)}

  @doc false
  def address_entry(address) do
    %{
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
  def phone_entry(phone), do: %{type: phone.number_type, value: phone.value}

  @doc false
  def tag_entry(user_tag) do
    %{
      name: UserTag.name(user_tag),
      slug: user_tag.tag.slug,
      endorsements: length(user_tag.endorsements),
      url: AgentDocs.abs_url("/tags/#{user_tag.tag.slug}")
    }
  end
end
