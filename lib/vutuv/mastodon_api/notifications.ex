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

  alias Vutuv.Accounts.User
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

  @doc """
  The account one notification names, as a single lookup.

  For the batch path (`/api/v1/notifications` renders a page at a time) the
  controller has its own two-query loader; this is for the callers that hold
  exactly one item, where a batch would be a batch of one.
  """
  def account(item) do
    case {item[:actor_id], item[:actor_kind]} do
      {nil, _kind} -> placeholder_account(item)
      {id, "organization"} -> lookup(Organization, id) || placeholder_account(item)
      {id, _member} -> lookup(User, id) || placeholder_account(item)
    end
  end

  @doc """
  The stand-in account for an actor with no vutuv profile — somebody on another
  network, whose handle is all `Vutuv.Activity` carries.

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

  defp lookup(schema, id) do
    case Repo.get(schema, id) do
      nil -> nil
      record -> Presenter.account(record)
    end
  end
end
