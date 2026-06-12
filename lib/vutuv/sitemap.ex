defmodule Vutuv.Sitemap do
  @moduledoc """
  The queries behind /sitemap.xml: which public pages a crawler should
  index, in chunks bounded by `chunk_size/0` so no request loads an
  unbounded row set. Only the anonymous view counts — activated, indexable
  (`noindex?: false`, not moderation-hidden) members, their unrestricted
  posts, and the tag pages.

  Chunks are plain limit/offset windows ordered by the UUID v7 primary key
  (creation order). Should offset depth ever hurt at scale, the upgrade
  path is keyset windows on `id` — the ordering already supports it.
  """

  import Ecto.Query
  import Vutuv.Moderation.Query

  alias Vutuv.Accounts.User
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Tags.Tag

  @chunk_size 10_000

  @static_paths [
                  "/",
                  "/community",
                  "/impressum",
                  "/datenschutzerklaerung",
                  "/listings/most_followed_users",
                  "/ads",
                  "/tags",
                  "/developers"
                ] ++ Enum.map(~w(authentication reference webhooks), &("/developers/" <> &1))

  def chunk_size, do: @chunk_size

  @doc "Pages of the static, always-present public pages (one chunk)."
  def static_paths, do: @static_paths

  @doc """
  How many chunks each dynamic sitemap type currently has. An empty type
  has zero chunks and contributes no child sitemap.
  """
  def chunk_counts do
    %{
      users: chunks(Repo.aggregate(indexable_users(), :count)),
      posts: chunks(Repo.aggregate(indexable_posts(), :count)),
      tags: chunks(Repo.aggregate(Tag, :count))
    }
  end

  @doc "`{path, lastmod_date}` entries of one users chunk (1-based)."
  def user_entries(chunk) do
    indexable_users()
    |> order_by([u], u.id)
    |> window(chunk)
    |> select([u], {u.active_slug, u.updated_at})
    |> Repo.all()
    |> Enum.map(fn {slug, updated_at} -> {"/" <> slug, NaiveDateTime.to_date(updated_at)} end)
  end

  @doc "`{path, lastmod_date}` entries of one posts chunk (1-based)."
  def post_entries(chunk) do
    indexable_posts()
    |> order_by([p], p.id)
    |> window(chunk)
    |> select([p, u], {u.active_slug, p.id, p.updated_at})
    |> Repo.all()
    |> Enum.map(fn {slug, id, updated_at} ->
      {"/#{slug}/posts/#{id}", NaiveDateTime.to_date(updated_at)}
    end)
  end

  @doc "`{path, lastmod_date}` entries of one tags chunk (1-based)."
  def tag_entries(chunk) do
    Tag
    |> order_by([t], t.id)
    |> window(chunk)
    |> select([t], {t.slug, t.updated_at})
    |> Repo.all()
    |> Enum.map(fn {slug, updated_at} ->
      {"/tags/" <> slug, NaiveDateTime.to_date(updated_at)}
    end)
  end

  defp window(query, chunk) when is_integer(chunk) and chunk >= 1 do
    query |> limit(^@chunk_size) |> offset(^((chunk - 1) * @chunk_size))
  end

  defp indexable_users do
    from(u in User, where: u.activated? and not u.noindex? and not account_hidden(u.id))
  end

  # scope_visible(nil) already drops restricted posts, frozen posts and
  # moderation-hidden authors; the join adds the member-level conditions.
  defp indexable_posts do
    Post
    |> Posts.scope_visible(nil)
    |> join(:inner, [p], u in assoc(p, :user))
    |> where([p, u], u.activated? and not u.noindex?)
  end

  defp chunks(0), do: 0
  defp chunks(count), do: div(count - 1, @chunk_size) + 1
end
