defmodule Vutuv.MastodonApi.Notifications do
  @moduledoc """
  The one mapping from a vutuv notification kind to a Mastodon notification
  type, and the account a notification names.

  **One table, three readers.** The REST endpoint, the Web Push fan-out and the
  streaming socket all have to agree about what a notification *is*, and while
  the table was written out twice they did not: the socket had no copy at all
  and sent the raw vutuv kind as the `type`, so a client was told `"like"` where
  the same notification came back from `/api/v1/notifications` as `"favourite"`,
  and kinds Mastodon has no type for (a tag endorsement, a CV update, a
  moderation case) went out over the socket under names no client can render or
  act on. That is the thing `VutuvWeb.MastodonApi.NotificationController` refuses
  to do on purpose — inventing a type is worse than leaving the item out — so
  the refusal has to live where every reader passes, not in one of them.

  `mapped?/1` is therefore the whole filter: a kind that is not in this table is
  not served, not pushed and not streamed.
  """

  import Ecto.Query, only: [where: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.Fediverse
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Organizations.Organization
  alias Vutuv.Repo

  # A reply and a thread answer both arrive as `mention`, which is the type
  # Mastodon uses for "somebody wrote to you"; it has no separate reply type.
  @types %{
    "mention" => "mention",
    "reply" => "mention",
    "thread" => "mention",
    "fediverse_reply" => "mention",
    "like" => "favourite",
    "fediverse_reaction" => "favourite",
    "follower" => "follow",
    "connection" => "follow"
  }

  @doc "Every Mastodon type this adapter can produce."
  def types, do: @types |> Map.values() |> Enum.uniq()

  @doc "The Mastodon type for a vutuv kind or notification item, or `nil`."
  def type(%{kind: kind}), do: @types[kind]
  def type(kind) when is_binary(kind), do: @types[kind]
  def type(_other), do: nil

  @doc "Whether this kind is one Mastodon has a type for."
  def mapped?(item), do: not is_nil(type(item))

  @doc "The account one notification names — `accounts/1` for a single item."
  def account(item), do: accounts([item])[item[:id]]

  @doc """
  The accounts a page of items names, rendered and keyed by **item id** — one
  query per actor kind (members, pages, cached remote accounts) rather than
  one per row. Both readers that name an actor — the REST controller and the
  streaming socket — render through here, for the same reason the type table
  lives here: two copies of "who is this" is how they come to disagree.

  A remote actor has no vutuv profile, so `Vutuv.Activity` carries only their
  handle and actor URI — but whoever's reply or reaction was stored got a
  `RemoteAccount` row too, gate-cleared avatar included, found under that URI
  and rendered through `Presenter.account/1`, the chokepoint the status path
  uses (issue #1598). So the actor and their statuses are one account to a
  client, face and all. Only an actor whose row is gone, or whom nobody here
  ever stored, falls back to `placeholder_account/1`.
  """
  def accounts(items) do
    {remote, local} = Enum.split_with(items, &is_nil(&1[:actor_id]))
    {organizations, users} = Enum.split_with(local, &(&1[:actor_kind] == "organization"))

    # A local actor is keyed by row id, a remote one by actor URI; the two
    # keyspaces cannot collide.
    resolved =
      Map.merge(
        accounts_by_id(User, Enum.map(users, & &1.actor_id)),
        Map.merge(
          accounts_by_id(Organization, Enum.map(organizations, & &1.actor_id)),
          remote_accounts(remote)
        )
      )

    Map.new(items, fn item ->
      {item[:id], resolved[item[:actor_id] || item[:actor_url]] || placeholder_account(item)}
    end)
  end

  @doc """
  The stand-in account for a remote actor nobody here ever stored — then their
  handle really is all `Vutuv.Activity` carries.

  Built through `Presenter.base_account/1` like every other account this adapter
  renders, so it carries the keys a client reads unconditionally (`emojis`,
  `fields`, `note`, the counts). A hand-built map missing them is how a client
  gets a `nil` where it expects a list.
  """
  def placeholder_account(item) do
    handle = item[:actor_handle] || item[:actor_name] || "unknown"

    Presenter.base_account(%{
      id: "remote-actor-" <> Base.url_encode64(:crypto.hash(:sha256, handle), padding: false),
      username: handle |> String.trim_leading("@") |> String.split("@") |> hd(),
      acct: String.trim_leading(handle, "@"),
      display_name: item[:actor_name] || handle,
      url: item[:actor_url],
      avatar: Presenter.fallback_avatar(),
      created_at: nil,
      group: false
    })
  end

  defp accounts_by_id(_schema, []), do: %{}

  defp accounts_by_id(schema, ids) do
    schema
    |> where([r], r.id in ^Enum.uniq(ids))
    |> Repo.all()
    |> Map.new(&{&1.id, Presenter.account(&1)})
  end

  defp remote_accounts(items) do
    items
    |> Enum.map(& &1[:actor_url])
    |> Fediverse.remote_accounts_by_uris()
    |> Map.new(fn {uri, account} -> {uri, Presenter.account(account)} end)
  end
end
