defmodule Mix.Tasks.Vutuv.Images.SweepLegacy do
  @shortdoc "Deletes legacy avatar/cover files after the fingerprint migration"

  @moduledoc """
  The **contract** step of the avatar/cover fingerprint migration: removes the
  legacy files that `Vutuv.Uploads.Regenerator` kept during the expand phase
  (so a rollback could still serve them). Run this **only once** the
  fingerprinted scheme is confirmed healthy in production — it is never part of
  the deploy. See `Vutuv.Uploads.LegacySweeper`.

      mix vutuv.images.sweep_legacy --dry-run   # report what would be removed
      mix vutuv.images.sweep_legacy
      mix vutuv.images.sweep_legacy --only covers

  Safe by construction: only rows already on the fingerprinted scheme are
  visited, and only non-current files are removed (and only when the current
  fingerprinted versions are all present). Idempotent.

  In production (a release, no Mix) use
  `bin/vutuv eval "Vutuv.Release.sweep_legacy_images()"` instead.
  """

  use Mix.Task

  alias Vutuv.Uploads.LegacySweeper

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _errors} =
      OptionParser.parse(args, strict: [only: :string, dry_run: :boolean])

    Mix.Task.run("app.start")

    opts
    |> Enum.map(fn
      {:only, type} -> {:only, parse_type!(type)}
      other -> other
    end)
    |> LegacySweeper.run()
  end

  defp parse_type!(type) do
    Enum.find(LegacySweeper.types(), &(Atom.to_string(&1) == type)) ||
      Mix.raise(
        "unknown --only type #{inspect(type)}; expected one of: " <>
          Enum.map_join(LegacySweeper.types(), ", ", &Atom.to_string/1)
      )
  end
end
