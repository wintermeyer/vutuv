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
  A remote host is folded the same way — `www.mastodon.social` is stored as
  `mastodon.social`, because `www.` is the same site on both sides of the
  question and two spellings would be a duplicate row and a duplicate fetch.

  What a member types here is **fetched later, by us** (#2126), so the row is a
  stored SSRF target and the changeset carries the same two-layer guard
  `Vutuv.Organizations.OrganizationDomain` uses for a domain somebody claims:
  the server-name grammar, and `Vutuv.Ssrf.internal_host?/1` on top of it — the
  grammar alone accepts `169.254.169.254`. That check is literal-only (no DNS in
  a changeset), so a hostname that *resolves* somewhere internal still has to be
  vetted at fetch time with `Vutuv.Ssrf.resolves_to_internal?/1` or
  `vetted_address/1`.

  Nothing is stored per source but the source itself. What was fetched from it,
  and when, belongs to the fetcher (#2126) and not to the member's subscription.
  """

  use VutuvWeb, :model

  alias Vutuv.Fediverse
  alias Vutuv.Fediverse.BlockedInstance
  alias Vutuv.Ssrf

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
  server (its `www.` folded away), `nil` when nothing host-shaped is left.
  """
  def normalize_source(@local_source), do: @local_source

  def normalize_source(value) when is_binary(value) do
    case BlockedInstance.normalize_host(value) do
      nil -> nil
      # Serving a site at both the apex and its `www.` alias is the oldest
      # convention on the web, and `own_host?/1` already reads the two as one
      # for our own address. Nothing about that is local, so a remote server is
      # folded by the same function: otherwise `www.mastodon.social` is a
      # second row beside `mastodon.social`, fetched separately, answering with
      # the same posts.
      host -> if Fediverse.own_host?(host), do: @local_source, else: Fediverse.strip_www(host)
    end
  end

  def normalize_source(_), do: nil

  # Two layers, the shape `Vutuv.Organizations.OrganizationDomain` already uses
  # for a member-supplied host that we will later fetch from: the server-name
  # grammar the instance blocklist defines (one definition of "a real host", so
  # an intranet or IDN address loosens both at once), and then the SSRF check —
  # the grammar accepts `169.254.169.254` and every private range, since it was
  # written to keep useless entries out of a blocklist, not to keep a fetcher
  # off the metadata service.
  defp validate_source(changeset) do
    case get_field(changeset, :source) do
      nil -> changeset
      @local_source -> changeset
      host -> validate_remote_host(changeset, host)
    end
  end

  defp validate_remote_host(changeset, host) do
    cond do
      not Regex.match?(BlockedInstance.host_format(), host) ->
        add_error(changeset, :source, "is not a server name")

      Ssrf.internal_host?(host) ->
        add_error(changeset, :source, "is not an allowed server")

      true ->
        changeset
    end
  end
end
