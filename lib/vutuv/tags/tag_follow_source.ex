defmodule Vutuv.Tags.TagFollowSource do
  @moduledoc """
  Where a followed tag's posts should come from (issue #2125): one row per
  source of one `Vutuv.Tags.TagFollow`.

  A follow used to be a member and a topic with nowhere to say *where*. It now
  carries sources — `"vutuv"`, this installation, plus any server the member
  picked. A table rather than a list on the follow, because the fetcher asks the
  question the other way round: which server-and-tag pairs does anybody here
  want? That is one grouped query (`Vutuv.Tags.wanted_tag_sources/0`) instead of
  unpacking every member's array.

  `source` is either the literal `"vutuv"` or a bare, lowercased hostname —
  never a URL, never a handle. It is deliberately not called `host`: the local
  row is no host, and a caller building `https://\#{source}/tags/…` out of it
  would fetch nonsense. `normalize_source/1` is the one place that turns
  whatever a member pasted into one of the two shapes, and **an address of our
  own becomes the local source** rather than a server to poll: asking this
  installation for its own posts is the failure v7.197.0 already produced once,
  via `www.`, so `Vutuv.Fediverse.own_host?/1` answers that question here too.

  Nothing is stored per source but the source itself. What was fetched from it,
  and when, belongs to the fetcher (#2126) and not to the member's subscription.
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.BlockedInstance

  # The one spelling of "this installation". Not a hostname on purpose: it means
  # "here" on every installation, so it survives a rename of the site's host and
  # never has to be rewritten when `PHX_HOST` changes. It carries no dot, so it
  # cannot collide with a server name either.
  @local_source "vutuv"

  schema "tag_follow_sources" do
    field(:source, :string)

    belongs_to(:tag_follow, Vutuv.Tags.TagFollow)

    timestamps()
  end

  @doc "The source that means this installation."
  def local_source, do: @local_source

  def changeset(model, params \\ %{}) do
    model
    |> cast(params, [:tag_follow_id, :source])
    |> update_change(:source, &normalize_source/1)
    |> validate_required([:tag_follow_id, :source])
    |> validate_length(:source, max: BlockedInstance.max_host())
    |> validate_source()
    |> unique_constraint(:source,
      name: :tag_follow_sources_tag_follow_id_source_index,
      message: "This follow already reads that source."
    )
    |> foreign_key_constraint(:tag_follow_id)
  end

  @doc """
  The stored shape of whatever was offered: `"vutuv"` for the local source and
  for any address of this installation, a bare lowercased hostname for a remote
  server, `nil` when nothing host-shaped is left.
  """
  def normalize_source(@local_source), do: @local_source

  def normalize_source(value) when is_binary(value) do
    case BlockedInstance.normalize_host(value) do
      nil -> nil
      host -> if Fediverse.own_host?(host), do: @local_source, else: host
    end
  end

  def normalize_source(_), do: nil

  # Anything but the sentinel has to be a server name, in the one shape the
  # instance blocklist already defines — two definitions of "a real host" would
  # have to be loosened together the day an intranet or an IDN address needs one.
  defp validate_source(changeset) do
    case get_field(changeset, :source) do
      @local_source ->
        changeset

      _remote ->
        validate_format(changeset, :source, BlockedInstance.host_format(),
          message: "is not a server name"
        )
    end
  end
end
