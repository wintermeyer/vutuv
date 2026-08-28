defmodule Vutuv.Sitemap do
  @moduledoc """
  The queries behind /sitemap.xml: which public pages a crawler should
  index, in chunks bounded by `chunk_size/0` so no request loads an
  unbounded row set. Only the anonymous view counts — activated, indexable
  (`noindex?: false`, not moderation-hidden) members, their unrestricted
  posts, and the tag pages above the search-engine bar
  (`Vutuv.Tags.indexable_tags_query/0` — enough visible members or a public
  post; the thin rest is noindexed by `VutuvWeb.TagController`).

  Chunks are plain limit/offset windows ordered by the UUID v7 primary key
  (creation order). Should offset depth ever hurt at scale, the upgrade
  path is keyset windows on `id` — the ordering already supports it.
  """

  import Ecto.Query

  alias Vutuv.Organizations.Organization
  alias Vutuv.Posts
  alias Vutuv.Posts.Post
  alias Vutuv.Repo
  alias Vutuv.Tags

  @chunk_size 10_000

  # Keep `@dev_doc_pages` in sync with VutuvWeb.DevDocController's registry — a
  # drift test (sitemap_dev_docs_test.exs) fails the build if a dev-doc page is
  # added there without appearing in the sitemap.
  @dev_doc_pages ~w(authentication cookbook data-model reference jobs webhooks)

  @static_paths [
                  "/",
                  "/community",
                  "/impressum",
                  "/datenschutzerklaerung",
                  "/nutzungsbedingungen",
                  "/listings/most_followed_users",
                  "/system/members",
                  "/system/markdown",
                  "/organizations",
                  "/jobs",
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
      tags: chunks(Repo.aggregate(Tags.indexable_tags_query(), :count)),
      organizations: chunks(Repo.aggregate(indexable_organizations(), :count)),
      organization_posts: chunks(Repo.aggregate(indexable_organization_posts(), :count)),
      jobs: chunks(Repo.aggregate(indexable_jobs(), :count))
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

  @doc """
  `{path, lastmod_date}` entries of one organization-posts chunk (1-based).

  Its own type rather than a widened `post_entries/1`: that one inner-joins
  `users` to read the author's handle for the URL and to honour their
  `noindex?`, and an organization post has neither — its URL is built from the
  page's slug and its indexability is the page's `seo?` flag. Without this the
  join simply dropped every one of them from the sitemap, silently.
  """
  def organization_post_entries(chunk) do
    indexable_organization_posts()
    |> order_by([p], p.id)
    |> window(chunk)
    |> select([p, o], {o.slug, p.id, p.updated_at})
    |> Repo.all()
    |> Enum.map(fn {slug, id, updated_at} ->
      {"/organizations/#{slug}/posts/#{id}", NaiveDateTime.to_date(updated_at)}
    end)
  end

  @doc "`{path, lastmod_date}` entries of one tags chunk (1-based)."
  def tag_entries(chunk) do
    Tags.indexable_tags_query()
    |> order_by([t], t.id)
    |> window(chunk)
    |> select([t], {t.slug, t.updated_at})
    |> Repo.all()
    |> Enum.map(fn {slug, updated_at} ->
      {"/tags/" <> slug, NaiveDateTime.to_date(updated_at)}
    end)
  end

  @doc "`{path, lastmod_date}` entries of one organizations chunk (1-based)."
  def organization_entries(chunk) do
    indexable_organizations()
    |> order_by([c], c.id)
    |> window(chunk)
    |> select([c], {c.slug, c.username, c.updated_at})
    |> Repo.all()
    |> Enum.map(fn {slug, username, updated_at} ->
      # An organization that claimed a root handle (issue #941) is canonical at
      # `/:handle`; list that, matching the page's rel=canonical, so the
      # sitemap never advertises the `/organizations/:slug` duplicate.
      path = if username, do: "/" <> username, else: "/organizations/" <> slug
      {path, NaiveDateTime.to_date(updated_at)}
    end)
  end

  @doc "`{path, lastmod_date}` entries of one job-postings chunk (1-based)."
  def job_entries(chunk) do
    indexable_jobs()
    |> order_by([p], p.id)
    |> window(chunk)
    |> select([p], {p.slug, p.updated_at})
    |> Repo.all()
    |> Enum.map(fn {slug, updated_at} ->
      {"/jobs/" <> slug, NaiveDateTime.to_date(updated_at)}
    end)
  end

  # The crawlable organization set lives in Vutuv.Organizations (the /organizations directory
  # rule), so directory and sitemap can never drift apart.
  defp indexable_organizations, do: Vutuv.Organizations.indexable_query()

  # Likewise the crawlable job-posting set lives in Vutuv.Jobs.
  defp indexable_jobs, do: Vutuv.Jobs.indexable_query()

  defp window(query, chunk) when is_integer(chunk) and chunk >= 1 do
    query |> limit(^@chunk_size) |> offset(^((chunk - 1) * @chunk_size))
  end

  # The crawlable member set lives in Vutuv.Directory, where it is derived in
  # one `where` from the set that module lists (`listed_users/0` minus the
  # search-engine opt-out), so the two cannot drift apart in the direction that
  # would matter — a member the sitemap advertises is always one the directory
  # shows. The reverse is deliberately false since v7.407.0: the directory
  # lists an opted-out member for people to find and marks their row
  # `rel="nofollow"`, while this set still leaves them out.
  defp indexable_users, do: Vutuv.Directory.indexable_users()

  # scope_visible(nil) already drops restricted posts, frozen posts and
  # moderation-hidden authors; the join adds the member-level conditions.
  defp indexable_posts do
    Post
    |> Posts.scope_visible(nil)
    |> join(:inner, [p], u in assoc(p, :user))
    |> where([p, u], u.email_confirmed? and not u.noindex?)
  end

  # A post published in an organization's name (issue #1334) is public by
  # construction — it carries no denials — so what decides indexability is the
  # page (active, not frozen, `seo?`) plus the post's own moderation state.
  defp indexable_organization_posts do
    Post
    |> join(:inner, [p], o in Organization, on: o.id == p.organization_id)
    |> where([p, o], o.status == "active" and is_nil(o.frozen_at) and o.seo?)
    |> where([p], is_nil(p.frozen_at))
  end

  defp chunks(0), do: 0
  defp chunks(count), do: div(count - 1, @chunk_size) + 1
end
