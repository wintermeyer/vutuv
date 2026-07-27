defmodule Vutuv.Repo.Migrations.WidenPostRemoteReplyUris do
  use Ecto.Migration

  @moduledoc """
  The sidecar's three URIs are `varchar(255)` while everything they are copied
  from is `text` capped at 2048 bytes, and its own changeset permits 2048. So a
  remote server publishing a post with a 300-character `id` — perfectly legal,
  accepted at our inbox, refused by no changeset anywhere — makes Postgres raise
  22001 the moment a member answers it. A crashed composer, triggered from
  another server, on ordinary input.

  This is the `fediverse_post_deliveries.inbox_uri` lesson again: a column that
  stores a value copied from an existing one takes **that column's** type.
  Nothing user-facing writes these, so no changeset validation would have caught
  the drift; only reading the source column's type does.

  A widen is safe for the previous release (every value that fit still fits),
  but a column type change does invalidate its cached prepared statements, so
  expect a single 0A000 blip per affected statement on the old slot during the
  switch — the pool re-prepares itself (`disconnect_on_error_codes`).

  `handle` stays `varchar(255)`: it is cosmetic and remote-supplied, so the
  writer truncates it rather than the column growing to hold whatever a hostile
  server sends.
  """

  def up do
    alter table(:post_remote_replies) do
      modify(:in_reply_to_uri, :text)
      modify(:actor_uri, :text)
      modify(:inbox_uri, :text)
    end
  end

  def down do
    alter table(:post_remote_replies) do
      modify(:in_reply_to_uri, :string)
      modify(:actor_uri, :string)
      modify(:inbox_uri, :string)
    end
  end
end
