defmodule Mix.Tasks.Vutuv.Images.RelabelLegacyDirs do
  @shortdoc "Renames image dirs from the legacy integer id to the new UUID"

  @moduledoc """
  One-time cutover step for the `convert_ids_to_uuid_v7` migration: renames the
  on-disk image directories (`avatars/`, `covers/`, `screenshots/` and their
  `originals/` mirrors) from their old integer id to the new UUID, using the
  `legacy_id_map` table the migration leaves behind. Without it every avatar,
  cover and screenshot URL points at a directory that no longer exists. See
  `Vutuv.Uploads.LegacyRelabel`.

      mix vutuv.images.relabel_legacy_dirs
      mix vutuv.images.relabel_legacy_dirs --dry-run

  Run it **before** `mix vutuv.images.regenerate`. In production (a release, no
  Mix) use `bin/vutuv eval "Vutuv.Release.relabel_image_dirs()"` instead.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _errors} = OptionParser.parse(args, strict: [dry_run: :boolean])

    Mix.Task.run("app.start")

    case Vutuv.Uploads.LegacyRelabel.run(opts) do
      {:ok, summary} ->
        Mix.shell().info(
          "relabel: #{summary.renamed} renamed, #{summary.unmapped} unmapped, " <>
            "#{summary.already_uuid} already UUID, #{summary.conflict} conflict"
        )

      {:error, :no_mapping} ->
        Mix.shell().info(
          "relabel: no legacy_id_map rows — nothing to do " <>
            "(migration not run, or already cleaned up)"
        )
    end
  end
end
