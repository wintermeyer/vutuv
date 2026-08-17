defmodule VutuvWeb.MastodonApi.NotificationController do
  @moduledoc """
  The member's notifications, mapped onto Mastodon's vocabulary.

  vutuv's notifications are **derived**, not stored rows: `Vutuv.Activity`
  assembles them from the likes, follows, mentions and replies themselves, and
  `users.notifications_read_at` is a single marker rather than a per-row read
  flag. Two consequences a client meets:

    * there is nothing to dismiss one at a time, so `POST …/:id/dismiss` is
      accepted and does nothing rather than pretending to delete a row;
      `POST /api/v1/notifications/clear` moves the marker, which is what
      "mark all read" means here;
    * an id is the derived item's key (`like-<uuid>`), not a notification row's.

  **Only the kinds Mastodon actually has are served.** Inventing a `type` a
  client does not know is worse than leaving the item out — some clients drop
  an unknown notification, others show an empty row, and none of them can act
  on it. vutuv's own kinds (tag endorsements, CV updates, moderation cases,
  role grants, handle changes) therefore stay on the website, where they have a
  rendering that means something. What is left is the bulk of the traffic
  anyway: mentions, replies, likes and follows.
  """

  use VutuvWeb, :controller

  import Ecto.Query, only: [where: 3]

  alias Vutuv.Accounts.User
  alias Vutuv.Activity
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Repo
  alias Vutuv.UUIDv7
  alias VutuvWeb.MastodonApi.Pagination

  # vutuv kind -> Mastodon notification type. A reply and a thread answer both
  # arrive as `mention`, which is the type Mastodon uses for "somebody wrote to
  # you"; it has no separate reply type.
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

  def index(conn, params) do
    page = Pagination.params(params)

    items =
      conn
      |> load(page)
      |> Enum.filter(&mapped?/1)
      |> filter_types(params)
      |> Pagination.window(page, &bare_id/1)

    conn
    |> Pagination.link_header(Enum.map(items, &bare_id/1), page)
    |> json(notifications(conn, items))
  end

  def show(conn, %{"id" => id}) do
    bare = bare_id(%{id: id})

    conn
    |> load(%Pagination{limit: 40})
    |> Enum.filter(&mapped?/1)
    |> Enum.find(&(bare_id(&1) == bare))
    |> case do
      nil -> conn |> put_status(404) |> json(%{error: "Record not found"})
      item -> json(conn, hd(notifications(conn, [item])))
    end
  end

  def unread_count(conn, _params) do
    json(conn, %{count: Activity.unread_notification_count(conn.assigns.current_user.id)})
  end

  def clear(conn, _params) do
    Activity.mark_notifications_read(conn.assigns.current_user.id)
    json(conn, %{})
  end

  # Derived items cannot be deleted one at a time; answering 200 keeps a client
  # that swipes a row from treating it as a failure.
  def dismiss(conn, _params), do: json(conn, %{})

  defp load(conn, page) do
    conn.assigns.current_user.id
    |> Activity.notifications_page(limit: Pagination.fetch_size(page), cursor: cursor(page))
    |> Map.fetch!(:entries)
  end

  defp cursor(%Pagination{max_id: nil}), do: nil

  defp cursor(%Pagination{max_id: max_id}) do
    case UUIDv7.timestamp(max_id) do
      nil -> nil
      at -> %{at: at, ids: []}
    end
  end

  defp mapped?(item), do: Map.has_key?(@types, item.kind)

  # `types[]` and `exclude_types[]` are how a client's filter tabs ask for one
  # kind. Both are Mastodon types, not vutuv kinds.
  defp filter_types(items, params) do
    include = List.wrap(params["types"] || params["types[]"])
    exclude = List.wrap(params["exclude_types"] || params["exclude_types[]"])

    items
    |> then(fn list ->
      if include == [], do: list, else: Enum.filter(list, &(type(&1) in include))
    end)
    |> Enum.reject(&(type(&1) in exclude))
  end

  defp notifications(conn, items) do
    accounts = load_accounts(items)
    statuses = load_statuses(conn, items)

    Enum.map(items, fn item ->
      %{
        id: item.id,
        type: type(item),
        created_at: timestamp(item.at),
        account: accounts[item[:actor_id]] || placeholder_account(item),
        status: statuses[item[:post_id]]
      }
    end)
  end

  # One query per actor kind rather than one per row: a page of twenty
  # notifications is usually twenty different people.
  defp load_accounts(items) do
    {organizations, users} =
      items
      |> Enum.filter(& &1[:actor_id])
      |> Enum.split_with(&(&1[:actor_kind] == "organization"))

    Map.merge(
      accounts_by_id(User, Enum.map(users, & &1.actor_id)),
      accounts_by_id(Organization, Enum.map(organizations, & &1.actor_id))
    )
  end

  defp accounts_by_id(_schema, []), do: %{}

  defp accounts_by_id(schema, ids) do
    ids = Enum.uniq(ids)

    schema
    |> where([r], r.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, Presenter.account(&1)})
  end

  defp load_statuses(conn, items) do
    items
    |> Enum.map(& &1[:post_id])
    |> Enum.reject(&is_nil/1)
    |> then(&Posts.visible_posts_by_ids(conn.assigns.current_user, &1))
    |> then(fn by_id ->
      posts = Map.values(by_id)
      rendered = Presenter.statuses(posts, conn.assigns.current_user)

      posts |> Enum.map(& &1.id) |> Enum.zip(rendered) |> Map.new()
    end)
  end

  # Somebody on another network has no vutuv profile, so `Vutuv.Activity` leaves
  # the local actor fields nil and carries their handle instead. A Mastodon
  # notification must still name an account, so it is built from what there is.
  defp placeholder_account(item) do
    handle = item[:actor_handle] || item[:actor_name] || "unknown"

    %{
      id: "remote-actor-" <> Base.url_encode64(:crypto.hash(:sha256, handle), padding: false),
      username: handle |> String.trim_leading("@") |> String.split("@") |> hd(),
      acct: String.trim_leading(handle, "@"),
      display_name: item[:actor_name] || handle,
      url: item[:actor_url],
      avatar: nil,
      created_at: nil,
      group: false
    }
  end

  defp type(item), do: Map.fetch!(@types, item.kind)

  defp bare_id(%{id: id}) do
    case String.split(id, "-", parts: 2) do
      [_prefix, rest] -> rest
      _plain -> id
    end
  end

  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp timestamp(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp timestamp(_missing), do: nil
end
