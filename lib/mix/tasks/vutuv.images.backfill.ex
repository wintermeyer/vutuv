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

  Every run ends with the check, and **a mismatch raises**: that is the gate on
  the later deploy that drops the columns. In production (a release, no Mix)
  use `bin/vutuv eval "Vutuv.Release.backfill_image_rows()"` /
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

    opts |> Keyword.take([:only]) |> Backfill.check() |> report!()
  end

  defp report!(%{kinds: kinds, ok?: ok?}) do
    for {kind, result} <- kinds do
      Mix.shell().info(
        "#{kind}: #{result.pictures} picture(s), #{result.rows} row(s) — " <>
          Enum.map_join(classes(), ", ", fn {key, label} ->
            "#{length(Map.fetch!(result, key))} #{label}"
          end)
      )

      for {key, label} <- classes(), Map.fetch!(result, key) != [] do
        Mix.shell().info("  #{label}: #{sample(Map.fetch!(result, key))}")
      end
    end

    unless ok?, do: Mix.raise("images backfill check failed — see the mismatches above")

    Mix.shell().info("Every member picture has its row and its file. Safe to cut.")
  end

  # Ten ids is enough to go and look at one; the count above is the number that
  # matters, and printing 1,700 uuids buries it.
  defp sample(ids) do
    shown = Enum.take(ids, 10)
    Enum.join(shown, " ") <> if(length(ids) > 10, do: " … (#{length(ids)} total)", else: "")
  end

  defp classes do
    [
      missing_row: "without a row",
      mismatched_row: "disagreeing with the member row",
      missing_pointer: "not pointed at",
      missing_file: "with no file on disk",
      orphan_row: "orphan row(s)"
    ]
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
