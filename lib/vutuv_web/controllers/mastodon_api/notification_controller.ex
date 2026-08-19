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

  alias Vutuv.Activity
  alias Vutuv.MastodonApi.Notifications
  alias Vutuv.MastodonApi.Presenter
  alias Vutuv.Posts
  alias Vutuv.UUIDv7
  alias VutuvWeb.MastodonApi.Pagination

  def index(conn, params) do
    page = Pagination.params(params, strip: &bare_id/1)
    read = load(conn, page)

    items =
      read
      |> Enum.filter(&mapped?/1)
      |> filter_types(params)
      |> Pagination.window(page, &bare_id/1)

    # What the **read** returned decides whether there is more, not what
    # survived the filter: a page of tag endorsements and CV updates maps to
    # nothing here, and calling that the end of the list would strand a client
    # above every older mention.
    more? = length(read) >= Pagination.fetch_size(page)

    conn
    |> Pagination.link_header(Enum.map(items, &bare_id/1), page, more?: more?)
    |> json(notifications(conn, items))
  end

  @doc """
  The **grouped** notifications a Mastodon 4.3+ client asks for
  (`GET /api/v2/notifications`).

  Not optional for us: this adapter advertises compatibility with 4.4, and a
  client reads that version to decide which endpoint to call. Ice Cubes does,
  so its whole notifications tab — and its "@ mentions" activity page, the same
  endpoint under a type filter — answered "an error occurred" against a server
  that served the v1 list perfectly well. Advertising a version is a promise
  about the shape of the API, not only about its features.

  The payload is the same items the v1 list serves, said differently: the
  accounts and statuses are hoisted into two shared lists and each group names
  them by id. vutuv's notifications are derived rather than stored, so a group
  is exactly the set of items that share a **type and a status** — several
  people liking one post is one group, which is the whole point of the shape —
  and anything without a status (a follow) groups by its own id.
  """
  def grouped(conn, params) do
    page = Pagination.params(params, strip: &bare_id/1)
    read = load(conn, page)

    items =
      read
      |> Enum.filter(&mapped?/1)
      |> filter_types(params)
      |> Pagination.window(page, &bare_id/1)

    more? = length(read) >= Pagination.fetch_size(page)
    rendered = notifications(conn, items)

    conn
    |> Pagination.link_header(Enum.map(items, &bare_id/1), page, more?: more?)
    |> json(%{
      accounts: rendered |> Enum.map(& &1.account) |> uniq_by_id(),
      statuses: rendered |> Enum.map(& &1.status) |> Enum.reject(&is_nil/1) |> uniq_by_id(),
      notification_groups: notification_groups(rendered)
    })
  end

  defp uniq_by_id(list), do: Enum.uniq_by(list, &(&1[:id] || &1["id"]))

  # Gathered across the **whole page**, not over consecutive runs. `chunk_by/2`
  # reads like grouping and is not: two likes on one post with a follow timed
  # between them came back as three groups, two of them carrying the identical
  # `favourite-<post id>` key and each counting one. A client keys its list by
  # that string, so a duplicate is not a cosmetic slip. Mastodon's own grouping
  # is over the whole page too.
  #
  # The order is first-appearance, which is newest-first because the page is:
  # `Enum.group_by/2` answers a map, and a map has no order to inherit.
  defp notification_groups(rendered) do
    by_key = Enum.group_by(rendered, &group_key/1)

    rendered
    |> Enum.map(&group_key/1)
    |> Enum.uniq()
    |> Enum.map(&notification_group(&1, Map.fetch!(by_key, &1)))
  end

  defp notification_group(key, [newest | _rest] = group) do
    ids = Enum.map(group, & &1.id)

    %{
      group_key: key,
      notifications_count: length(group),
      type: newest.type,
      most_recent_notification_id: newest.id,
      page_min_id: Enum.min(ids),
      page_max_id: Enum.max(ids),
      latest_page_notification_at: newest.created_at,
      # Mastodon's own `SAMPLE_ACCOUNTS_SIZE`.
      sample_account_ids: group |> Enum.map(& &1.account.id) |> Enum.uniq() |> Enum.take(8),
      status_id: newest.status[:id]
    }
  end

  # A group is one type over one status. Without a status there is nothing to
  # collapse onto, so the item is its own group.
  defp group_key(%{type: type, status: %{id: status_id}}), do: type <> "-" <> status_id
  defp group_key(%{id: id}), do: id

  @doc """
  One group (`GET /api/v2/notifications/:group_key`).

  The companion a 4.3+ client needs beside the grouped list: it opens a row from
  a push notification, from a deep link or after coming back to a stale list, and
  it has only the `group_key` the list gave it. Without this the call fell
  through to the adapter's 404, so the row a member tapped in the notification
  centre opened on an error.

  The key is looked for over the same window the grouped list pages
  (`@group_window`), not over all of history: a group is a description of a page
  of notifications — Mastodon's own grouping is per page too, which is why the
  entity carries `page_min_id` / `page_max_id` — so a key that has scrolled out
  of that window no longer names anything, and 404 is the honest answer rather
  than a group assembled from a different set of rows than the one the client
  was shown.
  """
  def group(conn, %{"group_key" => key}) do
    case group_members(conn, key) do
      [] -> not_found(conn)
      members -> json(conn, notification_group(key, members))
    end
  end

  @doc """
  The accounts behind one group (`GET /api/v2/notifications/:group_key/accounts`).

  What a client calls to fill "Alice, Bob and 4 others liked your post": the
  grouped list carries `sample_account_ids` only, and the full roster is this.
  """
  def group_accounts(conn, %{"group_key" => key}) do
    case group_members(conn, key) do
      [] -> not_found(conn)
      members -> json(conn, members |> Enum.map(& &1.account) |> uniq_by_id())
    end
  end

  @doc """
  Dismisses one group (`POST /api/v2/notifications/:group_key/dismiss`).

  Accepted and does nothing, for the same reason the per-item dismiss does:
  vutuv's notifications are derived from the likes and follows themselves, so
  there is no row to remove. A 404 here is what makes a client that swipes a row
  away show an error instead of letting it go.
  """
  def dismiss_group(conn, _params), do: json(conn, %{})

  # The page a group key is resolved against. Wider than a default request page,
  # because a client holds keys from a list it has scrolled, and narrow enough
  # that this stays one bounded read.
  @group_window 80

  defp group_members(conn, key) do
    conn
    |> load(%Pagination{limit: @group_window})
    |> Enum.filter(&(mapped?(&1) and possible_member?(&1, key)))
    |> then(&notifications(conn, &1))
    |> Enum.filter(&(group_key(&1) == key))
  end

  # Cut the window down before anything is looked up. Rendering costs a read of
  # every actor and every post in it (`notifications/2`), and a client fills
  # "Alice, Bob and 4 others" once per visible row, so rendering the whole
  # window per request meant paying for eighty notifications to keep three.
  #
  # A raw item can only ever land in a group named by its own id or by its type
  # and the post it is about, which is what this asks — deliberately a **wider**
  # net than the real key, because an item whose post the viewer may not see
  # renders without a status and then groups by its own id. The authoritative
  # filter above still runs on what came back.
  defp possible_member?(item, key) do
    item.id == key or (is_binary(item[:post_id]) and type(item) <> "-" <> item[:post_id] == key)
  end

  def show(conn, %{"id" => id}) do
    bare = bare_id(%{id: id})

    conn
    |> load(%Pagination{limit: 40})
    |> Enum.filter(&mapped?/1)
    |> Enum.find(&(bare_id(&1) == bare))
    |> case do
      nil -> not_found(conn)
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

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "Record not found"})

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

  defp mapped?(item), do: Notifications.mapped?(item)

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
    # Who each item names is `Notifications.accounts/1`'s answer — the same one
    # the streaming socket serves — keyed by item id, one query per actor kind.
    accounts = Notifications.accounts(items)
    statuses = load_statuses(conn, items)

    Enum.map(items, fn item ->
      %{
        id: item.id,
        type: type(item),
        created_at: timestamp(item.at),
        account: accounts[item.id],
        status: statuses[item[:post_id]]
      }
    end)
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

  defp type(item), do: Notifications.type(item)

  # A derived item's key is `<kind>-<uuid>`, and that whole string is the `id` a
  # client is given and hands back. Both shapes go through here: the item, when
  # the page is being cut and numbered, and the bare string, when it arrives as
  # a `max_id` and has to become the uuid the ordering is built on.
  defp bare_id(%{id: id}), do: bare_id(id)

  defp bare_id(id) when is_binary(id) do
    case String.split(id, "-", parts: 2) do
      [_prefix, rest] -> rest
      _plain -> id
    end
  end

  # One owner for the shape (see `Presenter.timestamp/1`): this used to be a
  # second copy of the same conversion, and it kept second precision after the
  # other was fixed — so every notification carried a date no client could
  # parse while the statuses beside them were fine.
  defp timestamp(at), do: Presenter.timestamp(at)
end
