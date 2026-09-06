defmodule Mix.Tasks.Vutuv.Images.Backfill do
  @shortdoc "Brings every existing profile picture and cover into the images table"

  @moduledoc """
  Reconciles every member's profile picture and cover with its row in the
  shared `images` table — the **contract** half of issue #2013. See
  `Vutuv.Images.Backfill`.

      mix vutuv.images.backfill              # reconcile, then check
      mix vutuv.images.backfill --dry-run    # report what would change
      mix vutuv.images.backfill --check      # check only, write nothing
      mix vutuv.images.backfill --only cover
      mix vutuv.images.backfill --from 019f0000-0000-7000-8000-000000000000

  Moves no file and changes no URL: the four member-row columns stay the source
  of truth, and this copies what they say into a row. Idempotent — a run that
  is interrupted (a deploy stopping the slot) is simply run again, and every
  member it already reached reports `unchanged`.

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
