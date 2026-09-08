defmodule Mix.Tasks.Vutuv.Images.Backfill do
  @shortdoc "Brings every existing picture into the shared images table"

  @moduledoc """
  Reconciles every picture with its row in the shared `images` table — the
  **contract** half of issue #2013 for profile pictures and covers, and of
  #2015 for the kinds that still keep their truth outside it (a job-posting
  picture since #2054, a post photo since #2052, an organization image since
  #2053, a review cover since #2055). See `Vutuv.Images.Backfill`.

      mix vutuv.images.backfill              # reconcile every kind, then check
      mix vutuv.images.backfill --dry-run    # report what would change
      mix vutuv.images.backfill --check      # check only, write nothing
      mix vutuv.images.backfill --only cover
      mix vutuv.images.backfill --only job_posting_image
      mix vutuv.images.backfill --only post_image
      mix vutuv.images.backfill --only organization_image
      mix vutuv.images.backfill --only review_cover
      mix vutuv.images.backfill --from 019f0000-0000-7000-8000-000000000000

  Moves no file and changes no URL: what a picture already lives in stays the
  source of truth (columns on a parent row for a profile picture and a review
  cover, its own row for a gallery one), and this copies what it says into a
  row. Idempotent — a run that is interrupted (a deploy stopping the slot) is
  simply run again, and every picture it already reached reports `unchanged`.
  `--from` is a parent-row id for a column kind (a member, a review) and a
  gallery row id for the rest, so pair it with `--only`.

  Every run ends with the check, which prints what it found and **fails the
  command only when something is outstanding** — that non-zero exit is the gate
  on the later deploy that drops the columns. The printing lives in
  `Vutuv.Images.Backfill.check/1`, not here, so this task and the release path
  cannot say different things.

  In production (a release, no Mix) use
  `bin/vutuv eval "Vutuv.Release.backfill_image_rows()"` /
  `bin/vutuv eval "Vutuv.Release.check_image_rows()"`.
  """

  use Mix.Task

  alias Vutuv.Images.Backfill

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _errors} =
      OptionParser.parse(args,
        strict: [only: :string, dry_run: :boolean, check: :boolean, from: :string]
      )

    Mix.Task.run("app.start")

    opts =
      Enum.map(opts, fn
        {:only, kind} -> {:only, parse_kind!(kind)}
        other -> other
      end)

    unless opts[:check], do: opts |> Keyword.delete(:check) |> Backfill.run()

    summary = opts |> Keyword.take([:only]) |> Backfill.check()

    unless summary.ok?,
      do: Mix.raise("images backfill check failed — see the mismatches above")

    summary
  end

  defp parse_kind!(kind) do
    if kind in Backfill.kinds() do
      kind
    else
      Mix.raise(
        "unknown --only kind #{inspect(kind)}; expected one of: " <>
          Enum.join(Backfill.kinds(), ", ")
      )
    end
  end
end
