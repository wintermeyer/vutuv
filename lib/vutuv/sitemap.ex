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

  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Tags.Tag

  @chunk_size 10_000

  # Keep `@dev_doc_pages` in sync with VutuvWeb.DevDocController's registry — a
  # drift test (sitemap_dev_docs_test.exs) fails the build if a dev-doc page is
  # added there without appearing in the sitemap.
  @dev_doc_pages ~w(authentication cookbook data-model reference webhooks)

  @static_paths [
                  "/",
                  "/community",
                  "/impressum",
                  "/datenschutzerklaerung",
                  "/nutzungsbedingungen",
                  "/listings/most_followed_users",
                  "/system/members",
                  "/companies",
                  "/ads",
                  "/tags",
                  "/developers"
                ] ++ Enum.map(@dev_doc_pages, &("/developers/" <> &1))

  def chunk_size, do: @chunk_size

  @doc """
  Pages of the static, always-present public pages (one chunk). `/ads` drops
  out while the ad system is switched off (`Vutuv.Ads.enabled?/0`), so the
  sitemap never points crawlers at a page that 404s.
  """
  def static_paths do
    if Vutuv.Ads.enabled?() do
      @static_paths
    else
      @static_paths -- ["/ads"]
    end
  end

  @doc """
  How many chunks each dynamic sitemap type currently has. An empty type
  has zero chunks and contributes no child sitemap.
  """
  def chunk_counts do
    %{
      users: chunks(Repo.aggregate(indexable_users(), :count)),
      posts: chunks(Repo.aggregate(indexable_posts(), :count)),
      tags: chunks(Repo.aggregate(Tag, :count)),
      companies: chunks(Repo.aggregate(indexable_companies(), :count))
    }
  end

  @doc "`{path, lastmod_date}` entries of one users chunk (1-based)."
  def user_entries(chunk) do
    indexable_users()
    |> order_by([u], u.id)
    |> window(chunk)
    |> select([u], {u.username, u.updated_at})
    |> Repo.all()
    |> Enum.map(fn {slug, updated_at} -> {"/" <> slug, NaiveDateTime.to_date(updated_at)} end)
  end

  @doc "`{path, lastmod_date}` entries of one posts chunk (1-based)."
  def post_entries(chunk) do
    indexable_posts()
    |> order_by([p], p.id)
    |> window(chunk)
    |> select([p, u], {u.username, p.id, p.updated_at})
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

  @doc "`{path, lastmod_date}` entries of one companies chunk (1-based)."
  def company_entries(chunk) do
    indexable_companies()
    |> order_by([c], c.id)
    |> window(chunk)
    |> select([c], {c.slug, c.updated_at})
    |> Repo.all()
    |> Enum.map(fn {slug, updated_at} ->
      {"/companies/" <> slug, NaiveDateTime.to_date(updated_at)}
    end)
  end

  # The crawlable company set lives in Vutuv.Companies (the /companies directory
  # rule), so directory and sitemap can never drift apart.
  defp indexable_companies, do: Vutuv.Companies.indexable_query()

  defp window(query, chunk) when is_integer(chunk) and chunk >= 1 do
    query |> limit(^@chunk_size) |> offset(^((chunk - 1) * @chunk_size))
  end

  # The crawlable member set lives in Vutuv.Directory (the /members pages),
  # so directory and sitemap can never drift apart.
  defp indexable_users, do: Vutuv.Directory.indexable_users()

  # scope_visible(nil) already drops restricted posts, frozen posts and
  # moderation-hidden authors; the join adds the member-level conditions.
  defp indexable_posts do
    Post
    |> Posts.scope_visible(nil)
    |> join(:inner, [p], u in assoc(p, :user))
    |> where([p, u], u.email_confirmed? and not u.noindex?)
  end

  defp chunks(0), do: 0
  defp chunks(count), do: div(count - 1, @chunk_size) + 1
end
