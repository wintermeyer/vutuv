defmodule Vutuv.Tags.Tag do
  @moduledoc false

  use VutuvWeb, :model
  @derive {Phoenix.Param, key: :slug}

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.WebAddress

  # A tag names a skill, a topic or an interest. A member who pastes their
  # homepage or their email address into the field is advertising, not tagging
  # themselves — and the tag becomes a public page nobody else will ever share.
  # Kept as one string so the name validation below and the link guard in
  # `create_or_link_tag/2` (which also covers *linking* a URL tag minted before
  # this rule) report the same thing.
  @web_address_message "must not be a web or email address"

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
    |> validate_web_address()
    |> validate_length(:slug, max: 60)
    |> validate_length(:name, max: 255)
    |> unique_constraint(:slug)
  end

  # A name that is nothing but a URL, a domain or an email address is refused
  # here, so no entry point can mint such a tag: the member paths reach this
  # through `create_or_link_tag/2`, the admin edit form and the post-hashtag
  # path (`Vutuv.Posts`) through the changeset heads directly. A name that only
  # *mentions* an address stays valid ("Frontend for shop.example"), the same
  # whole-value rule the profile tagline uses.
  defp validate_web_address(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if WebAddress.link_only?(name), do: [name: @web_address_message], else: []
    end)
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
  Puts a `:tag_id` change on the changeset for the tag matching the typed value,
  creating that tag first when none exists yet. The new tag is inserted here in
  its own `ON CONFLICT` statement (see `put_created_tag/2`) so concurrent callers
  sharing a tag get-or-create it idempotently instead of deadlocking — only an
  invalid name falls back to a nested `put_assoc` so its errors reach the caller.

  The value is one tag name and may contain spaces ("Ruby on Rails"): a
  multi-word value links to the existing spaced tag (case-insensitively) or
  creates it fresh, exactly like a single-word one. Callers that accept a batch
  (sign-up, the tags page, the post composer) tokenize their input first with
  `Vutuv.Tags.parse_tag_names/1`, which honours quotes; the JSON API reaches
  here with a single already-whole name.

  A value that is nothing but a web or email address is refused outright
  (`Vutuv.WebAddress`), before the lookup: the changeset head already keeps a
  new one from being minted, and this also blocks *linking* one of the URL tags
  a few profiles created before the rule existed.
  """
  def create_or_link_tag(changeset, %{"value" => value} = params) do
    # Strip the hashtag form before both the existing-tag lookup and the build,
    # so `#Elixir` links to `Elixir` (not a `#`-prefixed duplicate) and stores
    # the bare name. The rewritten params carry the normalized value downstream.
    value = normalize_value(value)
    params = Map.put(params, "value", value)

    if WebAddress.link_only?(value) do
      # The error lands on :tag_id, where the tags editor renders the other
      # refusals (at the ceiling, reserved honor tag) too.
      add_error(changeset, :tag_id, @web_address_message)
    else
      link_or_build_tag(changeset, value, params)
    end
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

    Repo.one(
      from(t in __MODULE__,
        where: fragment("lower(?)", t.name) == ^down or t.slug == ^down,
        limit: 1
      )
    )
  end

  defp link_or_build_tag(changeset, value, params) do
    case find_by_value(value) do
      nil -> put_created_tag(changeset, params)
      tag -> put_change(changeset, :tag_id, tag.id)
    end
  end

  # No committed tag matches the typed value, so mint one and link its id.
  #
  # The tag is INSERTed here in its own `ON CONFLICT DO NOTHING` statement rather
  # than deferred into the caller's `user_tag` insert as a nested `put_assoc`.
  # That is the deadlock fix: two concurrent sign-ups sharing a tag both reach
  # here with `find_by_value/1 == nil` (neither row is committed yet). The old
  # put_assoc path had each transaction INSERT the same `tags.slug`, and with
  # several tags per registration those unique-index waits chained into a cycle —
  # Postgres 40P01, the intermittent async-suite flake from register_user. With
  # ON CONFLICT the loser no-ops and re-reads the winner's row, and because the
  # tag insert is its own autocommit statement no transaction ever holds two
  # contended tag rows at once, so no cycle can form.
  #
  # That autocommit premise holds only in production. Under the test SQL
  # sandbox nothing commits: each test is one transaction that keeps the
  # unique-index lock on every slug it inserts until rollback, so two async
  # test modules minting the SAME tag name still convoy on it — and deadlock
  # when two contended slugs are acquired in opposite orders (the historical
  # 40P01 flake in register_user). The test-side rule is therefore that async
  # test modules never share literal tag names (see test/support/conn_case.ex
  # and the test guidelines in .claude/rules/elixir.md).
  defp put_created_tag(changeset, params) do
    tag_changeset = __MODULE__.changeset(%__MODULE__{}, params)

    if tag_changeset.valid? do
      slug = get_field(tag_changeset, :slug)

      tag =
        case Repo.insert(tag_changeset, on_conflict: :nothing, conflict_target: :slug) do
          {:ok, %__MODULE__{id: id} = tag} when not is_nil(id) -> tag
          # ON CONFLICT no-op'd (a racer committed this slug first): read its row.
          _ -> Repo.get_by(__MODULE__, slug: slug)
        end

      case tag do
        %__MODULE__{} = tag -> put_change(changeset, :tag_id, tag.id)
        nil -> put_assoc(changeset, :tag, tag_changeset)
      end
    else
      # Invalid name (blank, too long, stray control char): keep the nested-assoc
      # path so the user_tag changeset carries the tag's validation errors out.
      put_assoc(changeset, :tag, tag_changeset)
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

    Repo.all(
      from(u in source,
        left_join: us in assoc(u, :user_tags),
        left_join: e in assoc(us, :endorsements),
        # Count only endorsers who are currently publicly visible, the same gate
        # `Vutuv.Tags.UserTag.ordered_by_endorsements/1` and every visible count
        # apply. The test rides in the left-join ON clause, so a hidden or
        # unconfirmed endorser leaves `endorser` NULL and drops out of
        # count(endorser.id) — the ranking then agrees with the counts shown.
        left_join: endorser in assoc(e, :user),
        on: account_confirmed_row(endorser) and not account_hidden(endorser.id),
        where: us.tag_id == ^tag.id,
        where: account_confirmed_row(u) and not account_hidden(u.id),
        # most endorsed (by visible endorsers only)
        order_by: fragment("count(?) DESC", endorser.id),
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
