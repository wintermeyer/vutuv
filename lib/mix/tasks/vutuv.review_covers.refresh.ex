defmodule Mix.Tasks.Vutuv.ReviewCovers.Refresh do
  @shortdoc "Re-fetches every stored book cover from Open Library"

  @moduledoc """
  Re-fetches the cover of every book review from Open Library at the current
  `Vutuv.Uploads.Spec` size, and deletes the private originals that fetches
  before v7.122.4 kept.

      mix vutuv.review_covers.refresh
      mix vutuv.review_covers.refresh --delay 5000

  Covers are the one image kind vutuv keeps no original of (they are quoted
  publisher artwork, not our upload — see `Vutuv.ReviewCover`), so
  `mix vutuv.images.regenerate` cannot re-derive them after a Spec change;
  this task is their equivalent. Open Library asks callers not to crawl the
  cover API, so it waits `--delay` ms between fetches (3s by default).

  In production (a release, no Mix) use
  `bin/vutuv eval "Vutuv.Release.refresh_review_covers()"` instead.
  """

  use Mix.Task

  alias Vutuv.Posts.ReviewCovers

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _errors} = OptionParser.parse(args, strict: [delay: :integer])

    Mix.Task.run("app.start")

    summary = ReviewCovers.refresh_all(opts)
    Mix.shell().info("refetched #{summary.refetched}, skipped #{summary.skipped}")
  end
end
