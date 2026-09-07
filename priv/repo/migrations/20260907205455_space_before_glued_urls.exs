defmodule Vutuv.Repo.Migrations.SpaceBeforeGluedUrls do
  use Ecto.Migration

  alias Vutuv.Fediverse

  # Puts the missing space back into the cached remote text that already carries
  # a web address glued to the word in front of it.
  #
  # The cause is fixed in `Vutuv.RemoteHtml.keep_space_between_tags/1` — the
  # parser under `strip_tags/1` was dropping the whitespace between two tags —
  # but only the plain text is stored, never the HTML it came from, so nothing
  # can re-derive these rows. `Vutuv.Fediverse.space_stored_glued_urls/0` walks
  # every column `remote_text/3` writes and applies the very function the inbox
  # now runs, which is what keeps a backfilled row and a row written tomorrow
  # identical. Measured on the dev copy of production beforehand: 45 of 8,764
  # cached posts, notes and bios matched, all of them this bug.
  #
  # `fediverse_posts.search_tsv` is generated from `content_text`, so a repaired
  # row re-indexes itself — the glued word was one unsearchable token.
  #
  # Data-only (no DDL), so it is N-1 compatible for the blue/green deploy: the
  # previous release reads these columns as the plain text they already were,
  # and no column type changes, so no cached prepared plan is invalidated. A
  # fresh or test database has nothing to repair, which makes it a no-op there.
  def up do
    IO.puts("spaced #{Fediverse.space_stored_glued_urls()} glued address(es)")
  end

  # A space cannot be told from one the author wrote, so there is nothing to
  # take back out.
  def down, do: :ok
end
