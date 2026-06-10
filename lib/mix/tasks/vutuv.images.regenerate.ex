defmodule Mix.Tasks.Vutuv.Images.Regenerate do
  @shortdoc "Re-derives all served image versions from the private originals"

  @moduledoc """
  Re-derives every served image version (AVIF) from the kept originals per
  the current `Vutuv.Uploads.Spec`, relocating legacy public originals into
  the private `originals/` tree first. See `Vutuv.Uploads.Regenerator`.

      mix vutuv.images.regenerate
      mix vutuv.images.regenerate --dry-run
      mix vutuv.images.regenerate --only avatars
      mix vutuv.images.regenerate --force   # re-derive converged rows too

  `--only` takes one of: #{Enum.map_join(Vutuv.Uploads.Regenerator.types(), ", ", &"`#{&1}`")}
  (`orphans` runs just the final pass that moves originals no DB row claims
  out of the public trees). `--force` re-derives rows that are already on the
  current Spec — needed after a quality/resolution-only Spec change (the
  filenames stay the same, so those rows otherwise count as unchanged).

  In production (a release, no Mix) use
  `bin/vutuv eval "Vutuv.Release.regenerate_images()"` instead.
  """

  use Mix.Task

  alias Vutuv.Uploads.Regenerator

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _errors} =
      OptionParser.parse(args, strict: [only: :string, dry_run: :boolean, force: :boolean])

    Mix.Task.run("app.start")

    opts
    |> Enum.map(fn
      {:only, type} -> {:only, parse_type!(type)}
      other -> other
    end)
    |> Regenerator.run()
  end

  defp parse_type!(type) do
    Enum.find(Regenerator.types(), &(Atom.to_string(&1) == type)) ||
      Mix.raise(
        "unknown --only type #{inspect(type)}; expected one of: " <>
          Enum.map_join(Regenerator.types(), ", ", &Atom.to_string/1)
      )
  end
end
