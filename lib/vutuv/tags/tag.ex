defmodule Vutuv.Tags.Tag do
  @moduledoc false

  use VutuvWeb, :model
  @derive {Phoenix.Param, key: :slug}

  require Vutuv.Tags.MatchKey

  alias Vutuv.Accounts.User
  alias Vutuv.Repo
  alias Vutuv.Tags.MatchKey
  alias Vutuv.WebAddress

  # A tag names a skill, a topic or an interest. A member who pastes their
  # homepage or their email address into the field is advertising, not tagging
  # themselves — and the tag becomes a public page nobody else will ever share.
  # Kept as one string so the name validation below and the link guard in
  # `create_or_link_tag/2` (which also covers *linking* a URL tag minted before
  # this rule) report the same thing.
  @web_address_message "must not be a web or email address"

  # The other way a value names no topic: it is punctuation and nothing else
  # ("-", ".", "???"). Nobody searches for it, nobody else can share it, and the
  # slug it generates — the tag page's URL — is just as empty. Three such tags
  # exist from before this rule; they stay, but no new one is minted or linked
  # (see `punctuation_only?/1` and the guard in `create_or_link_tag/2`).
  @punctuation_message "must not be only punctuation"

  # A live tag's slug doubles as its fediverse actor name (#1330), so it may
  # hold only what the narrowest local part out there accepts.
  @slug_grammar_message "may contain only lowercase letters, digits and underscores"

  # The `#` belongs to the hashtag *notation*, never to the tag. Every member
  # path already strips it (`normalize_value/1`), so this only fires where a
  # name is cast raw — the admin edit form — and it fires loudly rather than
  # minting the `#`-prefixed twin of a tag that already exists. The catalog
  # still holds a couple of dozen such rows from before the strip;
  # `validate_change/3` runs only on a change, so they stay editable — the same
  # way the punctuation rule leaves its three legacy rows alone.
  @leading_hash_message "must not start with #"

  # What counts as content: anything that is not punctuation (`\p{P}`), a
  # separator/whitespace (`\p{Z}`) or an invisible control character (`\p{C}`).
  # Letters and digits, of course — and **symbols** (`\p{S}`), which is what
  # makes an emoji a tag of its own ("☕", "🎸"): an emoji is a name people
  # actually use and search for, unlike a run of question marks.
  @content_char ~r/[^\p{P}\p{Z}\p{C}]/u

  # The three things an alternative name for a topic can be (issue #1338).
  # There is deliberately no `misspelling`: a typo is unbounded, a near-miss
  # pair is exactly where a wrong merge does the most damage, and catching one
  # buys almost nothing — so a misspelled tag stays its own tag.
  @alias_kinds ~w(alias abbreviation former)

  schema "tags" do
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    # When true the tag is reserved site-wide: only site admins can assign or
    # remove it (the "vutuv_developer" badge). Set only through the admin edit
    # form / the generic changeset head — never the member "value" head below.
    field(:honor?, :boolean, default: false)

    # Set when this tag is an alternative name for another one (issue #1338):
    # `rails`, `ROR` and `rubyonrails` all point at `Ruby on Rails`. Such a row
    # is never a topic of its own — it keeps its slug so old links resolve, and
    # every listing leaves it out (`not_merged/1`).
    belongs_to(:merged_into, __MODULE__)
    field(:alias_kind, :string)

    has_many(:user_tags, Vutuv.Tags.UserTag)
    has_many(:aliases, __MODULE__, foreign_key: :merged_into_id)

    timestamps()
  end

  @doc "The kinds an alternative name can have: #{inspect(@alias_kinds)}."
  def alias_kinds, do: @alias_kinds

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
    |> validate_punctuation_only()
    |> validate_leading_hash()
    |> validate_length(:slug, max: 60)
    |> validate_length(:name, max: 255)
    |> validate_slug_grammar()
    |> unique_constraint(:slug)
    |> check_constraint(:slug,
      name: :tags_slug_actor_grammar,
      message: @slug_grammar_message
    )
  end

  # A live tag's slug is also the name of its fediverse actor (#1330), so it
  # lives in the narrowest local part any server accepts — the same grammar
  # `Vutuv.Handles` enforces for a member handle. `gen_slug/2` produces nothing
  # else; this is here for the admin edit form, which casts `:slug` straight
  # from a text field, and it runs only on a **change**, so an alias row keeping
  # its retired spelling is untouched (that spelling is the whole reason the row
  # exists).
  #
  # The database says the same thing (`tags_slug_actor_grammar`); the
  # `check_constraint` above turns a race into a field error rather than a 500.
  defp validate_slug_grammar(changeset) do
    if get_field(changeset, :merged_into_id) do
      changeset
    else
      validate_format(changeset, :slug, ~r/^[a-z0-9_]+$/, message: @slug_grammar_message)
    end
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

  defp validate_punctuation_only(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if punctuation_only?(name), do: [name: @punctuation_message], else: []
    end)
  end

  # Only a *leading* `#` is refused: `C#`, `F#` and `fitness#stuff` are ordinary
  # names, and the slug grammar above already keeps a `#` out of the URL.
  defp validate_leading_hash(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      if String.starts_with?(name, "#"), do: [name: @leading_hash_message], else: []
    end)
  end

  @doc """
  Whether `name` is punctuation (and whitespace) and nothing else, so it can't
  be a tag: `"-"`, `"."`, `"???"`, `"!!!"`. One character of actual content
  anywhere is enough, and a **symbol counts as content**, so `"C#"`, `"C++"`,
  `"3D"` and an emoji tag like `"☕"` are all ordinary tags.

  Both refusal points call this: the `changeset/2` heads (so no path mints such
  a tag) and `create_or_link_tag/2` (so none of the three legacy ones can be
  linked either — that path resolves an existing tag by lookup and would never
  build a changeset). Callers that quietly skip unusable values rather than
  erroring — the add-tag preview, post tags — filter on it too.
  """
  def punctuation_only?(name) when is_binary(name), do: not Regex.match?(@content_char, name)
  def punctuation_only?(_), do: true

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
    slug = Vutuv.SlugHelpers.gen_tag_slug_unique(value, __MODULE__, :slug)
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
  `Vutuv.Tags.parse_tag_names/1`, which splits on commas only; the JSON API reaches
  here with a single already-whole name.

  A value that names no topic is refused outright, before the lookup: one that
  is nothing but a web or email address (`Vutuv.WebAddress`), and one that is
  only punctuation (`punctuation_only?/1`). The changeset heads already keep
  such a tag from being minted; refusing here also blocks *linking* the handful
  of URL and punctuation tags that exist from before these rules.
  """
  def create_or_link_tag(changeset, %{"value" => value} = params) do
    # Strip the hashtag form before both the existing-tag lookup and the build,
    # so `#Elixir` links to `Elixir` (not a `#`-prefixed duplicate) and stores
    # the bare name. The rewritten params carry the normalized value downstream.
    value = normalize_value(value)
    params = Map.put(params, "value", value)

    # The errors land on :tag_id, where the tags editor renders the other
    # refusals (at the ceiling, reserved honor tag) too.
    cond do
      WebAddress.link_only?(value) -> add_error(changeset, :tag_id, @web_address_message)
      punctuation_only?(value) -> add_error(changeset, :tag_id, @punctuation_message)
      true -> link_or_build_tag(changeset, value, params)
    end
  end

  @doc """
  Whether `name` names a topic at all — the two refusals every tag path applies
  before it looks anything up: a value that is nothing but a web or email
  address, and one that is only punctuation.

  One predicate because four places ask it and they must not drift: this
  module's `create_or_link_tag/2` (which refuses with a *reason*, so it keeps
  its own `cond`), `Vutuv.Tags.preview_tag_names/1`, `Vutuv.Posts`' composer tag
  field and `Vutuv.Tags.mintable_hashtag?/1` — the last three quietly drop such
  a value rather than failing the save. `changeset/2` refuses them again at the
  insert, so this is the early filter, never the only one.
  """
  def names_a_topic?(name) when is_binary(name) do
    not (punctuation_only?(name) or WebAddress.link_only?(name))
  end

  def names_a_topic?(_), do: false

  # Every `#` the value opens with, plus the whitespace between them: the class
  # is greedy up to the last `#` it can still reach, so `"## # Elixir"` loses
  # all three while `"#fitness#stuff"` loses only the first (`f` ends the run).
  @leading_hash ~r/^[\s#]*#/u

  @doc """
  Normalizes a typed tag value: trims it, strips **every** leading `#` (the
  hashtag form members naturally type, since posts render `#hashtag` links, so
  `"#elixir"` is stored as the tag `elixir` and links to the same global tag as
  `"elixir"` rather than a `#`-prefixed duplicate; `"## # Elixir"` is the same
  tag again). Only a *leading* `#` goes, so `"C#"` / `"F#"` keep their trailing
  one and `"fitness#stuff"` its interior one. Then every interior run of
  whitespace collapses to a single space, so a multi-word tag is stored cleanly
  (`"Ruby   on  Rails"` and a pasted `"Ruby\\non Rails"` both become
  `"Ruby on Rails"`). A value that is nothing but `#` normalizes to `""`
  (dropped as blank by the tokenizer, rejected by the changeset). Applied at
  every tag-value boundary: `Vutuv.Tags.parse_tag_names/1`, `Vutuv.Posts` post
  tags, `create_or_link_tag/2` and `changeset/2`; the changeset then *refuses* a
  leading `#` outright (`@leading_hash_message`), so the raw name heads no entry
  point normalizes — the admin edit form — cannot store one either.
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
    case MatchKey.normalize(value) do
      nil -> nil
      key -> value |> by_match_key(key) |> follow_alias()
    end
  end

  # The catalog still holds both spellings of a few topics (#1332 normalizes the
  # column; until it has, `phoenix-framework` and `phoenix_framework` are two
  # rows with one key), so which row a folded key finds must not depend on the
  # planner: an exact hit on the name wins, then an exact hit on the slug, then
  # the oldest row — ids are UUID v7, so that is the first spelling written.
  defp by_match_key(value, key) do
    down = String.downcase(value)

    from(t in __MODULE__,
      where: MatchKey.sql(t.name) == ^key or MatchKey.sql(t.slug) == ^key,
      order_by: [
        asc:
          fragment(
            "case when lower(?) = ? then 0 when ? = ? then 1 else 2 end",
            t.name,
            ^down,
            t.slug,
            ^down
          ),
        asc: t.id
      ],
      limit: 1
    )
    |> Repo.one()
  end

  # An alias is a tag row pointing at its canonical (issue #1338), so a value
  # naming one resolves to the topic rather than to the alias. One hop is the
  # whole rule — an alias may never point at another alias, which
  # `Vutuv.Tags.Merge` refuses — so nothing here recurses. A canonical tag
  # costs one query as before; only an alias costs the second.
  defp follow_alias(nil), do: nil
  defp follow_alias(%__MODULE__{merged_into_id: nil} = tag), do: tag
  defp follow_alias(%__MODULE__{merged_into_id: id} = tag), do: Repo.get(__MODULE__, id) || tag

  @doc """
  What to call this tag on screen: the name its first writer gave it, falling
  back to the slug for a struct built without one (the column is NOT NULL, but
  it does allow a blank).

  One owner, because the answer now reaches further than a heading: it is the
  page's `<h1>`, its `<title>` and `og:title`, and the topic named in its meta
  description, and a page whose title says one thing while its heading says
  another is a page a search engine has to guess about.
  """
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{slug: slug}), do: slug

  @doc """
  The topic a tag stands for: itself, or the tag it is an alternative name for.

  Takes a loaded `%Tag{}` and answers without a query when the association is
  already loaded, which is the common case on a page that has just listed a
  tag's aliases.
  """
  def canonical(%__MODULE__{merged_into_id: nil} = tag), do: tag
  def canonical(%__MODULE__{merged_into: %__MODULE__{} = canonical}), do: canonical
  def canonical(%__MODULE__{merged_into_id: id}), do: Repo.get(__MODULE__, id)

  @doc """
  Whether this tag is an alternative name for another one, rather than a topic
  of its own.
  """
  def merged?(%__MODULE__{merged_into_id: id}), do: not is_nil(id)

  @doc """
  Narrows a tag query to real topics, leaving out every alternative name.

  **Every listing, search and count owes this call.** A tag query that forgets
  it puts the second page for one topic back in front of a reader, which is the
  bug issue #1338 exists to remove and which nothing else would report.
  `test/vutuv/tags/merged_tags_hidden_test.exs` walks the surfaces one by one.
  """
  def not_merged(query \\ __MODULE__), do: from(t in query, where: is_nil(t.merged_into_id))

  @doc """
  The alternative names filed under `tag`, oldest first.
  """
  def aliases_of(%__MODULE__{id: id}) do
    Repo.all(from(t in __MODULE__, where: t.merged_into_id == ^id, order_by: t.id))
  end

  @doc """
  Points `tag` at `canonical` as an alternative name of the given kind.

  The kind is validated here rather than in `changeset/2` because it only means
  anything alongside the pointer: a canonical tag carries neither.
  """
  def alias_changeset(%__MODULE__{} = tag, %__MODULE__{} = canonical, kind) do
    tag
    |> cast(%{alias_kind: kind}, [:alias_kind])
    |> put_change(:merged_into_id, canonical.id)
    |> validate_required([:alias_kind])
    |> validate_inclusion(:alias_kind, @alias_kinds)
  end

  defp link_or_build_tag(changeset, value, params) do
    case find_by_value(value) do
      nil -> put_created_tag(changeset, params)
      tag -> put_change(changeset, :tag_id, tag.id)
    end
  end

  # No committed tag matches the typed value, so mint one and link its id.
  # `insert_new/1` owns the insert (and the deadlock fix its doc explains);
  # this head only decides what to do with the changeset either way.
  defp put_created_tag(changeset, params) do
    tag_changeset = __MODULE__.changeset(%__MODULE__{}, params)

    case insert_new(tag_changeset) do
      %__MODULE__{} = tag ->
        put_change(changeset, :tag_id, tag.id)

      # Invalid name (blank, too long, stray control char), or a racer whose row
      # we could not read back: keep the nested-assoc path so the user_tag
      # changeset carries the tag's validation errors out.
      nil ->
        put_assoc(changeset, :tag, tag_changeset)
    end
  end

  @doc """
  Inserts the tag `tag_changeset` builds and returns it, or `nil` when the
  changeset is invalid.

  **The one place a tag row is created**, because the `ON CONFLICT` above is not
  an optimisation but the fix for a Postgres 40P01: two concurrent callers
  minting the same tag both reach here with `find_by_value/1 == nil` (neither
  row is committed yet), and with several tags per request the unique-index
  waits chained into a cycle — the intermittent async-suite flake from
  `register_user`. With `ON CONFLICT` the loser no-ops and re-reads the winner's
  row, and because the insert is its own autocommit statement no transaction
  ever holds two contended tag rows at once, so no cycle can form.

  That matters more since a `#hashtag` mints too (`Vutuv.Tags.tag_ids_for_hashtags/2`):
  one post can now create the composer's five chips *and* five tags its body
  names, in one request — exactly the shape the deadlock needs. So both mints
  come through here rather than each spelling its own insert.

  That autocommit premise holds only in production. Under the test SQL sandbox
  nothing commits: each test is one transaction that keeps the unique-index lock
  on every slug it inserts until rollback, so two async test modules minting the
  SAME tag name still convoy on it. The test-side rule is therefore that async
  test modules never share literal tag names (see `test/support/conn_case.ex`
  and the test guidelines in `.claude/rules/elixir.md`).
  """
  def insert_new(%Ecto.Changeset{} = tag_changeset) do
    if tag_changeset.valid? do
      slug = get_field(tag_changeset, :slug)

      case Repo.insert(tag_changeset, on_conflict: :nothing, conflict_target: :slug) do
        {:ok, %__MODULE__{id: id} = tag} when not is_nil(id) -> tag
        # ON CONFLICT no-op'd (a racer committed this slug first): read its row.
        _ -> Repo.get_by(__MODULE__, slug: slug)
      end
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
    import Vutuv.Moderation.Query, only: [account_hidden_row: 1, account_confirmed_row: 1]

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
        on: account_confirmed_row(endorser) and not account_hidden_row(endorser),
        where: us.tag_id == ^tag.id,
        where: account_confirmed_row(u) and not account_hidden_row(u),
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
