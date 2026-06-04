defmodule Vutuv.Tags.Tag do
  @moduledoc false

  use VutuvWeb, :model
  @derive {Phoenix.Param, key: :slug}

  schema "tags" do
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)

    has_many(:user_tags, Vutuv.Tags.UserTag)
    has_many(:job_posting_tags, Vutuv.JobPostings.JobPostingTag)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.

  Accepts either a `"value"` key (the human-readable tag name, as typed by a user)
  or explicit `"name"`/`"slug"` keys. The slug is auto-generated from the name.
  """
  def changeset(struct, params \\ %{})

  def changeset(struct, %{"value" => value} = params) do
    struct
    |> cast(params, [:name, :description])
    |> put_change(:name, value)
    |> gen_slug(value)
    |> shared_validations()
  end

  def changeset(struct, params) do
    struct
    |> cast(params, [:slug, :name, :description])
    |> maybe_gen_slug()
    |> shared_validations()
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_required([:slug, :name])
    |> validate_length(:slug, max: 60)
    |> validate_length(:name, max: 255)
    |> unique_constraint(:slug)
  end

  defp maybe_gen_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) -> gen_slug(changeset, name)
      _ -> changeset
    end
  end

  def edit_changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [:slug, :name, :description])
    |> validate_required([:slug, :name])
    |> validate_length(:slug, max: 60)
    |> validate_length(:name, max: 255)
    |> unique_constraint(:slug)
  end

  def gen_slug(changeset, value) do
    slug = Vutuv.SlugHelpers.gen_slug_unique(value, __MODULE__, :slug)
    put_change(changeset, :slug, slug)
  end

  @doc """
  Links the changeset to an existing tag whose name (case-insensitive) or slug
  matches the typed value, or builds a new tag when none exists.
  """
  def create_or_link_tag(changeset, %{"value" => value} = params) do
    downcase_value = String.downcase(value)

    Vutuv.Repo.one(
      from(t in __MODULE__,
        where: fragment("lower(?)", t.name) == ^downcase_value or t.slug == ^downcase_value,
        limit: 1
      )
    )
    |> case do
      nil ->
        tag = __MODULE__.changeset(%__MODULE__{}, params)
        put_assoc(changeset, :tag, tag)

      tag ->
        put_change(changeset, :tag_id, tag.id)
    end
  end

  def related_users(_, nil), do: []

  def related_users(tag, current_user) do
    (related_for(current_user, :followers, tag) ++
       related_for(current_user, :followees, tag))
    |> Enum.uniq_by(& &1.id)
  end

  # `followers`/`followees` are has_many :through, so `Ecto.assoc/2` builds a
  # query with `distinct: true`. Postgres rejects SELECT DISTINCT combined with
  # `ORDER BY count(...)` (the aggregate is not in the select list); MariaDB
  # tolerated it. `group_by: u.id` already yields one row per user, so drop the
  # redundant distinct.
  defp related_for(current_user, assoc, tag) do
    source = current_user |> Ecto.assoc(assoc) |> Ecto.Query.exclude(:distinct)
    most_endorsed_in_tag(source, tag)
  end

  def recommended_users(tag) do
    most_endorsed_in_tag(Vutuv.Accounts.User, tag)
  end

  # The ten users with the most endorsements for `tag`, drawn from `source`
  # (a queryable: a plain schema or an association query). Shared by
  # `related_for/3` and `recommended_users/1`, which differ only in that source.
  defp most_endorsed_in_tag(source, tag) do
    Vutuv.Repo.all(
      from(u in source,
        left_join: us in assoc(u, :user_tags),
        left_join: e in assoc(us, :endorsements),
        where: us.tag_id == ^tag.id,
        # most endorsed
        order_by: fragment("count(?) DESC", e.id),
        group_by: u.id,
        limit: 10
      )
    )
  end

  defimpl String.Chars, for: Vutuv.Tags.Tag do
    def to_string(tag), do: "#{tag.slug}"
  end

  defimpl List.Chars, for: Vutuv.Tags.Tag do
    def to_charlist(tag), do: ~c"#{tag.slug}"
  end
end
