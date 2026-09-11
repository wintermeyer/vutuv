defmodule Vutuv.Repo.Migrations.IndexReportedExternalTagPostsByAuthor do
  use Ecto.Migration

  # The one query the takedown key (issue #2164) added to a path that runs
  # whatever anybody does: before storing what a tag pull brought back,
  # `Vutuv.Tags.ExternalPosts.reject_reported/1` asks whether any of those posts
  # has already been reported, and it asks it per (tag, server) pair, up to the
  # fetch budget's twenty per run, every ten minutes to three hours.
  #
  # Measured over 10,000 rows at the table's own ceiling, with 0.2 % of them
  # tombstones: 1.75 ms as a sequential scan, 0.012 ms through this index, which
  # is 16 kB because the partial clause keeps only the reported rows in it. The
  # selectivity is what makes it worth having — a tombstone is a rare row
  # however popular one author host becomes, so this stays tiny and stays used,
  # where a plain index on `author_host` would be 88 kB and the planner would
  # ignore it for exactly the host that holds most of the table.
  #
  # Nothing needs it at today's 78 rows. It is here rather than in a note
  # because it is a plain addition, which the deploy takes in one step.
  def change do
    create(
      index(:external_tag_posts, [:author_host],
        where: "reported_at IS NOT NULL",
        name: :external_tag_posts_reported_author_index
      )
    )
  end
end
