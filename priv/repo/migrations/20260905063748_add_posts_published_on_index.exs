defmodule Vutuv.Repo.Migrations.AddPostsPublishedOnIndex do
  use Ecto.Migration

  @moduledoc """
  The index the post calendar (`/system/posts`) reads by.

  `posts_user_id_published_on_index` exists, but `published_on` is its *second*
  column and Postgres 17 has no btree skip scan, so a query that names the day
  and not the author walks the whole index. Measured against the dev copy of
  production (768 posts): the calendar's prev/next month lookup — an
  `ORDER BY published_on DESC LIMIT 1` that runs twice per month page — cost 312
  shared buffers as a sequential scan and 9 with this index, an early-stopping
  index scan. That gap grows with the archive; the page is linked from every
  footer.

  `id` rides along so the day page's `published_on = $1 ORDER BY id` is one
  ordered walk, and because a btree scans backwards, the same index serves the
  previous-month lookup without a `DESC` twin.

  A plain addition: N-1 compatible in one deploy.
  """

  def change do
    create(index(:posts, [:published_on, :id]))
  end
end
