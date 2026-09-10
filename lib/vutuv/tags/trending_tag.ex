defmodule Vutuv.Tags.TrendingTag do
  @moduledoc """
  One tag that is suddenly busy on the servers this installation reads from
  (issue #2129) — a row of the offer the feed's tag card draws.

  It is a **cache, replaced wholesale by every pass**, not a record of anything
  ours: the name is a stranger's word, the figures are ten strangers' counters
  added up, and nothing here points at a `tags` row. A name may well name no
  topic on this installation at all; `Vutuv.Tags.Trending.follow/2` is what
  turns one into one.

  `history` is the seven daily totals, newest first, as the servers reported
  them — the evidence for **suddenly** rather than for **a lot**. `uses` is its
  first entry and `baseline` the median of the other six, both stored because
  the two numbers are what the offer was judged on and what the reader is shown.
  `servers` is how many of them listed it, and it is the only figure here
  without a second denominator: a pass asks every server it offers, so a tag
  that only three list is a tag only three list.

  `author_hosts`, `bot_posts` and `sampled` are the vetting sample: how many
  distinct author domains carried the tag, how many of those statuses came from
  accounts their own server flags as bots, out of how many statuses were looked
  at. They are the whole defence against a bot wave — measured, one tag trending
  on seven of nine servers had 40 of 40 statuses from a single domain and 39 of
  them flagged as bots — and they are kept rather than thrown away so an
  operator looking at a bad offer can see what was actually measured.
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Tags.Tag

  # A hashtag is `\\p{L}\\p{N}_` only (`Tag.hashtag_name/1`), so this is the
  # column's guard rather than a shape check — but it is a stranger's value and
  # the column is a varchar(255).
  @max_name 255

  @doc "The longest trending name stored — anything longer is not offered."
  def max_name, do: @max_name

  schema "tag_trends" do
    field(:name, :string)
    field(:uses, :integer)
    field(:baseline, :integer)
    field(:history, {:array, :integer})
    field(:servers, :integer)
    field(:hosts, {:array, :string})
    field(:author_hosts, :integer)
    field(:bot_posts, :integer)
    field(:sampled, :integer)
    field(:checked_at, :utc_datetime)

    timestamps()
  end

  @fields ~w(name uses baseline history servers hosts
             author_hosts bot_posts sampled checked_at)a
  @required ~w(name uses baseline history servers hosts checked_at)a

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, @fields)
    |> validate_required(@required)
    # Counted in **bytes**, the conservative unit: Postgres counts codepoints,
    # Ecto counts graphemes, and in UTF-8 the byte count can never be under the
    # codepoint count. A trending name is a stranger's value in a varchar(255).
    |> validate_length(:name, max: @max_name, count: :bytes)
    # A stored name has to be exactly what a `#hashtag` may hold, and
    # `Tag.hashtag_name/1` is where that charset lives — asked rather than
    # re-spelled as a regex, or the two drift the moment one of them learns
    # about a new character class.
    |> validate_change(:name, fn :name, name ->
      if Tag.hashtag_name(name) == name, do: [], else: [name: "is not a hashtag"]
    end)
    |> validate_number(:uses, greater_than_or_equal_to: 0)
    |> validate_number(:baseline, greater_than_or_equal_to: 0)
    |> validate_number(:servers, greater_than: 0)
    |> validate_hosts()
    |> unique_constraint(:name)
  end

  # Every host here came out of the operator's own `:tag_source_servers` list,
  # but the row is what `follow/2` later hands to `add_tag_follow_source/2`, so
  # the column carries the same bound the source column does.
  defp validate_hosts(changeset) do
    hosts = get_field(changeset, :hosts) || []

    if Enum.all?(hosts, &(is_binary(&1) and byte_size(&1) <= BlockedInstance.max_host())) do
      changeset
    else
      add_error(changeset, :hosts, "are not server names")
    end
  end

  @doc """
  The six days before today, oldest last — what the pill's little chart draws
  beside the bar for today.
  """
  def previous(%__MODULE__{history: [_today | rest]}), do: rest
  def previous(%__MODULE__{}), do: []
end
