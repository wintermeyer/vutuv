defmodule Vutuv.Repo.Migrations.ClearStaleBrokenFlagOnUrls do
  use Ecto.Migration

  # `urls.broken?` today means one thing: the capture was refused because the
  # host resolves to an internal address (issue #777). It did not always. Until
  # v5 the pipeline flagged **every** failure — a missing Chromium binary, a
  # timeout, a site that was down that afternoon — and that flag is permanent,
  # because nothing ever clears it.
  #
  # On vutuv.de that left 45 links flagged, every one of them stamped between
  # 2016-12 and 2018-03, and not one of them resolving to an internal address
  # today: measured, all 45 answer with a public IP. They are members' ordinary
  # homepages, poisoned by a rule that no longer exists — and now that
  # `Vutuv.PageScreenshot.due/1` reads the flag to decide what to retry, they
  # are the rows the new sweeper would step over forever.
  #
  # So this clears the flag rather than the screenshots: NULL, not false, because
  # "never determined" is what these rows are. A link that really is an internal
  # target costs one DNS lookup on the next sweep and is flagged again — the
  # answer is cheap and the current code is the one that decides it.
  #
  # What this deliberately does **not** do is capture anything. A migration runs
  # before the app is started, so `Vutuv.Ssrf.SocksProxy` is not up and every
  # capture from here fails closed with `:proxy_unavailable` (verified against
  # production's own release). The pictures are the sweeper's job, and the row
  # state above is all it needs to find them.
  def up do
    execute("""
    UPDATE urls SET "broken?" = NULL WHERE "broken?" = true
    """)
  end

  # Not reversible in any useful sense: which rows carried the flag is exactly
  # what this drops, and restoring it would re-poison links that are fine.
  def down, do: :ok
end
