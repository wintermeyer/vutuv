defmodule Vutuv.Repo.Migrations.NormalizeLegacyTagWhitespace do
  use Ecto.Migration

  alias Vutuv.Tags

  # Reconciles the legacy 2017 tag data with vutuv's "a tag is a single token,
  # no spaces" rule (issue #847): merges the whitespace-only duplicate tags
  # (" Datacenter" into "Datacenter", "Phoenix Framework" into the stray
  # "phoenix_framework", …) and trims stray leading/trailing/doubled whitespace
  # from the rest. Legitimate multi-word names ("Ruby on Rails") are left as
  # they are — their already spaceless slug is what the tag page's "Add this
  # tag" button now submits. The work lives in
  # Vutuv.Tags.normalize_legacy_tag_whitespace/0.
  #
  # Data-only (no DDL): the old release keeps reading tags.name / slug and the
  # user_tags it points at throughout, so it stays N-1 compatible for the
  # blue/green deploy, and the whole cleanup runs all-or-nothing in the implicit
  # transaction. A fresh / test database has no legacy tags, so it is a no-op
  # there — the real work only touches production data.
  def up do
    {merged, trimmed} = Tags.normalize_legacy_tag_whitespace()
    IO.puts("merged #{merged} duplicate tag(s), trimmed #{trimmed} tag name(s)")
  end

  # The merge deletes rows and rewrites names in place, so it cannot be undone.
  def down, do: :ok
end
