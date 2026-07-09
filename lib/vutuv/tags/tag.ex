defmodule Vutuv.Tags.Tag do
  @moduledoc false

  use VutuvWeb, :model
  @derive {Phoenix.Param, key: :slug}

  alias Vutuv.Accounts.User

  schema "tags" do
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    # When true the tag is reserved site-wide: only site admins can assign or
    # remove it (the "vutuv_developer" badge). Set only through the admin edit
    # form / the generic changeset head — never the member "value" head below.
    field(:honor?, :boolean, default: false)

    has_many(:user_tags, Vutuv.Tags.UserTag)

    timestamps()
  end

  @doc """
  Builds a changeset based on the `struct` and `params`.

  Accepts either a `"value"` key (the human-readable tag name, as typed by a user)
  or explicit `"name"`/`"slug"` keys. The slug is auto-generated from the name.
  """
  def changeset(struct, params \\ %{})

  def changeset(struct, %{"value" => value} = params) do
    value = normalize_value(value)

    struct
    |> cast(params, [:name, :description])
    |> put_change(:name, value)
    |> gen_slug(value)
    |> shared_validations()
  end

  def changeset(struct, params) do
    struct
    |> cast(params, [:slug, :name, :description, :honor?])
    |> maybe_gen_slug()
    |> shared_validations()
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_required([:slug, :name])
    # A tag name is a single line that may contain spaces ("Ruby on Rails"):
    # multi-word tags are first-class again. `normalize_value/1` already
    # collapses any interior whitespace run to a single space on every member
    # entry point, so this only backstops the raw name/slug head (the admin
    # edit form) against a stray line break or tab sneaking in.
    |> validate_format(:name, ~r/^[^\r\n\t]+$/, message: "must be a single line")
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
    |> cast(params, [:slug, :name, :description, :honor?])
    |> shared_validations()
  end

  def gen_slug(changeset, value) do
    slug = Vutuv.SlugHelpers.gen_slug_unique(value, __MODULE__, :slug)
    put_change(changeset, :slug, slug)
  end

  @doc """
  Links the changeset to an existing tag whose name (case-insensitive) or slug
  matches the typed value, or builds a new tag when none exists.

  The value is one tag name and may contain spaces ("Ruby on Rails"): a
  multi-word value links to the existing spaced tag (case-insensitively) or
  builds it fresh, exactly like a single-word one. Callers that accept a batch
  (sign-up, the tags page, the post composer) tokenize their input first with
  `Vutuv.Tags.parse_tag_names/1`, which honours quotes; the JSON API reaches
  here with a single already-whole name.
  """
  def create_or_link_tag(changeset, %{"value" => value} = params) do
    # Strip the hashtag form before both the existing-tag lookup and the build,
    # so `#Elixir` links to `Elixir` (not a `#`-prefixed duplicate) and stores
    # the bare name. The rewritten params carry the normalized value downstream.
    value = normalize_value(value)
    params = Map.put(params, "value", value)
    link_or_build_tag(changeset, value, params)
  end

  @leading_hash ~r/^#+\s*/

  @doc """
  Normalizes a typed tag value: trims it, strips a leading `#` (the hashtag
  form members naturally type, since posts render `#hashtag` links, so
  `"#elixir"` is stored as the tag `elixir` and links to the same global tag as
  `"elixir"` rather than a `#`-prefixed duplicate; only a *leading* run of `#`
  and any space right after it is removed, so `"C#"` / `"F#"` keep their
  trailing `#`), and collapses every interior run of whitespace to a single
  space so a multi-word tag is stored cleanly (`"Ruby   on  Rails"` and a
  pasted `"Ruby\\non Rails"` both become `"Ruby on Rails"`). A bare `"#"`
  normalizes to `""` (dropped as blank by the tokenizer, rejected by the
  changeset). Applied at every tag-value boundary: `Vutuv.Tags.parse_tag_names/1`,
  `Vutuv.Posts` post tags, `create_or_link_tag/2` and `changeset/2`, so no entry
  point can store a leading `#` or ragged whitespace.
  """
  def normalize_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(@leading_hash, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def normalize_value(value), do: value

  @doc """
  The stored tag matching `value` case-insensitively by name or slug, or `nil`.

  vutuv keeps a tag's **name exactly as its first writer typed it** — capitals and
  all (`normalize_value/1` only trims and strips a leading `#`, it never
  downcases) — while every match ignores case. So `find_by_value("PostgreSQL")`
  returns the existing `postgresql` tag rather than minting a case-variant
  duplicate, which is what makes "the first user decides the spelling" hold even
  when a later member types it differently.

  This is the single place that **loads** a tag by a typed value: the find-or-link
  paths all resolve through here (`create_or_link_tag/2`, so the tags page / JSON
  API / account-setup importer; `Vutuv.Tags.declare_honor_tag/1`; `Vutuv.Posts`
  post tags), so they match a tag identically. Search's tag filters
  (`Vutuv.Search`) and the `Vutuv.Tags.preview_tag_names/1` batch build the same
  case-insensitive name-or-slug predicate inline, because they compose it into a
  larger query rather than fetching a single row.
  """
  def find_by_value(value) when is_binary(value) do
    down = String.downcase(value)

    Vutuv.Repo.one(
      from(t in __MODULE__,
        where: fragment("lower(?)", t.name) == ^down or t.slug == ^down,
        limit: 1
      )
    )
  end

  defp link_or_build_tag(changeset, value, params) do
    case find_by_value(value) do
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
  # Same visibility gate as search/most-followed (unactivated + moderation-
  # hidden accounts never surface), same narrow listing-row select.
  defp most_endorsed_in_tag(source, tag) do
    import Vutuv.Moderation.Query, only: [account_hidden: 1, account_confirmed_row: 1]

    Vutuv.Repo.all(
      from(u in source,
        left_join: us in assoc(u, :user_tags),
        left_join: e in assoc(us, :endorsements),
        where: us.tag_id == ^tag.id,
        where: account_confirmed_row(u) and not account_hidden(u.id),
        # most endorsed
        order_by: fragment("count(?) DESC", e.id),
        group_by: u.id,
        limit: 10,
        select: struct(u, ^User.listing_fields())
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
