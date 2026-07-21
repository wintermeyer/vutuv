defmodule Vutuv.Newsletters.NewsletterGroup do
  @moduledoc """
  A newsletter audience ("group"): a **fixed snapshot** of members built from
  filters and minus other groups.

  The filter criteria live on the struct (`locales`, `country`, `min_age`/
  `max_age`, `tag_id`, `excluded_group_ids`, optional `max_size` cap), so a group
  can be re-previewed and edited; the matching members are frozen into
  `NewsletterGroupMember` rows when the group is saved (`Vutuv.Newsletters`).
  Because membership is a snapshot, "test run of 100, then the rest" partitions
  cleanly: the rest group subtracts the (fixed) test group.

  `tag_name` is a virtual field the form binds; the context resolves it to
  `tag_id`.
  """

  use VutuvWeb, :model

  import Vutuv.ChangesetHelpers, only: [trim_fields: 2]

  alias Vutuv.Newsletters.NewsletterGroupMember
  alias Vutuv.Tags.Tag

  @locales ~w(en de)
  @max_name 255

  schema "newsletter_groups" do
    field(:name, :string)
    field(:locales, {:array, :string}, default: [])
    field(:country, :string)
    field(:min_age, :integer)
    field(:max_age, :integer)
    field(:max_size, :integer)
    # When capped, take a random sample of the pool instead of the oldest members.
    field(:random_sample, :boolean, default: false)
    # An ILIKE handle pattern (`*` wildcard); see Vutuv.Newsletters.
    field(:username, :string)
    # Other groups UNIONed in (the inverse of excluded_group_ids).
    field(:included_group_ids, {:array, :binary_id}, default: [])
    field(:excluded_group_ids, {:array, :binary_id}, default: [])
    # Per-account curation: specific members always in / always out.
    field(:included_user_ids, {:array, :binary_id}, default: [])
    field(:excluded_user_ids, {:array, :binary_id}, default: [])
    field(:member_count, :integer, default: 0)
    field(:tag_name, :string, virtual: true)

    belongs_to(:tag, Tag)
    has_many(:members, NewsletterGroupMember, foreign_key: :group_id)

    timestamps()
  end

  def locales, do: @locales

  def changeset(group, params \\ %{}) do
    group
    |> cast(params, [
      :name,
      :locales,
      :country,
      :min_age,
      :max_age,
      :max_size,
      :random_sample,
      :username,
      :included_group_ids,
      :excluded_group_ids,
      :included_user_ids,
      :excluded_user_ids,
      :tag_name
    ])
    # Nil-safe: clearing the prefilled name casts to a nil change, and
    # String.trim(nil) would crash.
    |> update_change(:name, fn name -> name && String.trim(name) end)
    |> validate_required([:name])
    |> validate_length(:name, max: @max_name)
    # country and username are cast :string fields over varchar(255) columns, so
    # cap them too or an oversized value raises Postgres 22001 on save.
    |> validate_length(:country, max: @max_name)
    |> validate_length(:username, max: @max_name)
    |> clean_locales()
    |> trim_fields([:country, :username])
    |> clean_ids(:included_group_ids)
    |> clean_ids(:excluded_group_ids)
    |> clean_ids(:included_user_ids)
    |> clean_ids(:excluded_user_ids)
    |> validate_number(:min_age, greater_than_or_equal_to: 0, less_than_or_equal_to: 150)
    |> validate_number(:max_age, greater_than_or_equal_to: 0, less_than_or_equal_to: 150)
    |> validate_number(:max_size, greater_than: 0)
    |> validate_age_range()
  end

  # Keep only the supported locales (drops the empty hidden-input value the form
  # sends so unchecking all clears the list).
  defp clean_locales(changeset) do
    case fetch_change(changeset, :locales) do
      {:ok, locales} -> put_change(changeset, :locales, Enum.filter(locales, &(&1 in @locales)))
      :error -> changeset
    end
  end

  # Drop the empty hidden-input value and any blanks from an id-array field (the
  # included/excluded audiences and the per-account include/exclude lists).
  defp clean_ids(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, ids} ->
        put_change(changeset, field, ids |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq())

      :error ->
        changeset
    end
  end

  defp validate_age_range(changeset) do
    min_age = get_field(changeset, :min_age)
    max_age = get_field(changeset, :max_age)

    if is_integer(min_age) and is_integer(max_age) and min_age > max_age do
      add_error(changeset, :max_age, "must not be smaller than the minimum age")
    else
      changeset
    end
  end
end
