defmodule Vutuv.Repo.Migrations.StripCustomEmojiFromRemoteText do
  use Ecto.Migration

  alias Vutuv.Fediverse

  # Takes the custom-emoji shortcodes out of the remote text already cached.
  #
  # `Vutuv.RemoteHtml.strip_shortcodes/1` drops them on the way in from this
  # release on, but a cached post is written once and never re-read from its
  # origin, so everything stored before this would go on showing a literal
  # ":tux:" until it aged out of its six-month retention. The work lives in
  # Vutuv.Fediverse.strip_stored_shortcodes/0, which covers every column
  # remote_text/3 writes — calling it rather than transcribing the grammar into
  # SQL is what keeps a backfilled row and a row written tomorrow identical.
  #
  # Data-only (no DDL), so it is N-1 compatible for the blue/green deploy: the
  # previous release reads these columns as the plain text they already were,
  # shorter text renders the same everywhere, and no column type changes, so no
  # cached prepared plan is invalidated. A fresh or test database has nothing to
  # clean, which makes it a no-op there.
  def up do
    IO.puts("stripped shortcodes from #{Fediverse.strip_stored_shortcodes()} stored value(s)")
  end

  # The shortcodes are gone from text a remote server sent us, and that text is
  # a cache we never held another copy of.
  def down, do: :ok
end
