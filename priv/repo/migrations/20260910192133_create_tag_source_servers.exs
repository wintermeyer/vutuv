defmodule Vutuv.Repo.Migrations.CreateTagSourceServers do
  use Ecto.Migration

  # What this installation knows about a server a followed tag could read from
  # (issue #2128): whether it will serve a public tag timeline at all, and how
  # big it is. The tag-source panel reads it to put a figure beside every server
  # it offers, and writes it when it asks one.
  #
  # A table rather than a memory cache because the answers are slow to change
  # and expensive to get — three requests per server, ten servers behind the
  # panel — while a cache is empty again after every deploy, which is daily
  # here. Nothing else keys on it, so this is a plain addition and N-1 safe: the
  # release now serving traffic neither reads nor writes it.
  def change do
    create table(:tag_source_servers) do
      add(:host, :string, null: false)

      # What the server calls itself, and its own blurb. `description` is
      # `:text` deliberately: it is a stranger's prose, not ours to bound, and
      # the sibling for remote-written text here is `fediverse_followers.name`,
      # which is text for the same reason. A varchar(255) would raise 22001 on
      # nothing worse than a chatty operator.
      add(:node_name, :string)
      add(:description, :text)

      # NodeInfo's `usage`: accounts, accounts active this month, posts written
      # here. `:bigint` because the biggest server in the shipped list already
      # reads 187,847,145 posts and the column must not be the reason a bigger
      # one cannot be offered.
      add(:accounts, :bigint)
      add(:active_month, :bigint)
      add(:posts, :bigint)

      # The server's own default language, as an ISO code. Not from NodeInfo,
      # which carries no such field in either 2.0 or 2.1 — see
      # `Vutuv.Tags.SourceServerProbe`.
      add(:language, :string, size: 16)

      # Whether the public tag timeline can be read: "ok", "account_required"
      # (the server answers, but only to somebody logged in), "unreachable".
      # It is the one column the panel's switch depends on; everything above is
      # decoration a server may leave out and still be pickable.
      add(:status, :string, null: false)

      # The scheduler's clock, stamped on every outcome including the ones where
      # nothing could be learned — a server that cannot be reached must not be
      # asked again on the next render.
      add(:checked_at, :utc_datetime, null: false)

      timestamps()
    end

    create(unique_index(:tag_source_servers, [:host]))
  end
end
